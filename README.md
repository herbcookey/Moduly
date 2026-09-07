# Moduly

Moduly is a small, multi-platform Flutter planner backed by Supabase. The
repository contains the database contract and a development profile for a
self-hosted Supabase stack. The Supabase service is deliberately **not**
installed or started as part of this repository setup.

## Architecture and security

The Flutter client uses the public Supabase URL and publishable (anon) key only. Auth is
handled by `auth.users`; a trigger creates one `public.profiles` row per user.
The application tables are:

| Table | Purpose |
| --- | --- |
| `profiles` | Display name, avatar URL, and IANA timezone. |
| `groups` | Planner workspace and immutable owner, with an optional description, version, and soft-delete marker. |
| `memberships` | Owner/member role and active/inactive membership history. |
| `invite_codes` | Expiring, revocable, max-use invite metadata. Only a SHA-256 token hash is stored. |
| `events` | Group events with UTC `timestamptz` boundaries, IANA timezone, all-day date range, and an unsigned ARGB color value. |
| `audit_logs` | Append-only lifecycle audit records (minimal metadata). |
| `invite_join_attempts` | Private rolling-window rate-limit ledger for invite attempts. |
| `event_recurrence_rules` | Additive daily/weekly/monthly rule for an existing event series anchor. |
| `event_occurrence_overrides` | Sparse, versioned exceptions and tombstones keyed by stable occurrence identity. |

Every public table has RLS enabled. Policies derive identity from
`auth.uid()`: active members can see active group data, owners control invites
and membership status, and only an event's `created_by` can update or soft
delete that event. Hard deletes are not granted to authenticated clients.

Invite creation and joining are security-definer RPCs. `create_invite_code`
returns a random token once and stores only its digest. The transactional
`join_group_with_invite` RPC locks the invite row, checks expiry/revocation/max
uses, serializes attempts per user, and upserts the membership atomically.
`soft_delete_event_if_version`, `archive_group_if_version`, and
`revoke_invite_code` require the expected optimistic-lock version. Direct
event/group/invite updates must also send `version = old_version + 1`; a
trigger rejects stale or skipped versions.

Timed event instants are UTC `timestamptz`. For all-day events,
`all_day_start`/`all_day_end` is a half-open local date range
`[start, end)`, and `starts_at`/`ends_at` are the corresponding local-midnight
UTC instants in the event's IANA timezone.

Group descriptions are optional text persisted by `create_group`, default to the
empty string, and are limited to 10,000 characters. Event `color_value` is an
unsigned 32-bit ARGB integer (`0` through `4,294,967,295`) with a default of
`4,282,874,742` (`0xff477b76`); create, update, and realtime event payloads
preserve this value.

### Group management and account deletion

The Members screen exposes owner-only group name/description/IANA-timezone
updates through `update_group_if_version`, ownership transfer through
`transfer_group_ownership`, and terminal archive through
`archive_group_if_version`. All three RPCs use the group's optimistic-lock
`version`; a stale response is shown as a Korean conflict message and the
draft/target remains in its dialog. Active non-owners can confirm **Leave
group** (`leave_group`). Owners cannot leave until they transfer ownership or
archive the group. The UI filters transfer targets to active non-owner
members, asks for a second confirmation, and requires the exact group name to
archive. RLS keeps these operations owner/member scoped; authenticated clients
do not receive direct ownership or presentation-column UPDATE privileges.

Account deletion first calls the authenticated `account_deletion_preflight()`
RPC. Its typed JSON summary lists owned active and archived groups (including
member counts) and the cascade counts for groups, events, invite codes, and
memberships. The Edge Function validates that same summary and only accepts a
successful `{ "deleted": true, "summary": ... }` body after JWT verification;
the Auth Admin delete then cascades owned/authored rows according to the
account-deletion migration. The confirmation screen clearly states that the
cascade is permanent and links back to group management when an active owned
group should be transferred or archived first. Local/configuration-blocked
builds report that this capability requires a connected server; they never
claim a local account was deleted.

### Event participants (Feature 5)

Migration `supabase/migrations/20260907130002_event_members.sql` adds the
additive `public.event_members` relation. It stores one `(event_id, user_id)`
assignment per row, records `created_at`, and has cascading foreign keys to
`events` and `auth.users`, plus a user-leading index for account cleanup. The
migration backfills each existing event's creator at the event's original
`created_at` before installing the integrity and transition triggers; the
guarded insert is safe to reapply. Soft-deleted events and archived groups keep
their child rows for history, but RLS hides them. Hard event, group, or account
deletion cascades the child rows.

Authenticated clients have read-only table privileges. The select policy
requires the requester to be an active member of the live event's group and
the assigned user to be an active, non-removed member of that same group.
Direct child INSERT/UPDATE/DELETE is denied; the authenticated RPCs are the
only write path. `create_event_with_members` and
`update_event_with_members_if_version` validate every target against the same
live-group membership while holding the group/event locks. A new event with a
omitted or `null` `member_ids` input defaults to its active creator; an
explicitly supplied empty list creates an event with no participants. An empty
list on an update or replacement intentionally clears all assignments.

