import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.50.0";

// 이 엔드포인트는 의도적으로 내부 전용이다. 이 작업자는 브라우저가 아니라
// 스케줄러가 호출하므로 config.toml에서 Supabase JWT 게이트를 비활성화했다.
// 모든 요청에는 아래의 배포 전용 작업자 비밀 값이 있어야 한다.
const jsonHeaders = { "Content-Type": "application/json" };

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: jsonHeaders,
  });
}

function configuredSecret(name: string): string {
  const value = Deno.env.get(name);
  return value?.trim() ?? "";
}

function serviceKey(): string {
  const candidates = [
    configuredSecret("SUPABASE_SECRET_KEY"),
    configuredSecret("SUPABASE_SERVICE_ROLE_KEY"),
  ];
  const keySet = configuredSecret("SUPABASE_SECRET_KEYS");
  if (keySet.length > 0) {
    try {
      const parsed: unknown = JSON.parse(keySet);
      if (
        parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
      ) {
        const value = (parsed as { default?: unknown }).default;
        if (typeof value === "string" && value.trim().length > 0) {
          candidates.unshift(value.trim());
        }
      }
    } catch (_) {
      // 잘못된 키 집합을 근거로 제공자를 추측하거나 이를 로그에 남기지 않는다.
    }
  }
  return candidates.find((value) => value.length > 0) ?? "";
}

type Capability = {
  provider: string;
  enabled: boolean;
  capability: string;
};

type Counts = {
  reconciled: number;
  claimed: number;
  sent: number;
  retried: number;
  deadLettered: number;
  stale: number;
};

function capabilityConfigured(value: unknown): value is Capability {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const raw = value as Record<string, unknown>;
  return (
    typeof raw.provider === "string" &&
    typeof raw.enabled === "boolean" &&
    typeof raw.capability === "string"
  );
}

// 제공자 SDK/I/O는 의도적으로 이 어댑터 뒤에 둔다. 이 저장소에는 APNs/FCM
// 자격 증명이나 제공자 클라이언트가 없으므로, 기능이 구성된 것처럼 보여도
// 거짓 "전송 완료" 응답으로 바꿀 수 없다. 대신 작업자가 작업을 가져오고
// 임대한 뒤 재시도 가능한 어댑터 오류를 보고한다.
async function sendProvider(_payload: unknown, _provider: string): Promise<
  { outcome: "retryable"; errorCode: string }
> {
  return { outcome: "retryable", errorCode: "provider_adapter_unavailable" };
}

async function rpc<T>(
  client: SupabaseClient,
  name: string,
  params?: Record<string, unknown>,
): Promise<T> {
  const result = await client.rpc(name, params ?? {});
  if (result.error != null) throw result.error;
  return result.data as T;
}

async function internalSecret(request: Request): Promise<boolean> {
  const expected = configuredSecret("REMINDER_WORKER_SECRET");
  const supplied = request.headers.get("x-reminder-worker-secret")?.trim() ??
    "";
  // 두 값을 고정 크기 다이제스트로 해시하고 모든 바이트를 비교한다. 작업자
  // 경계에서 조기 종료 문자열 비교를 사용하지 않으며, 비어 있지 않은지도
  // 검사하므로 구성되지 않은 배포나 빈 헤더로 내부 엔드포인트를 인증할 수 없다.
  const encoder = new TextEncoder();
  const [expectedDigest, suppliedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
  ]);
  const expectedBytes = new Uint8Array(expectedDigest);
  const suppliedBytes = new Uint8Array(suppliedDigest);
  let difference = expected.length > 0 && supplied.length > 0 ? 0 : 1;
  for (let index = 0; index < expectedBytes.length; index += 1) {
    difference |= expectedBytes[index] ^ suppliedBytes[index];
  }
  return difference === 0;
}

function providerSecretConfigured(provider: string): boolean {
  if (provider === "apns") {
    return (
      configuredSecret("APNS_KEY_ID").length > 0 &&
      configuredSecret("APNS_TEAM_ID").length > 0 &&
      configuredSecret("APNS_PRIVATE_KEY").length > 0
    );
  }
  if (provider === "fcm") {
    return configuredSecret("FCM_SERVER_KEY").length > 0 ||
      (configuredSecret("FCM_PROJECT_ID").length > 0 &&
        configuredSecret("FCM_CLIENT_EMAIL").length > 0 &&
        configuredSecret("FCM_PRIVATE_KEY").length > 0);
  }
  return false;
}

