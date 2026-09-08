import { handleRequest } from "./index.ts";

function assert(
  condition: unknown,
  message = "검증에 실패했습니다",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `기댓값: ${JSON.stringify(expected)}, 실제 값: ${JSON.stringify(actual)}`,
    );
  }
}

function assertFalse(value: unknown): void {
  assert(value === false, `false를 기대했지만 ${String(value)}을(를) 받았습니다`);
}

function assertStringIncludes(value: string, fragment: string): void {
  assert(value.includes(fragment), `${value}에 ${fragment}이(가) 포함되어야 합니다`);
}

const envNames = [
  "REMINDER_WORKER_SECRET",
  "SUPABASE_URL",
  "SUPABASE_SECRET_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_SECRET_KEYS",
  "APNS_KEY_ID",
  "APNS_TEAM_ID",
  "APNS_PRIVATE_KEY",
  "FCM_SERVER_KEY",
  "FCM_PROJECT_ID",
  "FCM_CLIENT_EMAIL",
  "FCM_PRIVATE_KEY",
];

type RpcCall = {
  name: string;
  params: Record<string, unknown>;
};

function request(body: unknown, secret?: string): Request {
  const headers = new Headers({ "content-type": "application/json" });
  if (secret != null) headers.set("x-reminder-worker-secret", secret);
  return new Request("https://worker.example/send-reminders", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

async function responseJson(
  response: Response,
): Promise<Record<string, unknown>> {
  return await response.json() as Record<string, unknown>;
}

async function withCleanEnvironment<T>(
  operation: () => Promise<T>,
): Promise<T> {
  const previous = new Map<string, string | undefined>();
  for (const name of envNames) {
    previous.set(name, Deno.env.get(name));
    Deno.env.delete(name);
  }
  try {
    return await operation();
  } finally {
    for (const name of envNames) {
      const value = previous.get(name);
      if (value == null) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
}

async function installFetch(
  handler: (name: string, params: Record<string, unknown>) => unknown,
  calls: RpcCall[],
): Promise<() => void> {
  const previous = globalThis.fetch;
  globalThis.fetch = async (
    input: Request | URL | string,
    init?: RequestInit,
  ) => {
    const outgoing = new Request(input, init);
    const name = new URL(outgoing.url).pathname.split("/").pop() ?? "";
    let params: Record<string, unknown> = {};
    const body = await outgoing.clone().text();
    if (body.length > 0) params = JSON.parse(body) as Record<string, unknown>;
    calls.push({ name, params });
    const value = handler(name, params);
    return new Response(JSON.stringify(value), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  return () => {
    globalThis.fetch = previous;
  };
}

Deno.test("send-reminders가 인증하고 작업 가져오기 범위를 제한하며 작업자 출력을 정제한다", async () => {
  await withCleanEnvironment(async () => {
    const unauthorizedCalls: RpcCall[] = [];
    const restoreUnauthorized = await installFetch(
      () => ({}),
      unauthorizedCalls,
    );
    try {
      // 작업자 비밀 값이 없거나 일치하지 않으면 요청 본문의 형식이 잘못된
      // 경우를 포함해 URL/키 확인이나 Supabase RPC 전에 실패한다.
      let response = await handleRequest(request({ limit: 999 }));
      assertEquals(response.status, 401);
      assertEquals(unauthorizedCalls.length, 0);
      Deno.env.set("REMINDER_WORKER_SECRET", "worker-secret");
      response = await handleRequest(request({ limit: 999 }, "wrong-secret"));
      assertEquals(response.status, 401);
      assertEquals(unauthorizedCalls.length, 0);
    } finally {
      restoreUnauthorized();
    }

    Deno.env.set("SUPABASE_URL", "https://project.example");
    Deno.env.set("SUPABASE_SECRET_KEY", "service-key");

    // 두 작업 가져오기 경로보다 먼저 기능을 확인한다. 구성되지 않은 배포는
    // 모든 임대를 그대로 두고 명시적인 503을 반환한다.
    const unconfiguredCalls: RpcCall[] = [];
    const restoreUnconfigured = await installFetch((name) => {
      assertEquals(name, "worker_push_capability");
      return {
        committed: true,
        provider: "none",
        enabled: false,
        capability: "push_unconfigured",
      };
    }, unconfiguredCalls);
    try {
      const response = await handleRequest(request({}, "worker-secret"));
      const body = await responseJson(response);
      assertEquals(response.status, 503);
      assertEquals(body.capability, "push_unconfigured");
      assertEquals(unconfiguredCalls.map((call) => call.name), [
        "worker_push_capability",
      ]);
    } finally {
      restoreUnconfigured();
    }

    // 제공자 기능과 가짜 제공자 비밀 값만 구성한다. 저장소에는 의도적으로
    // APNs/FCM 어댑터가 없으므로 유효한 페이로드는 재시도 가능 상태로 완료하고,
    // 오래되었거나 기기가 없는 페이로드는 각각 영구/재시도 가능 응답을 사용한다.
    // 해당 페이로드 값은 어느 것도 HTTP 응답이나 로그로 노출될 수 없다.
    Deno.env.set("FCM_SERVER_KEY", "fake-provider-secret");
    const calls: RpcCall[] = [];
    const restoreConfigured = await installFetch((name, params) => {
      switch (name) {
        case "worker_push_capability":
          return {
            committed: true,
            provider: "fcm",
            enabled: true,
            capability: "push_configured",
          };
        case "worker_claim_reconcile_requests":
          assertEquals(params.p_limit, 100);
          return {
            committed: true,
            requests: [{ event_id: "event-1" }],
            count: 1,
          };
        case "worker_prepare_event_reminder_jobs":
          return { committed: true, queued_jobs: 0 };
        case "worker_complete_reconcile_request":
          return { committed: true, status: "done" };
        case "worker_claim_event_reminder_jobs":
          assertEquals(params.p_limit, 100);
          return {
            committed: true,
            capability: "push_configured",
            jobs: [
              { id: "job-valid" },
              { id: "job-stale" },
              { id: "job-no-device" },
            ],
            count: 3,
          };
        case "worker_load_event_reminder_payload": {
          const jobId = params.p_job_id;
          if (jobId === "job-valid") {
            return {
              valid: true,
              job_id: jobId,
              title: "private title",
              description: "private description",
              tokens: [{ token: "private-device-token" }],
            };
          }
          if (jobId === "job-no-device") {
            return { valid: false, job_id: jobId, reason: "no_device" };
          }
          return { valid: false, job_id: jobId, reason: "stale" };
        }
        case "worker_complete_event_reminder_job":
          return { committed: true, status: params.p_outcome };
        default:
          throw new Error(`예상하지 못한 RPC: ${name}`);
      }
    }, calls);
    const logs: string[] = [];
    const originalConsole = globalThis.console;
    globalThis.console = {
      ...originalConsole,
      log: (...values: unknown[]) => logs.push(values.join(" ")),
      error: (...values: unknown[]) => logs.push(values.join(" ")),
      warn: (...values: unknown[]) => logs.push(values.join(" ")),
    };
    try {
      const response = await handleRequest(
        request({ limit: 999, ignored: "private title" }, "worker-secret"),
      );
      const body = await responseJson(response);
      assertEquals(response.status, 200);
      assertEquals(body.capability, "push_configured");
      assertEquals(body.claimed, 3);
      assertEquals(body.reconciled, 1);
      assertEquals(body.retried, 1);
      assertEquals(body.stale, 1);
      assertEquals(body.sent, 0);
      assertEquals(logs, []);
      const serialized = JSON.stringify(body);
      for (
        const forbidden of [
          "private-device-token",
          "private title",
          "private description",
          "worker-secret",
          "fake-provider-secret",
        ]
      ) {
        assertFalse(serialized.includes(forbidden));
      }

      const names = calls.map((call) => call.name);
      assertEquals(names[0], "worker_push_capability");
      assert(names.indexOf("worker_claim_reconcile_requests") > 0);
      assert(
        names.indexOf("worker_claim_event_reminder_jobs") >
          names.indexOf("worker_claim_reconcile_requests"),
      );
      const completions = calls.filter((call) =>
        call.name === "worker_complete_event_reminder_job"
      );
      assertEquals(completions.length, 3);
      assertEquals(
        completions.map((call) => call.params.p_outcome),
        ["retryable", "permanent", "retryable"],
      );
      assertStringIncludes(
        JSON.stringify(completions[0].params),
        "provider_adapter_unavailable",
      );
      assertStringIncludes(JSON.stringify(completions[1].params), "stale");
      assertStringIncludes(JSON.stringify(completions[2].params), "no_device");
    } finally {
      globalThis.console = originalConsole;
      restoreConfigured();
    }
  });
});