Event-body edits remain creator-only. `replace_event_members_if_version` lets
the active event creator or current active group owner replace the participant
list, but the group owner cannot change another creator's title, note, times,
color, or delete the event. A participant assignment never grants body or
delete permission. Every changed list advances the event version exactly once;
an unchanged canonical set is an idempotent no-op and does not create a version
or realtime transition. Stale versions, inactive/cross-group targets, deleted
events, and inactive actors fail atomically without a partial child update.

When an ordinary member leaves or an owner deactivates that member, current
assignments are pruned and each affected live parent event is version-bumped
once. Those post-migration lifecycle removals are not restored by rejoining or
reactivating. The historical creator rows inserted by the migration are an
intentional exception: an inactive creator's backfilled row is merely hidden by
RLS and can become visible if that membership is later reactivated. The local
adapter preserves the same omitted/`null` creator default versus explicit-empty
assignment distinction, active-member/same-group checks, and no-op semantics;
the Supabase adapter passes that distinction to the participant-aware RPCs and
canonicalizes their `member_ids` response. Event streams read parent `events`
rows and then batch-read visible child assignments. `event_members` is
deliberately **not**
published to `supabase_realtime`: parent-event version invalidation drives the
refresh, while child DELETE payloads could expose UUIDs that DELETE/RLS
authorization cannot safely verify.

The editor shows active members as keyboard/focusable checkbox rows (at least
48 px) and keeps a stale assignment as the neutral Korean label `이전 멤버`
until an authoritative event refresh removes it. Creators edit body and
participants together; a new event initially selects its creator, but the
creator may clear every checkbox to leave the participant list empty. Group
owners see participant-only controls; ordinary members can view but cannot
save. Home uses the participant-specific filter
(`모든 참여자`), renders accessible names/counts/compact avatars, and uses the
same neutral fallback for inactive or unknown assignments. The participant
list is parent-scrollable rather than a nested unbounded list, and the editor
is covered for 320x568 layouts, 2x text, and a 300 px bottom keyboard inset.

### Calendar views and bounded ranges (Feature 1)

Home keeps the existing daily week strip, swipe navigation, event cards, participant
filter, routes, and add-event action. The toolbar adds accessible `일간`, `월간`,
and `Agenda` modes, previous/next period controls, `오늘`, and a date picker.
Month mode uses a Monday-first 35/42-cell grid; each cell remains individually
focusable/tappable, reports its date and event count to assistive technology, and
shows event dots or compact titles. Agenda mode groups the selected calendar month
by the first overlapping group-timezone date, puts all-day events before timed
events, and sorts timed rows by UTC start and id. A cross-midnight event appears
once with a next-day marker. Selecting a month cell or picker date changes the
selected day without changing the current mode; cancelling the picker is a no-op.

Calendar boundaries are based on the selected group's IANA timezone, not the
device timezone. Every read is a half-open `[start, end)` UTC range produced from
local calendar midnights, so DST transition days can be 23 or 25 hours. The
`supabase/migrations/20260907130003_calendar_range.sql` migration adds the
participant-aware `events_for_range` RPC with a bounded limit and a keyset cursor
over `(starts_at, id)`. Timed events use UTC overlap while all-day events use their
half-open local date range. `PlannerController` replaces the current range when
the group, mode, date, or participant filter changes; `더 불러오기` follows the
cursor and never downloads an unbounded group history. A same-range refresh keeps
the last good list visible while the new page is in flight and reports a retryable
error if the read fails.

The Local and Supabase adapters implement the same range and cursor contract. A
parent `events` Realtime invalidation schedules a range refetch; child participant
rows are intentionally not published. This avoids exposing DELETE payloads that
RLS cannot safely authorize, while still reflecting participant changes after the
parent version changes. The UI has no offline-sync promise: an offline banner or
last-good snapshot is informational only, and a failed range must be retried when
connectivity returns.

For a release check, run `supabase db reset` (or the reviewed migration job),
enable Realtime for the parent `events` table, and run the credential-free checks:

```sh
flutter test --no-pub test/calendar_views_ui_test.dart \
  test/controller_test.dart test/timezone_test.dart
flutter analyze --no-pub
```

Against a disposable Supabase/Auth deployment, create a group with a DST-observing
timezone and a dataset of 1,000+ events. Verify the day/month/Agenda pages return
only their half-open range, keyset paging has no duplicates/gaps, a participant
filter resets the cursor, and a parent event INSERT/UPDATE/soft-delete causes one
coalesced refetch. Change an event in a second authenticated session and confirm
the first session updates without a child-table Realtime payload. Repeat the
manual checks on a 320x568 viewport with 2x text, a 300 px keyboard inset, hardware
keyboard focus, VoiceOver/TalkBack, and both 35- and 42-cell months. These live
Supabase, load, network, and real-device checks are external to this repository
and are not claimed as executed here.

