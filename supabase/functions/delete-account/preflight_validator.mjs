// account_deletion_preflight()용 순수 런타임 중립 검증기다. CI에서 Node로 실행할
// 수 있도록 이 모듈에는 Edge/런타임 import를 넣지 않는다. 허용하는 형태는
// lib/repositories/account_deletion_repository.dart의
// AccountDeletionImpact.fromJson과 의도적으로 동일하게 맞춘다.

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function hasOwn(record, key) {
  return Object.prototype.hasOwnProperty.call(record, key)
}

function isRequiredString(value) {
  return typeof value === 'string' && value.trim().length > 0
}

function parseNonNegativeInteger(value) {
  if (typeof value === 'number') {
    return Number.isSafeInteger(value) && value >= 0 ? BigInt(value) : null
  }
  // 클라이언트 파서에서 사용하는 Dart의 int.tryParse는 정수 문자열을 허용한다.
  // BigInt를 사용하면 반올림된 안전하지 않은 JavaScript 숫자를 조용히 허용하지 않는다.
  if (typeof value !== 'string' || !/^[+-]?\d+$/.test(value)) return null
  try {
    const parsed = BigInt(value)
    return parsed >= 0n ? parsed : null
  } catch (_) {
    return null
  }
}

function isRequiredNonNegativeInteger(value) {
  return parseNonNegativeInteger(value) !== null
}

function isDateTimeString(value) {
  if (typeof value !== 'string' || value.trim().length === 0) return false
  // Date.parse만 사용하면 "0" 같은 임의의 짧은 문자열도 허용한다.
  // 클라이언트의 DateTime.tryParse는 ISO 형식과 비슷한 날짜 접두사를 기대한다.
  if (!/^\d{4}-\d{2}-\d{2}(?:$|[Tt ])/.test(value.trim())) return false
  return Number.isFinite(Date.parse(value))
}

function isValidGroup(value) {
  if (!isRecord(value)) return false
  for (const key of [
    'id',
    'name',
    'timezone',
    'version',
    'status',
    'member_count',
    'membership_count',
  ]) {
    if (!hasOwn(value, key)) return false
  }
  const memberCount = parseNonNegativeInteger(value.member_count)
  const membershipCount = parseNonNegativeInteger(value.membership_count)
  if (
    !isRequiredString(value.id) ||
    !isRequiredString(value.name) ||
    !isRequiredString(value.timezone) ||
    !isRequiredNonNegativeInteger(value.version) ||
    memberCount === null ||
    membershipCount === null
  ) {
    return false
  }
  if (
    value.status !== 'active' &&
    value.status !== 'archived'
  ) {
    return false
  }
  if (memberCount > membershipCount) return false

  const deletedAt = value.deleted_at
  if (deletedAt !== undefined && deletedAt !== null && !isDateTimeString(deletedAt)) {
    return false
  }
  const hasDeletedAt = deletedAt !== undefined && deletedAt !== null
  // Dart 파서의 `(status == 'active') != (deletedAt == null)` 가드가 요구하는
  // 그대로, 소프트 삭제 표시가 없거나 null일 때만 활성 상태다.
  return (value.status === 'active') === !hasDeletedAt
}

function isUniqueGroupList(value) {
  if (!Array.isArray(value)) return false
  if (!value.every(isValidGroup)) return false
  const ids = value.map((group) => group.id)
  return new Set(ids).size === ids.length
}

function canonicalGroup(value) {
  const deletedAt = value.deleted_at
  const parsedDeletedAt =
    deletedAt === undefined || deletedAt === null
      ? null
      : new Date(Date.parse(deletedAt)).toISOString()
  return JSON.stringify({
    id: value.id,
    name: value.name,
    timezone: value.timezone,
    version: parseNonNegativeInteger(value.version).toString(),
    status: value.status,
    member_count: parseNonNegativeInteger(value.member_count).toString(),
    membership_count: parseNonNegativeInteger(value.membership_count).toString(),
    deleted_at: parsedDeletedAt,
  })
}

/**
 * 완전하고 내부적으로 일관된 사전 검사 요약에만 true를 반환한다.
 * 이 함수는 예외를 던지거나 사용자 제공 개인정보가 포함될 수 있는 페이로드
 * 내용을 기록하지 않는다. true를 반환하지 않으면 호출자는 Auth 관리자 삭제를
 * 실행해서는 안 된다.
 */
export function isValidDeletionSummary(value) {
  try {
    if (!isRecord(value)) return false
    for (const key of [
      'owned_groups',
      'active_owned_groups',
      'archived_owned_groups',
      'groups',
      'events',
      'invites',
      'memberships',
    ]) {
      if (!hasOwn(value, key)) return false
    }

    const owned = value.owned_groups
    const active = value.active_owned_groups
    const archived = value.archived_owned_groups
    if (
      !isUniqueGroupList(owned) ||
      !isUniqueGroupList(active) ||
      !isUniqueGroupList(archived) ||
      !isRequiredNonNegativeInteger(value.groups) ||
      !isRequiredNonNegativeInteger(value.events) ||
      !isRequiredNonNegativeInteger(value.invites) ||
      !isRequiredNonNegativeInteger(value.memberships)
    ) {
      return false
    }

    const groupCount = parseNonNegativeInteger(value.groups)
    if (groupCount === null || groupCount !== BigInt(owned.length)) {
      return false
    }
    if (owned.length !== active.length + archived.length) return false

    const ownedIds = new Set(owned.map((group) => group.id))
    const activeIds = new Set(active.map((group) => group.id))
    const archivedIds = new Set(archived.map((group) => group.id))
    if (
      activeIds.size !== active.length ||
      archivedIds.size !== archived.length
    ) {
      return false
    }
    for (const id of activeIds) {
      if (!ownedIds.has(id) || archivedIds.has(id)) return false
    }
    for (const id of archivedIds) {
      if (!ownedIds.has(id)) return false
    }
    if (activeIds.size + archivedIds.size !== ownedIds.size) return false
    for (const id of ownedIds) {
      if (!activeIds.has(id) && !archivedIds.has(id)) return false
    }
    if (active.some((group) => group.status !== 'active')) return false
    if (archived.some((group) => group.status !== 'archived')) return false

    // RPC는 같은 그룹을 세 번 직렬화한다. 모순된 이름/개수/버전이 사전 검사
    // 경계를 통과하지 못하도록 각 분할 항목의 ID/상태뿐 아니라 클라이언트에
    // 보이는 모든 필드를 비교한다.
    const ownedCanonical = new Map(
      owned.map((group) => [group.id, canonicalGroup(group)]),
    )
    for (const group of [...active, ...archived]) {
      if (ownedCanonical.get(group.id) !== canonicalGroup(group)) return false
    }
    return true
  } catch (_) {
    // 예상하지 못한 객체/프록시/getter는 프로토콜 실패로 취급하며, 권한 있는
    // 삭제 호출에 절대 도달하게 해서는 안 된다.
    return false
  }
}

// 이름 있는 별칭을 두어 Edge 핸들러가 사용하는 단일 조건자를 바꾸지 않고도
// 순수 계약을 쉽게 찾을 수 있게 한다.
export const validateDeletionSummary = isValidDeletionSummary
export const validatePreflightSummary = isValidDeletionSummary
