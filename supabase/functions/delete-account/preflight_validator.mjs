// Pure, runtime-neutral validator for account_deletion_preflight().  Keep this
// module free of Edge/runtime imports so it can be exercised with Node in CI.
// Its accepted shape intentionally mirrors AccountDeletionImpact.fromJson in
// lib/repositories/account_deletion_repository.dart.

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
  // Dart's int.tryParse (used by the client parser) accepts integer strings;
  // BigInt avoids silently accepting a rounded unsafe JavaScript number.
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
  // Date.parse alone accepts arbitrary short strings (for example "0").
  // DateTime.tryParse on the client expects an ISO-like calendar prefix.
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
  // Active iff the soft-delete marker is absent/null, exactly as the Dart
  // parser's `(status == 'active') != (deletedAt == null)` guard requires.
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
 * Return true only for a complete, internally consistent preflight summary.
 * This function never throws and never logs payload contents (which may carry
 * user-provided PII).  Callers must not invoke Auth admin deletion unless it
 * returns true.
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

    // The same group is serialized three times by the RPC.  Compare all
    // client-visible fields for each partition entry, not just IDs/status, so
    // a contradictory name/count/version cannot pass the preflight boundary.
    const ownedCanonical = new Map(
      owned.map((group) => [group.id, canonicalGroup(group)]),
    )
    for (const group of [...active, ...archived]) {
      if (ownedCanonical.get(group.id) !== canonicalGroup(group)) return false
    }
    return true
  } catch (_) {
    // An unexpected object/proxy/getter must be treated as protocol failure,
    // never allowed to reach the privileged deletion call.
    return false
  }
}

// Named aliases make the pure contract easy to discover without changing the
// single predicate used by the Edge handler.
export const validateDeletionSummary = isValidDeletionSummary
export const validatePreflightSummary = isValidDeletionSummary