### Recurring events (Feature 2)

Recurring data is additive: the existing `events.id` remains the logical
series anchor, while a materialized occurrence carries the same anchor id and
an opaque, stable `occurrence_key`. Legacy single events keep the `single`
key and the `/event/:id` route. Occurrences are expanded only inside the
requested bounded calendar range, with a defensive cap; the client never
creates an unbounded row set.

The editor places `반복` immediately after the time fields. It supports
`매일`, `매주`, and `매월`, a 1–999 interval, ISO Monday-first weekday chips,
repeat count, or an inclusive end date. Weekly creation selects the DTSTART
weekday by default. Monthly rules preserve the requested day and clamp to the
last day in shorter months; the notice in the editor states this explicitly.
The live Korean summary is announced to screen readers and is reused on day,
month, and Agenda cards as a repeat badge.

Editing or deleting an occurrence always opens a scrollable radio confirmation
with the safest default, `이번 일정만`. The other choices are `이번 일정과
이후` and `전체 일정`; cancelling or dismissing the dialog is a no-op. The
future/all copy warns that existing exceptions can be reset. Participant
assignments are series-wide inherited fields: they are shown on every
occurrence and can change only when the full series scope is selected. Title,
memo, color, timezone, duration, and all-day boundaries follow the same
series/exception inheritance contract, and a committed mutation is followed
by an authoritative bounded refresh rather than a client-side fan-out.

For a credential-free UI check run:

```sh
flutter test --no-pub test/recurrence_ui_test.dart \
  test/recurrence_accessibility_test.dart
flutter analyze --no-pub
```

On a disposable Auth/Postgres deployment, also verify a daily rule across a
DST transition, a monthly day 29–31 across short months, all-day boundaries,
this/future/all exception deletion, stale-version rejection, and duplicate-free
range paging. Repeat the UI checks at 320x568, 2x text, a 300 px keyboard
inset, hardware keyboard focus, and VoiceOver/TalkBack. These live service and
real-device checks are external to this checkout and are not claimed as run.

### Local reminders (Feature 3)

This stage ships device-local reminders only. The dependency is pinned to
`flutter_local_notifications: 22.3.0`; that release requires the pinned
`timezone: 0.11.1`, which keeps all event wall-time and DST calculations on the
same IANA database used by the planner. Android reminders use the
`inexactAllowWhileIdle` schedule mode, so the operating system may deliver a
reminder a little later under Doze or battery policy. Exact-alarm permissions
(`SCHEDULE_EXACT_ALARM` and `USE_EXACT_ALARM`) are intentionally not requested.

The local scheduler reads only a bounded `[now, now + 60 days)` event window and
keeps at most 48 upcoming fire times per device, ordered by fire time. A later
occurrence is scheduled when the app next reconciles its local snapshot; this is
not an offline-sync promise. Once a reminder is committed to the operating
system, it can be displayed without a network connection, subject to the
platform's permission, reboot, battery, and delivery rules. A timed reminder
subtracts its lead from the persisted UTC instant. An all-day reminder is
computed at 09:00 on the event's IANA timezone and subtracts whole civil days,
never device-timezone midnight.

The Settings screen separates the account switch, this-device permission, and
server-push capability. Permission prompts happen only after an explicit
`알림 켜기` action; returning from system settings rechecks the status. Android
requires `POST_NOTIFICATIONS` on API 33+, while iOS/macOS local reminders use
the UserNotifications permission. Web, Windows, and Linux report local
reminders as unsupported in this stage. No notification title, memo, email,
member name, or token is copied into an operating-system payload; a tap carries
only an opaque event id and validated occurrence key and then reloads the
authoritative event after authentication and membership checks.
The local/demo repository uses human-readable seed IDs, so native scheduling
and notification taps remain `unconfigured` until a configured Supabase
deployment supplies UUID-backed event data; demo controls never claim OS
delivery success.

Server push is deliberately `unconfigured` here. Enabling it later requires a
real Firebase project and generated identifiers, APNs Push capability plus a
`.p8` key/Key ID/Team ID, web HTTPS service-worker registration and a public
VAPID key, and a trusted server worker/cron with provider credentials. Those
values must stay in provider/CI secret storage and are never added to this
repository or Flutter client. The future worker should claim jobs with a lease,
deduplicate by `(user, device, event, occurrence_key, reminder, method)`, and
retry with bounded backoff. Delivery is therefore at-least-once rather than an
exactly-once guarantee; an invalid provider token must be revoked privately.
The `send-reminders` Edge Function has `verify_jwt = false` because it is called
by a scheduler, so every request must carry the non-empty
`x-reminder-worker-secret` header matching the deployment-only
`REMINDER_WORKER_SECRET`; the worker checks this secret before capability or
claim RPCs. Keep that value in the Edge/CI secret store and never put it in the
Flutter client, logs, or checked-in configuration.

Credential-free checks for this slice are:

