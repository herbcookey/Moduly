import { createClient } from 'npm:@supabase/supabase-js@2.50.0'
import { isValidDeletionSummary } from './preflight_validator.mjs'

const confirmationPhrase = '계정 삭제'
// Flutter web sends a non-simple POST with these four headers. Keep the
// allow-list scoped to this function's actual endpoint rather than inheriting
// a broad project-wide policy. The endpoint authenticates every POST with an
// explicit bearer token, so wildcard origin is safe here without credentials;
// credentialed cross-origin requests are intentionally not enabled.
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const jsonHeaders = {
  ...corsHeaders,
  'Content-Type': 'application/json',
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: jsonHeaders,
  })
}

function bearerToken(request: Request): string | null {
  const value = request.headers.get('Authorization') ?? ''
  const match = value.match(/^Bearer\s+(.+)$/i)
  return match?.[1]?.trim() || null
}

/// 현재 Supabase Edge 런타임은 공개/비밀 키 집합을 JSON 객체(예:
/// {"default":"sb_publishable_..."})로 제공한다. 이전 런타임과 로컬 실행을
/// 위해 기존 단일 키 이름도 대체 경로로 유지하되, 권한 있는 키는 Flutter
/// 클라이언트에 절대 넣지 않는다.
function defaultKey(setName: string): string {
  const raw = Deno.env.get(setName)
  if (raw == null || raw.trim().length === 0) return ''
  try {
    const parsed: unknown = JSON.parse(raw)
    if (parsed != null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      const value = (parsed as { default?: unknown }).default
      return typeof value === 'string' ? value.trim() : ''
    }
  } catch (_) {
    // 잘못된 키 집합 변수로 키를 추측해서는 안 된다. 아래의 명시적인 이전
    // 키 대체 경로는 오래된 로컬 실행을 위해 유지한다.
  }
  return ''
}

Deno.serve(async (request: Request) => {
  try {
    // Browsers send this unauthenticated preflight before the actual POST.
    // Handle it before bearer validation; the POST path below still requires a
    // verified token and never treats OPTIONS as an account-deletion request.
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders })
    }

    if (request.method !== 'POST') {
      return json({ error: 'method_not_allowed' }, 405)
    }

    const token = bearerToken(request)
    if (token == null) return json({ error: 'unauthorized' }, 401)

    let rawBody: unknown
    try {
      rawBody = await request.json()
    } catch (_) {
      return json({ error: 'invalid_request' }, 400)
    }
    if (
      rawBody == null ||
      typeof rawBody !== 'object' ||
      Array.isArray(rawBody)
    ) {
      return json({ error: 'invalid_request' }, 400)
    }
    const body = rawBody as { confirmation?: unknown }
    if (body.confirmation !== confirmationPhrase) {
      return json({ error: 'confirmation_required' }, 400)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    // Auth 검증에는 공개 키를 사용하고, 권한 있는 삭제는 아래 관리자
    // 클라이언트로 격리한다. 이 값들은 Edge 환경에만 주입된다.
    const publicKey =
      defaultKey('SUPABASE_PUBLISHABLE_KEYS') ||
      Deno.env.get('SUPABASE_PUBLISHABLE_KEY') ||
      Deno.env.get('SUPABASE_ANON_KEY') ||
      ''
    const serviceKey =
      defaultKey('SUPABASE_SECRET_KEYS') ||
      Deno.env.get('SUPABASE_SECRET_KEY') ||
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ||
      ''
    if (!supabaseUrl || !publicKey || !serviceKey) {
      return json({ error: 'server_not_configured' }, 500)
    }

    // getUser(token)이 Auth 서비스에 대해 JWT를 검증한다. 요청 본문에 담긴
    // 사용자 ID나 수정 가능한 사용자 메타데이터를 신뢰하지 않는다.
    const authClient = createClient(supabaseUrl, publicKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    })
    const { data, error: authError } = await authClient.auth.getUser(token)
    if (authError || data.user == null) return json({ error: 'unauthorized' }, 401)

    // Fetch the caller-scoped, display-only deletion summary before invoking the
    // privileged Auth admin API.  The RPC runs with the verified caller JWT and
    // never accepts a user ID from the request body.
    const { data: summary, error: preflightError } = await authClient.rpc(
      'account_deletion_preflight',
    )
    // Treat the RPC result as an untrusted protocol boundary.  The same
    // fail-closed shape is parsed by Flutter before rendering: every count is
    // a non-negative integer, every group has the required display/lifecycle
    // fields, and the three group lists are a disjoint, complete partition.
    // Never call the privileged Auth API for malformed or contradictory data.
    if (preflightError || !isValidDeletionSummary(summary)) {
      // Do not claim success when the preflight could not be evaluated.  The
      // provider error is intentionally kept out of the response.
      return json({ error: 'preflight_failed' }, 500)
    }

    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })
    const { error: deleteError } = await adminClient.auth.admin.deleteUser(
      data.user.id,
    )
    if (deleteError) {
      // 제공자 세부 정보, 사용자 ID, 키 자료를 앱에 반환하지 않는다.
      return json({ error: 'delete_failed' }, 500)
    }

    return json({ deleted: true, summary })
  } catch (_) {
    // Provider/network failures must never leak details or masquerade as a
    // successful deletion.  Keep the generic response CORS-compatible.
    return json({ error: 'internal_error' }, 500)
  }
})
