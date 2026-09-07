import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.50.0";

// The endpoint is intentionally internal. Supabase's JWT gate is disabled in
// config.toml because this worker is called by a scheduler, not by a browser;
// every request must carry the deployment-only worker secret below.
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
      // A malformed key set is not a reason to guess at a provider or log it.
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

// Provider SDK/I/O is deliberately kept behind this adapter. There are no
// APNs/FCM credentials or provider client in this repository, so an apparently
// configured capability cannot be turned into a false "sent" receipt. The
// worker claims/leases jobs and reports a retryable adapter error instead.
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
  // Hash both values to a fixed-size digest and compare every byte.  This keeps
  // the worker boundary from using an early-exit string comparison, while the
  // non-empty checks ensure an unconfigured deployment or empty header can
  // never authenticate an internal endpoint.
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
    // Empty JSON is equivalent to a default bounded worker pass.
  }
  const requestedLimit = body.limit;
  const limit =
    typeof requestedLimit === "number" && Number.isSafeInteger(requestedLimit)
      ? Math.min(100, Math.max(1, requestedLimit))
      : 50;

  const client = createClient(supabaseUrl, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Capability and provider secrets are checked before either claim RPC. This
  // makes the unconfigured state honest and leaves leases untouched for a
  // future deployment that has credentials.
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
            // The lease/retry RPC is itself best effort; no payload is logged.
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
          // This call is outside all database transactions. Its implementation
          // is intentionally a retryable no-op until an approved provider
          // adapter and credentials are added to the deployment.
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
            // A lease can expire/reclaim safely; never emit the job payload.
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