```sh
flutter pub get
flutter test --no-pub test/notification_platform_static_test.dart \
  test/notification_settings_ui_test.dart \
  test/event_notification_controls_test.dart \
  test/notification_deep_link_static_test.dart
flutter analyze --no-pub
```

The native permission, reboot, Doze/Focus, lock-screen privacy, and DST checks
require real Android/iOS/macOS devices and are manual release checks. Firebase,
APNs, VAPID, service-worker, worker/cron, and signed-release configuration are
external blockers until an operator supplies the corresponding project and
signing metadata.

### Event search (Feature 7)

Event search is a server-side, active-group projection. It searches title and
description with literal matching (not a client-side scan or fuzzy index), and
also supports a bounded local-date period plus independent active-member
creator and participant filters. An empty query intentionally means
period/filter-only search; a non-empty query is 2–100 Unicode scalar values and
at most 400 UTF-8 bytes. The selected group's IANA timezone defines the
half-open date range; the UI's inclusive end date is converted to the next
local midnight and the range may cover at most 366 calendar days.

The `search_events_v1` RPC returns complete event/occurrence rows in bounded
pages (50 by default) with an opaque keyset cursor over
`(starts_at,event_id,occurrence_key)`. Effective recurring occurrence fields,
including overrides and stable occurrence identity, are retained so selecting
a result opens the exact event and occurrence. Search results never alter the
calendar range snapshot or its cursor. Typing is debounced; cancelling,
switching users/groups/filters, and stale responses are fenced by the
controller generation.

The RPC checks authentication, group existence/lifecycle, and active
membership before searching or counting. Outsiders, inactive members,
archived groups, and missing groups receive the same unavailable response, and
creator/participant IDs must be active members of that group. Its public
execution is revoked for `public`/`anon` and granted only to `authenticated`;
the function uses an empty `search_path`. No title, description, member data,
or query is placed in a URL or log. Results can be opened at `/event/:id` or
`/event/:seriesId?occurrence=...`, with the selected day updated in the group
timezone.

Credential-free checks for this slice are:

```sh
flutter test --no-pub test/event_search_core_test.dart \
  test/event_search_ui_test.dart \
  test/sql_event_search_static_test.dart
flutter analyze --no-pub
bash supabase/tests/run_event_search_upgrade.sh
```

The upgrade runner applies the migration on an isolated local PostgreSQL
cluster, re-applies it for idempotence, and executes the `event_search.sql`
fixture with real authenticated-role claims (or its assertion fallback when
pgTAP is unavailable). For release verification, run `supabase db reset` on a
disposable Auth/Postgres deployment, create owner/member/inactive/outsider
accounts, and repeat the RLS denial, Unicode/special-character, date/DST,
creator/participant, and 1,000+ row no-gap/no-duplicate cursor checks with
real JWTs. Exercise debounce/cancel/retry and exact occurrence navigation in
the Flutter app, then repeat at 320x568 with 2x text, a 300 px keyboard inset,
hardware focus, VoiceOver/TalkBack, and web/native targets. These live
service, load, network, and real-device checks are external to this checkout
and are not claimed as executed here.

## Flutter development

1. Keep `.env.example` as the checked-in placeholder reference. For Flutter
   3.44 or newer, copy it to an ignored `.env.local` file and replace the two
   public values with the deployment values. Set `INVITE_BASE_URL` only when
   the operator owns a public HTTPS origin that serves the Flutter app:

   ```sh
   cp .env.example .env.local
   ```

   The checked-in example uses Flutter's `.env` key-value format. Flutter 3.44+
   accepts either this format or a JSON object with the same three keys when
   loading `--dart-define-from-file`. Never put a service-role key, database
   password/URI, or any other server-only credential in Flutter, source control,
   or a mobile binary.
2. Install Flutter dependencies and run the app with compile-time values loaded
   from that ignored file:

   ```sh
   flutter pub get
   flutter run --dart-define-from-file=.env.local
   ```

   For a local web callback test, run Chrome on the port allowed by the checked-in
   Supabase profile:

   ```sh
   flutter run -d chrome --web-port 3000 \
     --dart-define-from-file=.env.local
   ```

   `--dart-define-from-file` accepts either `.env` key-value or JSON files;
   `.env.local` is ignored by the repository's `.gitignore`. You can still use
   individual `--dart-define` flags when a different local secret manager
   supplies the values.

3. Use the API addresses below when the Supabase API is bound to the host:

   | Client | API URL |
   | --- | --- |
   | iOS simulator | `http://127.0.0.1:54321` |
   | Android emulator | `http://10.0.2.2:54321` |
   | Physical iOS/Android device | `http://<developer-LAN-IP>:54321` for local-only testing |

   These HTTP addresses are for local-only testing. Android cleartext policy
   and iOS App Transport Security may block them, especially in release
   profiles; prefer an HTTPS reverse proxy or tunnel when possible. If local
   HTTP is unavoidable, use an explicitly debug-only transport exception and
   remove it from store builds. A physical device must be able to route to the
   development host. For a shared device, staging, or production, use an HTTPS
   hostname and a trusted certificate; do not turn off certificate validation.

