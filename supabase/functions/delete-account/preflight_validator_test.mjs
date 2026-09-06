import assert from 'node:assert/strict'
import { isValidDeletionSummary } from './preflight_validator.mjs'

const active = {
  id: 'group-active',
  name: 'Active group',
  timezone: 'UTC',
  version: 2,
  status: 'active',
  member_count: 2,
  membership_count: 3,
  deleted_at: null,
}
const archived = {
  id: 'group-archived',
  name: 'Archived group',
  timezone: 'Asia/Seoul',
  version: 4,
  status: 'archived',
  member_count: 0,
  membership_count: 2,
  deleted_at: '2026-01-02T03:04:05.000Z',
}

const validSummary = {
  owned_groups: [active, archived],
  active_owned_groups: [active],
  archived_owned_groups: [archived],
  groups: 2,
  events: 3,
  invites: 1,
  memberships: 5,
}

assert.equal(isValidDeletionSummary(validSummary), true)
assert.equal(
  isValidDeletionSummary({
    ...validSummary,
    groups: '-1',
  }),
  false,
)
assert.equal(
  isValidDeletionSummary({
    ...validSummary,
    active_owned_groups: [archived],
  }),
  false,
)
assert.equal(
  isValidDeletionSummary({
    ...validSummary,
    active_owned_groups: [
      { ...active, name: 'Contradictory active name' },
    ],
  }),
  false,
)
assert.equal(
  isValidDeletionSummary({
    ...validSummary,
    owned_groups: [active, active],
  }),
  false,
)
assert.equal(
  isValidDeletionSummary({
    ...validSummary,
    archived_owned_groups: [
      { ...archived, deleted_at: null },
    ],
  }),
  false,
)
assert.equal(
  isValidDeletionSummary({
    ...validSummary,
    active_owned_groups: [
      { ...active, member_count: 4, membership_count: 3 },
    ],
  }),
  false,
)
assert.equal(
  isValidDeletionSummary({
    ...validSummary,
    events: Number.POSITIVE_INFINITY,
  }),
  false,
)
