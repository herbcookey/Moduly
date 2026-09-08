import { createClient } from 'npm:@supabase/supabase-js@2.50.0'
import { isValidDeletionSummary } from './preflight_validator.mjs'

const confirmationPhrase = '계정 삭제'
// Flutter 웹은 이 네 헤더와 함께 단순 요청이 아닌 POST를 보낸다. 광범위한
// 프로젝트 전체 정책을 상속하지 않고 허용 목록을 이 함수의 실제 엔드포인트로
// 한정한다. 엔드포인트가 모든 POST를 명시적인 Bearer 토큰으로 인증하므로 자격
// 증명 없는 와일드카드 출처는 여기에서 안전하다. 자격 증명을 포함한 교차 출처
// 요청은 의도적으로 허용하지 않는다.
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
    // 브라우저는 실제 POST 전에 인증되지 않은 이 사전 요청을 보낸다. Bearer
    // 검증 전에 처리하되, 아래 POST 경로에는 여전히 검증된 토큰이 필요하며
    // OPTIONS를 계정 삭제 요청으로 취급하지 않는다.
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

    // 권한 있는 Auth 관리자 API를 호출하기 전에 호출자 범위의 표시 전용 삭제
    // 요약을 가져온다. RPC는 검증된 호출자 JWT로 실행하며 요청 본문에서 사용자
    // ID를 받지 않는다.
    const { data: summary, error: preflightError } = await authClient.rpc(
      'account_deletion_preflight',
    )
    // RPC 결과를 신뢰할 수 없는 프로토콜 경계로 취급한다. Flutter도 렌더링 전에
    // 동일한 실패 시 차단 형태를 파싱한다. 모든 개수는 음이 아닌 정수여야 하고,
    // 모든 그룹에는 필수 표시/수명 주기 필드가 있어야 하며, 세 그룹 목록은 서로
    // 겹치지 않는 완전한 분할이어야 한다. 형식이 잘못되었거나 모순된 데이터에는
    // 권한 있는 Auth API를 절대 호출하지 않는다.
    if (preflightError || !isValidDeletionSummary(summary)) {
      // 사전 검사를 평가하지 못했을 때 성공으로 알리지 않는다. 제공자 오류는
      // 의도적으로 응답에 포함하지 않는다.
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
    // 제공자/네트워크 실패는 세부 정보를 노출하거나 삭제 성공으로 가장해서는
    // 안 된다. 일반 응답이 CORS와 호환되도록 유지한다.
    return json({ error: 'internal_error' }, 500)
  }
})