### Runtime configuration and release fail-closed behavior

Debug and profile builds may omit `SUPABASE_URL` and
`SUPABASE_PUBLISHABLE_KEY`; that deliberate preview path uses the in-memory
demo repositories. A release build requires both public values. If either is
missing, or if Supabase initialization fails, the app shows a Korean
configuration error gate and does not construct or use the local demo
repositories. The gate never displays secret values. Build production
artifacts with the real deployment values supplied through a protected build
environment, and use only the publishable (anon) key in the client.

### Android release signing

The Android application ID and Kotlin namespace are `com.herbcookey.moduly`.
The release build never uses the debug keystore. Create an upload keystore in
a secure location, copy the checked-in template, and fill in its values:

```sh
cp android/key.properties.example android/key.properties
keytool -genkeypair -v -keystore android/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias moduly
```

`android/key.properties` and `*.jks`/`*.keystore` files are ignored by git.
For CI, provide the equivalent values through
`MODULY_ANDROID_KEYSTORE_FILE`, `MODULY_ANDROID_KEYSTORE_PASSWORD`,
`MODULY_ANDROID_KEY_ALIAS`, and `MODULY_ANDROID_KEY_PASSWORD` instead. A
release build fails with an actionable error when any value or the keystore is
missing; debug and profile builds do not require a signing key.

## Self-hosted Supabase (Docker methodology)

Run these steps on a dedicated development/CI host that has Docker and the
Supabase CLI. They are instructions only; this checkout does not execute them.

```sh
# On the chosen host, from this repository:
supabase start                 # starts the local Docker stack
supabase status                # copy the API URL and publishable key into local env
supabase db reset              # applies migrations and supabase/seed.sql
```