export async function handleRequest(request: Request): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  if (!await internalSecret(request)) {
    return json({ error: "unauthorized" }, 401);
  }

  const supabaseUrl = configuredSecret("SUPABASE_URL");
  const key = serviceKey();
  if (supabaseUrl.length === 0 || key.length === 0) {
    return json({ error: "server_not_configured" }, 500);
  }

  let body: Record<string, unknown> = {};
  try {
    const parsed: unknown = await request.json();
    if (
      parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
    ) {
      body = parsed as Record<string, unknown>;
    }
  } catch (_) {
    // 빈 JSON은 기본 제한 범위의 작업자 실행과 같다.
  }
  const requestedLimit = body.limit;
  const limit =
    typeof requestedLimit === "number" && Number.isSafeInteger(requestedLimit)
      ? Math.min(100, Math.max(1, requestedLimit))
      : 50;

  const client = createClient(supabaseUrl, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 작업 가져오기 RPC를 호출하기 전에 기능과 제공자 비밀 값을 확인한다. 따라서
  // 미구성 상태를 정확히 알리고, 향후 자격 증명을 갖춘 배포를 위해 임대 상태를
  // 변경하지 않는다.
  let capability: Capability;
  try {
    const raw = await rpc<unknown>(client, "worker_push_capability");
    if (!capabilityConfigured(raw)) {
      return json({ error: "capability_invalid" }, 500);
    }
    capability = raw;
  } catch (_) {
    return json({ error: "capability_unavailable" }, 503);
  }
  if (
    !capability.enabled || capability.provider === "none" ||
    capability.capability !== "push_configured" ||
    !providerSecretConfigured(capability.provider)
  ) {
    return json({
      capability: "push_unconfigured",
      processed: 0,
      claimed: 0,
    }, 503);
  }

  const workerId = crypto.randomUUID();
  const counts: Counts = {
    reconciled: 0,
    claimed: 0,
    sent: 0,
    retried: 0,
    deadLettered: 0,
    stale: 0,
  };

  try {
    const requests = await rpc<unknown>(
      client,
      "worker_claim_reconcile_requests",
      {
        p_worker_id: workerId,
        p_limit: limit,
      },
    );
    const requestRows = requests !== null && typeof requests === "object" &&
        !Array.isArray(requests)
      ? (requests as { requests?: unknown }).requests
      : [];
    if (Array.isArray(requestRows)) {
      for (const row of requestRows) {
        if (row === null || typeof row !== "object" || Array.isArray(row)) {
          continue;
        }
        const eventId = (row as { event_id?: unknown }).event_id;
        if (typeof eventId !== "string") continue;
        try {
          await rpc(client, "worker_prepare_event_reminder_jobs", {
            p_event_id: eventId,
          });
          await rpc(client, "worker_complete_reconcile_request", {
            p_event_id: eventId,
            p_worker_id: workerId,
            p_outcome: "done",
          });
          counts.reconciled += 1;
        } catch (_) {
          try {
            await rpc(client, "worker_complete_reconcile_request", {
              p_event_id: eventId,
              p_worker_id: workerId,
              p_outcome: "retryable",
              p_error_code: "reconcile_failed",
            });
          } catch (_) {
            // 임대/재시도 RPC 자체는 최선형 처리이며 페이로드를 로그에 남기지 않는다.
          }
        }
      }
    }

    const claimed = await rpc<unknown>(
      client,
      "worker_claim_event_reminder_jobs",
      {
        p_worker_id: workerId,
        p_limit: limit,
      },
    );
    const jobRows =
      claimed !== null && typeof claimed === "object" && !Array.isArray(claimed)
        ? (claimed as { jobs?: unknown }).jobs
        : [];
    if (Array.isArray(jobRows)) {
      counts.claimed = jobRows.length;
      for (const row of jobRows) {
        if (row === null || typeof row !== "object" || Array.isArray(row)) {
          continue;
        }
        const jobId = (row as { id?: unknown }).id;
        if (typeof jobId !== "string") continue;
        try {
          const payload = await rpc<unknown>(
            client,
            "worker_load_event_reminder_payload",
            {
              p_job_id: jobId,
              p_worker_id: workerId,
            },
          );
          if (
            payload === null || typeof payload !== "object" ||
            Array.isArray(payload)
          ) {
            throw new Error("payload_invalid");
          }
          const valid = (payload as { valid?: unknown }).valid;
          if (valid !== true) {
            const reason = (payload as { reason?: unknown }).reason;
            const retryable = reason === "no_device";
            if (!retryable) counts.stale += 1;
            await rpc(client, "worker_complete_event_reminder_job", {
              p_job_id: jobId,
              p_worker_id: workerId,
              p_outcome: retryable ? "retryable" : "permanent",
              p_error_code: retryable ? "no_device" : "stale",
            });
            continue;
          }
          // 이 호출은 모든 데이터베이스 트랜잭션 밖에서 수행한다. 승인된 제공자
          // 어댑터와 자격 증명이 배포에 추가될 때까지 의도적으로 재시도 가능한
          // 무동작으로 구현한다.
          const result = await sendProvider(payload, capability.provider);
          await rpc(client, "worker_complete_event_reminder_job", {
            p_job_id: jobId,
            p_worker_id: workerId,
            p_outcome: result.outcome,
            p_error_code: result.errorCode,
          });
          counts.retried += 1;
        } catch (_) {
          try {
            await rpc(client, "worker_complete_event_reminder_job", {
              p_job_id: jobId,
              p_worker_id: workerId,
              p_outcome: "retryable",
              p_error_code: "worker_failed",
            });
          } catch (_) {
            // 임대는 안전하게 만료되거나 다시 가져올 수 있으며 작업 페이로드는 절대 출력하지 않는다.
          }
        }
      }
    }
  } catch (_) {
    return json({
      error: "worker_failed",
      capability: "push_configured",
      processed: 0,
    }, 500);
  }

  return json({
    capability: "push_configured",
    processed: counts.reconciled + counts.claimed,
    reconciled: counts.reconciled,
    claimed: counts.claimed,
    sent: counts.sent,
    retried: counts.retried,
    stale: counts.stale,
    dead_lettered: counts.deadLettered,
  });
}

if (import.meta.main) {
  Deno.serve(handleRequest);
}
