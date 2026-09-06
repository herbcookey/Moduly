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

## Flutter development

1. Keep `.env.example` as the checked-in placeholder reference. For Flutter
   3.44 or newer, copy it to an ignored `.env.local` file and replace the two
   public values with the deployment values:

   ```sh
   cp .env.example .env.local
   ```

   The checked-in example uses Flutter's `.env` key-value format. Flutter 3.44+
   accepts either this format or a JSON object with the same two keys when
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
creation/listing/revocation with expiry and max-use controls, event create and
edit, timed/all-day events, and optimistic conflict handling, plus realtime event
stream updates, and authenticated self-service account deletion with explicit
owned-data cleanup. The backend additionally provides profile/timezone records
for the next UI iteration. Useful follow-ups are profile editing, recurring events,
reminders/notifications, attachment storage, pagination and rate-limit retention
jobs, TLS/secret management in deployment, backups, and a full pgTAP/RLS
integration suite.