For an existing self-hosted deployment, put the API behind a TLS reverse proxy
(Caddy, Nginx, or a managed load balancer), set the public site/redirect URLs
in the Auth service, and apply migrations with `supabase db push` (or the
deployment's reviewed migration job). Keep the database and Studio ports
private: Postgres `54322` and Studio `54323` should be bound to loopback or a
VPN/admin network, never exposed to the public internet. Expose only the API
port through the reverse proxy, rotate JWT/database secrets, and keep backups
and logs outside the mobile client.

The checked-in `supabase/config.toml` documents the local ports and Auth
redirects. The first reset on a fresh stack may have no users, so the seed
prints a notice and skips demo rows. Sign up one local user, then run
`supabase db seed` (or execute `supabase/seed.sql`) to create the demo group
and all-day event without resetting the auth user.

### 계정 삭제 Edge Function

`supabase/functions/delete-account`는 로그인 사용자의 Bearer 토큰을
`auth.getUser(token)`으로 직접 검증한 뒤, Edge 환경에만 있는 Auth Admin
키로 계정을 삭제합니다. Flutter 앱에는 publishable 키만 넣습니다. 2026년
키 환경에서는 기본 키를 JSON으로 설정합니다(예시는 자리표시자입니다).

```sh
supabase secrets set \
  SUPABASE_PUBLISHABLE_KEYS='{"default":"sb_publishable_<public>"}' \
  SUPABASE_SECRET_KEYS='{"default":"sb_secret_<server-only>"}'
supabase functions deploy delete-account
```

구형 로컬 런타임에서는 `SUPABASE_PUBLISHABLE_KEY`/`SUPABASE_ANON_KEY`와
`SUPABASE_SECRET_KEY`/`SUPABASE_SERVICE_ROLE_KEY`를 대체 이름으로 사용할 수
있습니다. `supabase/config.toml`의 `verify_jwt = false`는 새 `sb_*` 키가
플랫폼의 기본 JWT 게이트와 호환되지 않을 수 있기 때문이며, 함수 내부의
`auth.getUser(token)` 검증을 우회한다는 뜻이 아닙니다. 서비스·시크릿 키는
Edge 비밀 저장소 밖으로 복사하거나 앱·Git에 넣지 마세요.

### Auth callback redirect allow-list

Native (iOS, Android, and macOS) email confirmation, password recovery, and
OAuth links return through the exact `moduly://auth-callback` custom URI scheme.
For a hosted Supabase project, add that exact value in **Dashboard →
Authentication → URL Configuration → Redirect URLs**, then save the setting.

On web, the client resolves the callback from the current browser origin and
uses `/auth-callback` (for example,
`https://planner.example.com/auth-callback` or
`http://localhost:3000/auth-callback`). Add each deployed origin/path that can
serve the app to the same Supabase Redirect URLs allow-list. The local CLI
profile already allows the localhost patterns in `supabase/config.toml`; add
any additional staging or production origins there when running a local stack.

The hosted web server must serve a direct request to `/auth-callback` (including
its query string) through the same Flutter `index.html` SPA fallback used for
the rest of the app. Without that rewrite, an OAuth or email return can become
a server 404 before Flutter starts. The resolver emits this callback at the
origin root, so a deployment under a subpath must provide an equivalent root
alias or otherwise expose the exact callback URL in its hosting configuration.

The allow-list is project configuration and cannot be changed by a SQL
migration or by the client. Keep the native custom-scheme entry in every
environment that ships a native app, and keep the web origin entries for every
hosted web deployment.

### Invite links and sharing

The owner sees a one-shot invite code after creating it. The dialog can copy
the formatted code or open the OS share sheet. A shareable URL is appended only
when `INVITE_BASE_URL` is a valid configured HTTPS origin; otherwise the app
shares the code alone. The Supabase API URL is never used as an application
origin, and this repository does not invent a production hostname. A listed
invite row has no plaintext token, so copy/share is intentionally available
only in the creation result.

Native fallback links use the registered `moduly://invite/<token>` scheme. The
existing `moduly://auth-callback` scheme remains separate for Supabase auth and
password recovery. The Flutter listener captures a link before Supabase auth
initialization completes, buffers cold-start values, and de-duplicates warm and
initial deliveries. Auth/recovery callback parameters always remain owned by
Supabase; invite preview and joining happen only after an authenticated user
explicitly confirms the group.

The web build uses Flutter's path URL strategy, so a direct
`https://<configured-origin>/invite/<token>` request and a refresh must be
rewritten by the hosting provider to the same `web/index.html` SPA entry. The
same rewrite is required for `/auth-callback` (including its query string).
The app removes the token from the browser route immediately and keeps it in a
short-lived pending invite state (memory, with best-effort tab-scoped
`sessionStorage` hydration so a login redirect can resume). It is never put in
query parameters, logs, analytics, or the public preview model. The current
build intentionally does not generate hash-style links; a host that cannot
provide SPA rewrites must add the rewrite before enabling web invite links.

Verified HTTPS links require operator-owned platform association files in
addition to the Flutter changes:

* Android App Links need a separate `https` intent filter with
  `android:autoVerify="true"`, the final host, and
  `https://<host>/.well-known/assetlinks.json` containing the
  `com.herbcookey.moduly` package and every release signing certificate's
  SHA-256 fingerprint. Verify on a device with
  `adb shell pm verify-app-links --re-verify com.herbcookey.moduly`.
* iOS Universal Links need `applinks:<host>` in the signed Associated Domains
  entitlement and `https://<host>/.well-known/apple-app-site-association`
  (no `.json` suffix or redirects) with the real Apple Team ID and
  `com.herbcookey.moduly` app ID. Each subdomain needs its own entitlement and
  association file.

No HTTPS intent filter, Apple entitlement, Team ID, association file, Windows
MSIX/registry entry, or Linux `.desktop` registration is checked in here until
the operator supplies the real host/signing metadata. Desktop custom-scheme
delivery therefore remains an installer responsibility; use the web URL or
manual code on unpackaged Windows/Linux builds.

### Desktop custom-scheme packaging

The macOS Runner registers `moduly` in `macos/Runner/Info.plist`, so packaged
macOS builds can receive the native callback. Windows registration is owned by
the installer: `app_links` documents protocol activation through a packaged
MSIX manifest, while unpackaged/debug runs require an explicit Windows runtime
or registry registration that this repository does not own. Linux similarly
requires application activation handling plus installer registration for the
`x-scheme-handler/moduly` MIME entry. Add those platform-specific installer
steps before shipping desktop deep links; this repository intentionally does not
ship a Windows MSIX/registry registration or a Linux `.desktop` file. Until
those installer steps exist, use the web callback on Windows/Linux and treat
native desktop callback support as unshipped.

The macOS sandboxed Release and Debug/Profile entitlements include
`com.apple.security.network.client` for Supabase's outbound HTTPS calls.
Preserve that entitlement in any signing override and smoke-test a signed build;
without it, a sandboxed macOS build cannot reach the configured service.

### Social login provider setup

The sign-in screen offers Google, Apple, and Kakao through Supabase
`signInWithOAuth`. Native builds send `moduly://auth-callback`; web builds send
the current origin plus `/auth-callback`. Provider client secrets must remain
in the Supabase Dashboard (or the local Supabase secret environment) and are
never compiled into Flutter or stored in this repository. Enable each provider
under **Dashboard → Authentication → Providers**, configure its client
ID/secret there, and allow-list the native and/or web callback URI described
above.

The app treats the browser launch result as provisional and waits for the
typed Supabase auth event before granting access. If a provider is disabled,
the browser launch fails, or the user cancels, the UI shows a Korean error and
does not create a demo session. Apple OAuth credentials require the provider's
normal Apple Developer setup and secret rotation; this browser-based OAuth
path does not add a native Apple entitlement or embed an Apple secret.

### iOS bundle and signing

The iOS application bundle identifier is `com.herbcookey.moduly`; the unit-test
bundle uses the `com.herbcookey.moduly.RunnerTests` family. `ios/Flutter/Debug.xcconfig`
and `Release.xcconfig` optionally include the ignored `Signing.xcconfig` file.
For a local Xcode account, copy `ios/Flutter/Signing.xcconfig.example` and set
`DEVELOPMENT_TEAM` to the Team ID shown by that account. Do not commit the
copied file or provisioning-profile details.

CI should inject the team at build time from a protected variable rather than
hard-coding an unverified Team ID:

```sh
xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/ios/archive/Runner.xcarchive \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID in CI}" \
  archive
```

Before a signing identity and matching provisioning profile are available,
verify the iOS release with `flutter build ios --release --no-codesign`.

### Privacy policy and terms before store submission

The Korean drafts in `docs/privacy-policy-ko.md` and
`docs/terms-of-service-ko.md` are also available inside the app from Settings
and from the logged-out login/sign-up screens. They intentionally do not claim
an operator identity, contact address, retention period, processor contract,
data region, cross-border transfer, or support URL that this repository cannot
verify. They are not legal advice.

Before publishing a store build, the actual operator should:

1. Review the data-flow statements against the deployed Supabase project and
   fill in the operator identity, address, real contact method, retention and
   deletion procedure, processor/subprocessor and region information, and any
   required age, paid-service, or jurisdiction terms.
2. Have the final text reviewed for the jurisdictions where the app will be
   offered. Keep the in-app copy and the hosted copy synchronized when the
   policy or terms change.
3. Publish both Markdown documents as public, static HTTPS pages on a
   domain/repository controlled by the operator (for example, an
   operator-owned static hosting project). Do not submit a guessed URL or a
   private repository URL; this checkout does not own a public policy host.
4. Open the final pages while logged out and add the actual privacy-policy
   page URL to the relevant store listing only after the host is deployed and
   the URL has been verified. The terms page may be linked from the same
   operator-controlled site and from the app.

No support URL is configured by this repository. The operator must provide a
real contact route before release rather than copying a placeholder.

## Migrations and static checks

- `supabase/migrations/202608110001_schema.sql` creates extensions, tables,
  constraints, indexes, triggers, profile/group-owner hooks, and audit writes.
- `supabase/migrations/202608110002_rls_rpc.sql` creates helper functions,
  RLS policies, least-privilege grants, invite/group/event/member RPCs, and
  rate limiting.
- `supabase/migrations/202608140003_account_deletion.sql` makes the
  authenticated account-deletion policy explicit in the ownership/authored-row
  foreign keys; apply it through the reviewed migration job before deploying
  the `delete-account` Edge Function.
- `supabase/migrations/20260906154329_persist_group_description_event_color.sql`
  backfills and constrains group descriptions and unsigned event colors, then
  replaces the `create_group` RPC with the description-aware signature and
  least-privilege grants.
- `supabase/migrations/20260907130001_group_management.sql` adds the
  race-safe single-owner invariant, versioned update/transfer/archive/leave
  RPCs, and the authenticated `account_deletion_preflight()` JSON contract.
- `supabase/migrations/20260907130002_event_members.sql` adds the
  RLS-protected `event_members` assignment relation, creator backfill,
  participant-aware create/update/replace RPCs, parent-event version
  invalidation, and leave/deactivation pruning. It is intentionally not added
  to the `supabase_realtime` publication.
- `supabase/migrations/20260907130003_calendar_range.sql` adds the bounded,
  timezone-aware calendar range RPC and opaque keyset pagination.
- `supabase/migrations/20260907130004_invite_links.sql` adds the narrow,
  authenticated invite-preview RPC. It returns sanitized group metadata only;
  the bearer token is never persisted or returned by the preview endpoint.
- `supabase/migrations/20260907130005_recurrence.sql` adds stable recurring
  occurrence expansion, overrides, and occurrence-aware range reads.
- `supabase/migrations/20260907130006_reminders.sql` adds local reminder
  settings plus the private, server-owned delivery queue.
- `supabase/migrations/20260907171029_event_search.sql` adds the bounded,
  authenticated title/description search RPC with creator/participant filters
  and occurrence-aware keyset cursors.
- `supabase/seed.sql` is an idempotent, local-only demo seed that never creates
  an auth user or stores an invite plaintext token.

Review SQL migrations in order and apply them through the Supabase CLI or a
reviewed migration job. The Flutter test suite includes a static security
check so CI can catch missing RLS, token hashing, or optimistic-lock clauses
without requiring Docker. A production pipeline should additionally run
pgTAP/integration tests with real JWT roles and exercise owner/member,
revoked/expired/max-use, stale-version, and soft-delete cases.

## Current features and follow-ups

The current UI/remote adapter covers email/password auth, email confirmation and
password recovery, group selection, member listing, owner member removal, invite
creation/listing/revocation with expiry and max-use controls, event create/edit,
timed/all-day and recurring events, participant assignment/filtering,
creator-versus-group-owner participant permissions, optimistic conflict handling,
parent-event realtime refreshes, bounded server-side event search, local
reminders, and authenticated self-service account deletion with explicit
owned-data cleanup. The backend additionally provides profile/timezone records
for the next UI iteration. Useful follow-ups are profile editing, attachment
storage, pagination and rate-limit retention jobs, TLS/secret management in
deployment, backups, and a full pgTAP/RLS integration suite.

### Manual group/account verification

On a disposable Supabase stack, apply migrations in order (`supabase db reset`)
and create two authenticated users. Verify the following with the real JWT
roles (the Flutter client never sends an actor ID):

1. An owner creates a group with `Asia/Seoul`, edits the description and exact
   IANA zone, and sees the new values after a refresh. An invalid zone and a
   stale `version` are rejected without losing the dialog draft.
2. A member can leave after confirmation and is routed to `/groups`; an owner
   sees the transfer/archive guidance. Transfer only lists active non-owners,
   changes exactly one owner, and archive requires the exact group name and
   removes the group from active reads.
3. Open account deletion and confirm that preflight lists both active and
   archived owned groups plus cascade counts. Keep a group by transferring or
   archiving it first, then confirm the exact deletion phrase and verify the
   Edge response includes `deleted: true` and the validated `summary`.

These checks require a running Auth/Postgres/Edge deployment and are not run in
this checkout: Docker/Supabase services are intentionally not installed or
started here, so CI covers Dart/widget behavior and static SQL/Edge contracts
only. Run focused tests with `flutter test test/account_deletion_test.dart
test/navigation_test.dart test/group_management_core_test.dart` and run
`flutter analyze --no-pub` before a reviewed deployment.

### Manual event participant verification

These checks are a release checklist, not a claim that they have been run in
this checkout. They require a disposable Supabase/Auth/Postgres deployment,
two or more real authenticated sessions, and Realtime enabled for the parent
`events` table:

1. Apply migrations in order with `supabase db reset` (or the reviewed
   deployment job). Create an active group owner, an event creator who is an
   ordinary member, another active member, an inactive member, and an
   outsider in a different group. Run
   `flutter test --no-pub test/event_members_core_test.dart
   test/event_members_ui_test.dart test/sql_event_members_static_test.dart`
   for the credential-free Dart/static contract checks. The isolated upgrade
   proof can be run with
   `bash supabase/tests/run_group_management_upgrade.sh`; it needs local
   PostgreSQL `initdb`, `pg_ctl`, and `psql`, and never connects to a remote
   service. The pgTAP fixture is `supabase/tests/event_members.sql`; execute it
   through the deployment's pgTAP runner (for example, `supabase test db` or
   `psql -f supabase/tests/event_members.sql` against the disposable database).
