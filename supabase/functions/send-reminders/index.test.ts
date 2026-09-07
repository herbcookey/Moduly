import { handleRequest } from "./index.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

function assertFalse(value: unknown): void {
  assert(value === false, `expected false, got ${String(value)}`);
}

function assertStringIncludes(value: string, fragment: string): void {
  assert(value.includes(fragment), `expected ${value} to include ${fragment}`);
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

Deno.test("send-reminders authenticates, bounds claims, and sanitizes worker output", async () => {
  await withCleanEnvironment(async () => {
    const unauthorizedCalls: RpcCall[] = [];
    const restoreUnauthorized = await installFetch(
      () => ({}),
      unauthorizedCalls,
    );
    try {
      // Missing and mismatched worker secrets fail before URL/key resolution or
      // any Supabase RPC, including when the request body is malformed.
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

    // Capability is checked before either claim path; an unconfigured
    // deployment leaves every lease untouched and returns an explicit 503.
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

    // Configure only the provider capability and a fake provider secret.  The
    // repository intentionally has no APNs/FCM adapter, so a valid payload is
    // completed retryably while stale/no-device payloads use their distinct
    // permanent/retryable receipts.  None of those payload values can escape
    // the HTTP response or logs.
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
          throw new Error(`unexpected rpc ${name}`);
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