2. With the authenticated creator, create an event with several active
   participants. Verify that omitted/`null` `member_ids` input on creation
   defaults to the creator, while an explicitly supplied empty list creates an
   event with no participants. Clear an existing list explicitly and verify it
   remains empty. Edit body and participants together, then repeat with an
   unchanged list and verify that the optimistic-lock `version` does not
   advance for the no-op.
3. As the group owner, open the creator-owned event. Verify that participant
   checkboxes and `참여자 저장하기` work, while title/note/date/time/color and
   delete remain read-only/unavailable. As an ordinary participant or outsider,
   verify that the event remains viewable only within the active group and no
   participant/body write is offered. Attempt inactive and cross-group target
   IDs through the RPC boundary and verify an atomic rejection with no partial
   assignment change. A stale event version must likewise preserve the draft.
4. In a second session, deactivate or leave an assigned ordinary member.
   Verify that current `event_members` rows are pruned, each affected parent
   event advances once, the assignment is absent after reactivation, and a
   fresh event read does not restore that pruned assignment. Confirm that the
   parent `events` realtime signal causes the client to batch-read child
   assignments. Do not expect an `event_members` DELETE payload: the child
   table is intentionally absent from `supabase_realtime` because DELETE/RLS
   authorization cannot safely verify the deleted row without risking UUID
   disclosure.
5. On real iOS and Android devices, run VoiceOver and TalkBack through the
   editor checkboxes, save buttons, participant filter, and event cards. Check
   hardware-keyboard focus order and Space/Enter activation, 48 px minimum
   targets, Korean labels (`모든 참여자`, `이전 멤버`), and that inactive or
   unknown identities never appear in text or accessibility output. Repeat at
   a 320x568 viewport with 2x text and a 300 px bottom keyboard inset; verify
   that the parent-scrolling editor keeps participant rows and save actions
   reachable without RenderFlex/AlertDialog overflow.

The live Auth, RLS, membership lifecycle, parent-event Realtime invalidation,
and real-device accessibility checks above are external limitations of this
repository and remain unexecuted until a configured deployment and devices are
available. Keep service-role/secret keys in Supabase/CI secret storage; never
put them in Flutter, this README, or test fixtures.
