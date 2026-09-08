# Moduly

Moduly는 Supabase를 기반으로 하는 소규모 멀티플랫폼 Flutter 플래너입니다. 이
저장소에는 데이터베이스 계약과 자체 호스팅 Supabase 스택용 개발 프로필이
포함되어 있습니다. 이 저장소를 설정할 때 Supabase 서비스는 의도적으로
설치하거나 시작하지 **않습니다**.

## 아키텍처와 보안

Flutter 클라이언트는 공개 Supabase URL과 publishable(anon) 키만 사용합니다. 인증은
`auth.users`에서 처리하며, 트리거가 사용자마다 `public.profiles` 행 하나를 생성합니다.
애플리케이션 테이블은 다음과 같습니다.

| 테이블 | 용도 |
| --- | --- |
| `profiles` | 표시 이름, 아바타 URL, IANA 시간대입니다. |
| `groups` | 플래너 작업 공간과 변경할 수 없는 소유자, 선택적 설명, 버전 및 소프트 삭제 표시입니다. |
| `memberships` | 소유자/멤버 역할과 활성/비활성 멤버십 이력입니다. |
| `invite_codes` | 만료·폐기·최대 사용 횟수를 포함한 초대 메타데이터입니다. SHA-256 토큰 해시만 저장합니다. |
| `events` | UTC `timestamptz` 경계, IANA 시간대, 종일 날짜 범위 및 부호 없는 ARGB 색상 값을 가진 그룹 일정입니다. |
| `audit_logs` | 추가만 가능한 수명 주기 감사 기록(최소 메타데이터)입니다. |
| `invite_join_attempts` | 초대 시도에 대한 비공개 슬라이딩 윈도우 속도 제한 원장입니다. |
| `event_recurrence_rules` | 기존 일정 시리즈 기준점에 추가되는 일간/주간/월간 규칙입니다. |
| `event_occurrence_overrides` | 안정적인 발생 항목 식별자를 키로 사용하는 희소한 버전별 예외 및 삭제 표시입니다. |

모든 공개 테이블에는 RLS가 활성화되어 있습니다. 정책은 `auth.uid()`에서 신원을
가져옵니다. 활성 멤버는 활성 그룹 데이터를 볼 수 있고, 소유자는 초대와 멤버십
상태를 제어하며, 일정의 `created_by` 사용자만 해당 일정을 수정하거나 소프트
삭제할 수 있습니다. 인증된 클라이언트에는 하드 삭제 권한을 부여하지 않습니다.

초대 생성과 참여는 보안 정의자 권한으로 실행되는 RPC입니다. `create_invite_code`는
임의 토큰을 한 번만 반환하고 다이제스트만 저장합니다. 트랜잭션 방식의
`join_group_with_invite` RPC는 초대 행을 잠그고 만료·폐기·최대 사용 횟수를
검사하며, 사용자별 시도를 직렬화한 뒤 멤버십을 원자적으로 삽입하거나 갱신합니다.
`soft_delete_event_if_version`, `archive_group_if_version`,
`revoke_invite_code`에는 예상 낙관적 잠금 버전이 필요합니다. 일정·그룹·초대를
직접 수정할 때도 `version = old_version + 1`을 보내야 하며, 트리거는 오래되거나
건너뛴 버전을 거부합니다.

시간 지정 일정의 시점은 UTC `timestamptz`입니다. 종일 일정에서
`all_day_start`/`all_day_end`는 반개방 로컬 날짜 범위 `[start, end)`이고,
`starts_at`/`ends_at`은 일정의 IANA 시간대에서 각 날짜의 자정에 해당하는 UTC
시점입니다.

그룹 설명은 `create_group`이 저장하는 선택적 텍스트이며 기본값은 빈 문자열이고
최대 10,000자로 제한됩니다. 일정의 `color_value`는 부호 없는 32비트 ARGB 정수
(`0`부터 `4,294,967,295`)이며 기본값은 `4,282,874,742`(`0xff477b76`)입니다.
일정 생성·수정·실시간 페이로드는 이 값을 유지합니다.

### 그룹 관리와 계정 삭제

멤버 화면에서는 소유자만 `update_group_if_version`을 통해 그룹 이름·설명·IANA
시간대를 수정하고, `transfer_group_ownership`으로 소유권을 이전하며,
`archive_group_if_version`으로 최종 보관 처리할 수 있습니다. 세 RPC 모두 그룹의
낙관적 잠금 `version`을 사용합니다. 오래된 응답에는 한국어 충돌 메시지를 표시하고
초안이나 대상을 대화상자에 그대로 둡니다. 소유자가 아닌 활성 멤버는 **그룹
나가기**(`leave_group`)를 확인할 수 있습니다. 소유자는 소유권을 이전하거나 그룹을
보관 처리하기 전에는 나갈 수 없습니다. UI는 이전 대상을 소유자가 아닌 활성
멤버로 한정하고 두 번째 확인을 요청하며, 보관 처리 시 정확한 그룹 이름을
요구합니다. RLS는 이러한 작업을 소유자·멤버 범위로 제한합니다. 인증된
클라이언트에는 소유권 또는 표시용 열을 직접 UPDATE할 권한이 없습니다.

계정 삭제는 먼저 인증된 `account_deletion_preflight()` RPC를 호출합니다. 형식이
정해진 JSON 요약에는 소유한 활성·보관 그룹(멤버 수 포함)과 그룹·일정·초대 코드·
멤버십의 연쇄 삭제 수가 나열됩니다. Edge Function은 동일한 요약을 검증하고 JWT
검증 후 성공한 `{ "deleted": true, "summary": ... }` 본문만 허용합니다. 이후 Auth
Admin 삭제는 계정 삭제 마이그레이션에 따라 소유하거나 작성한 행을 연쇄
삭제합니다. 확인 화면은 연쇄 삭제가 영구적임을 명확히 밝히고, 소유 중인 활성
그룹을 먼저 이전하거나 보관해야 한다면 그룹 관리 화면으로 연결합니다. 로컬 또는
설정이 막힌 빌드는 이 기능에 연결된 서버가 필요하다고 알리며 로컬 계정이
삭제되었다고 표시하지 않습니다.

### 일정 참여자(기능 5)

`supabase/migrations/20260907130002_event_members.sql` 마이그레이션은 기존 구조에
`public.event_members` 관계를 추가합니다. 각 행에 `(event_id, user_id)` 할당 하나를
저장하고 `created_at`을 기록하며, `events` 및 `auth.users`를 참조하는 연쇄 외래 키와
계정 정리용 사용자 선행 인덱스를 갖습니다. 마이그레이션은 무결성 및 전환 트리거를
설치하기 전에 기존 각 일정의 작성자를 일정 원본 `created_at` 시각으로 채웁니다.
보호된 삽입이므로 다시 적용해도 안전합니다. 소프트 삭제된 일정과 보관된 그룹은
이력을 위해 하위 행을 유지하지만 RLS가 이를 숨깁니다. 일정·그룹·계정을 하드
삭제하면 하위 행도 연쇄 삭제됩니다.

인증된 클라이언트에는 테이블 읽기 전용 권한이 있습니다. 조회 정책은 요청자가
삭제되지 않은 일정 그룹의 활성 멤버이고, 할당된 사용자가 같은 그룹에서 삭제되지
않은 활성 멤버일 것을 요구합니다. 하위 행의 직접 INSERT/UPDATE/DELETE는
거부되며 인증된 RPC만 쓰기 경로로 사용할 수 있습니다.
`create_event_with_members`와 `update_event_with_members_if_version`은 그룹·일정
잠금을 유지하면서 모든 대상을 동일한 활성 그룹 멤버십과 대조하여 검증합니다.
새 일정 생성 시 `member_ids` 입력을 생략하거나 `null`로 지정하면 활성 작성자가
기본값이 됩니다. 빈 목록을 명시적으로 전달하면 참여자가 없는 일정이 생성됩니다.
수정 또는 교체 시 빈 목록을 전달하면 의도대로 모든 할당을 지웁니다.

일정 본문 수정은 계속 작성자만 할 수 있습니다. 활성 일정 작성자 또는 현재 활성
그룹 소유자는 `replace_event_members_if_version`으로 참여자 목록을 교체할 수 있지만,
그룹 소유자가 다른 작성자의 제목·메모·시간·색상을 바꾸거나 일정을 삭제할 수는
없습니다. 참여자로 지정되어도 본문 수정 또는 삭제 권한은 생기지 않습니다. 변경된
목록마다 일정 버전은 정확히 한 번 증가합니다. 변경되지 않은 정규 집합은 멱등
무동작이며 새 버전이나 실시간 전환을 만들지 않습니다. 오래된 버전, 비활성 또는
다른 그룹의 대상, 삭제된 일정 및 비활성 작업자는 하위 행을 부분적으로 수정하지
않고 원자적으로 실패합니다.

일반 멤버가 나가거나 소유자가 해당 멤버를 비활성화하면 현재 할당이 정리되고,
영향받은 삭제되지 않은 상위 일정마다 버전이 한 번 증가합니다. 마이그레이션 이후
수명 주기에서 제거된 할당은 다시 참여하거나 활성화해도 복원되지 않습니다.
마이그레이션이 삽입한 과거 작성자 행은 의도적인 예외입니다. 비활성 작성자의
백필된 행은 RLS에 의해 숨겨질 뿐이며 해당 멤버십이 다시 활성화되면 표시될 수
있습니다. 로컬 어댑터는 생략/`null` 작성자 기본값과 명시적 빈 할당의 차이,
활성 멤버·동일 그룹 검사 및 무동작 의미를 그대로 유지합니다. Supabase 어댑터는
이 차이를 참여자 인식 RPC에 전달하고 `member_ids` 응답을 정규화합니다. 일정
스트림은 상위 `events` 행을 읽은 뒤 표시 가능한 하위 할당을 일괄 조회합니다.
`event_members`는 의도적으로 `supabase_realtime`에 게시하지 **않습니다**. 상위
일정 버전 무효화가 새로 고침을 유도하며, DELETE/RLS 권한 검사로 안전하게 확인할
수 없는 UUID가 하위 DELETE 페이로드를 통해 노출될 수 있기 때문입니다.

편집기는 활성 멤버를 키보드로 조작하고 포커스를 둘 수 있는 체크박스 행(최소
48 px)으로 표시하며, 오래된 할당은 서버 기준 일정 새로 고침이 제거할 때까지
중립적인 한국어 레이블 `이전 멤버`로 유지합니다. 작성자는 본문과 참여자를 함께
수정합니다. 새 일정은 처음에 작성자를 선택하지만 작성자가 모든 체크박스를 해제해
참여자 목록을 비울 수도 있습니다. 그룹 소유자에게는 참여자 전용 컨트롤이 보이고,
일반 멤버는 볼 수 있지만 저장할 수 없습니다. 홈에서는 참여자 전용 필터
(`모든 참여자`)를 사용하고 접근 가능한 이름·수·작은 아바타를 렌더링하며,
비활성 또는 알 수 없는 할당에도 같은 중립 대체 레이블을 사용합니다. 참여자 목록은
중첩된 무제한 목록 대신 상위 화면과 함께 스크롤되며, 편집기는 320x568 레이아웃,
2배 텍스트 및 300 px 하단 키보드 인셋 조건까지 대응합니다.

### 캘린더 보기와 제한된 범위(기능 1)

홈은 기존 일간 주간 스트립, 스와이프 탐색, 일정 카드, 참여자 필터, 경로 및 일정
추가 동작을 유지합니다. 도구 모음에는 접근 가능한 `일간`, `월간`, `일정 목록` 모드,
이전·다음 기간 컨트롤, `오늘` 및 날짜 선택기가 추가됩니다. 월간 모드는 월요일부터
시작하는 35/42칸 그리드를 사용합니다. 각 칸은 개별적으로 포커스하고 탭할 수 있고
보조 기술에 날짜와 일정 수를 알리며, 일정 점 또는 짧은 제목을 표시합니다.
일정 목록 모드는 선택한 달을 처음 겹치는 그룹 시간대 날짜별로 묶고, 종일 일정을
시간 지정 일정 앞에 두며, 시간 지정 행을 UTC 시작 시각과 ID순으로 정렬합니다.
자정을 넘는 일정은 다음 날 표시와 함께 한 번만 나타납니다. 월간 칸이나 선택기의
날짜를 선택하면 현재 모드를 바꾸지 않고 선택한 날짜만 변경되며, 선택기를 취소하면
아무 작업도 하지 않습니다.

캘린더 경계는 기기 시간대가 아니라 선택한 그룹의 IANA 시간대를 기준으로 합니다.
모든 읽기는 로컬 날짜의 자정에서 생성한 반개방 `[start, end)` UTC 범위이므로 DST
전환일은 23시간 또는 25시간일 수 있습니다.
`supabase/migrations/20260907130003_calendar_range.sql` 마이그레이션은 제한된
최댓값과 `(starts_at, id)` 기반 키셋 커서를 사용하는 참여자 인식
`events_for_range` RPC를 추가합니다. 시간 지정 일정은 UTC 겹침을 사용하고, 종일
일정은 반개방 로컬 날짜 범위를 사용합니다. 그룹·모드·날짜·참여자 필터가 바뀌면
`PlannerController`가 현재 범위를 교체합니다. `더 불러오기`는 커서를 따라가며
제한 없는 그룹 이력을 다운로드하지 않습니다. 같은 범위를 새로 고칠 때는 새
페이지를 가져오는 동안 마지막 정상 목록을 표시하고, 읽기에 실패하면 다시 시도할
수 있는 오류를 알립니다.

로컬 및 Supabase 어댑터는 동일한 범위·커서 계약을 구현합니다. 상위 `events`의
Realtime 무효화는 범위를 다시 가져오도록 예약하며, 하위 참여자 행은 의도적으로
게시하지 않습니다. 따라서 RLS로 안전하게 권한을 확인할 수 없는 DELETE 페이로드의
노출을 막으면서도 상위 버전이 바뀐 뒤 참여자 변경 사항을 반영할 수 있습니다.
UI는 오프라인 동기화를 보장하지 않습니다. 오프라인 배너나 마지막 정상 스냅샷은
정보 제공용일 뿐이며, 연결이 복구되면 실패한 범위를 다시 요청해야 합니다.

릴리스를 검사하려면 `supabase db reset`(또는 검토된 마이그레이션 작업)을 실행하고,
상위 `events` 테이블에 Realtime을 활성화한 뒤 자격 증명이 필요 없는 검사를 실행합니다.

```sh
flutter test --no-pub test/calendar_views_ui_test.dart \
  test/controller_test.dart test/timezone_test.dart
flutter analyze --no-pub
```

폐기 가능한 Supabase/Auth 배포에서 DST를 적용하는 시간대를 가진 그룹과 1,000개
이상의 일정 데이터셋을 만듭니다. 일간·월간·일정 목록 페이지가 각자의 반개방 범위만
반환하는지, 키셋 페이지에 중복이나 누락이 없는지, 참여자 필터가 커서를 초기화하는지,
상위 일정의 INSERT/UPDATE/소프트 삭제가 병합된 재조회 한 번을 일으키는지 확인합니다.
두 번째 인증 세션에서 일정을 변경하고 하위 테이블 Realtime 페이로드 없이 첫 번째
세션이 갱신되는지 확인합니다. 320x568 뷰포트, 2배 텍스트, 300 px 키보드 인셋,
하드웨어 키보드 포커스, VoiceOver/TalkBack 및 35칸·42칸 월간 화면에서 수동 검사를
반복합니다. 이러한 실제 Supabase·부하·네트워크·실기기 검사는 저장소 외부 작업이며,
여기에서 실행했다고 주장하지 않습니다.

### 반복 일정(기능 2)

반복 데이터는 기존 구조에 추가됩니다. 기존 `events.id`는 논리적 시리즈 기준점으로
유지되고, 구체화된 발생 항목은 동일한 기준점 ID와 불투명하고 안정적인
`occurrence_key`를 가집니다. 기존 단일 일정은 `single` 키와 `/event/:id` 경로를
유지합니다. 발생 항목은 요청한 제한된 캘린더 범위 안에서만 방어적 상한을 두고
확장되며, 클라이언트는 제한 없는 행 집합을 만들지 않습니다.

편집기에서는 시간 필드 바로 다음에 `반복`을 배치합니다. `매일`, `매주`, `매월`,
1~999 간격, ISO 월요일 우선 요일 칩, 반복 횟수 또는 종료일 포함 방식을 지원합니다.
주간 일정을 만들 때는 기본적으로 DTSTART의 요일을 선택합니다. 월간 규칙은 요청한
날짜를 유지하되 해당 날짜가 없는 짧은 달에는 마지막 날로 맞춥니다. 편집기의 안내
문구가 이를 명확히 설명합니다. 실시간 한국어 요약은 스크린 리더에 전달되고 일간,
월간 및 일정 목록 카드의 반복 배지에도 재사용됩니다.

발생 항목을 수정하거나 삭제하면 가장 안전한 기본값인 `이번 일정만`을 선택한
스크롤 가능한 라디오 확인 창이 항상 열립니다. 다른 선택지는 `이번 일정과 이후`와
`전체 일정`이며, 대화상자를 취소하거나 닫으면 아무 작업도 하지 않습니다. 이후·
전체 범위 안내 문구는 기존 예외가 초기화될 수 있음을 경고합니다. 참여자 할당은
시리즈 전체가 상속하는 필드입니다. 모든 발생 항목에 표시되며 전체 시리즈 범위를
선택한 경우에만 바꿀 수 있습니다. 제목, 메모, 색상, 시간대, 기간 및 종일 경계도
동일한 시리즈·예외 상속 계약을 따릅니다. 변경을 커밋한 뒤에는 클라이언트에서
여러 항목으로 확산하지 않고 서버 기준의 제한된 범위를 새로 고칩니다.

자격 증명이 필요 없는 UI 검사는 다음과 같이 실행합니다.

```sh
flutter test --no-pub test/recurrence_ui_test.dart \
  test/recurrence_accessibility_test.dart
flutter analyze --no-pub
```

폐기 가능한 Auth/Postgres 배포에서는 DST 전환을 지나는 일간 규칙, 짧은 달에 걸친
월간 29~31일, 종일 경계, 이번/이후/전체 예외 삭제, 오래된 버전 거부 및 중복 없는
범위 페이지 구분도 확인합니다. 320x568, 2배 텍스트, 300 px 키보드 인셋, 하드웨어
키보드 포커스 및 VoiceOver/TalkBack 환경에서 UI 검사를 반복합니다. 이러한 실제
서비스 및 실기기 검사는 이 체크아웃 외부 작업이며 실행했다고 주장하지 않습니다.

### 로컬 알림(기능 3)

이 단계에서는 기기 로컬 알림만 제공합니다. 의존성은
`flutter_local_notifications: 22.3.0`으로 고정되어 있습니다. 이 릴리스에는
`timezone: 0.11.1` 고정 버전이 필요하므로 모든 일정의 현지 시각 및 DST 계산에
플래너와 동일한 IANA 데이터베이스를 사용합니다. Android 알림은
`inexactAllowWhileIdle` 예약 모드를 사용하므로 Doze 또는 배터리 정책에 따라 운영
체제가 알림을 약간 늦게 전달할 수 있습니다. 정확한 알람 권한
(`SCHEDULE_EXACT_ALARM` 및 `USE_EXACT_ALARM`)은 의도적으로 요청하지 않습니다.

로컬 스케줄러는 제한된 `[now, now + 60 days)` 일정 구간만 읽고, 기기마다 가까운
알림 시각을 최대 48개까지 알림 시각순으로 유지합니다. 이후 발생 항목은 앱이 다음에
로컬 스냅샷을 조정할 때 예약되며, 이는 오프라인 동기화를 보장하지 않습니다. 알림이
운영 체제에 커밋된 뒤에는 플랫폼 권한·재부팅·배터리·전달 규칙에 따라 네트워크
연결 없이도 표시될 수 있습니다. 시간 지정 알림은 저장된 UTC 시점에서 미리 알림
시간을 뺍니다. 종일 알림은 일정의 IANA 시간대에서 09:00를 계산한 뒤 달력상의
날짜 단위로 빼며, 기기 시간대의 자정을 기준으로 하지 않습니다.

설정 화면은 계정 전환, 이 기기 권한 및 서버 푸시 기능을 구분합니다. 권한 요청은
사용자가 명시적으로 `알림 켜기`를 실행한 뒤에만 표시되며, 시스템 설정에서 돌아오면
상태를 다시 확인합니다. Android API 33 이상에서는 `POST_NOTIFICATIONS`가 필요하고,
iOS/macOS 로컬 알림은 UserNotifications 권한을 사용합니다. 이 단계에서 웹,
Windows 및 Linux는 로컬 알림을 지원하지 않는다고 표시합니다. 알림 제목·메모·
이메일·멤버 이름·토큰은 운영 체제 페이로드에 복사하지 않습니다. 탭 동작에는
불투명한 일정 ID와 검증된 발생 항목 키만 들어가며, 인증 및 멤버십 검사 후 서버
기준 일정을 다시 불러옵니다. 로컬·데모 저장소는 사람이 읽을 수 있는 시드 ID를
사용하므로, UUID 기반 일정 데이터를 제공하도록 Supabase 배포를 설정하기 전에는
네이티브 예약과 알림 탭이 `unconfigured` 상태로 유지됩니다. 데모 컨트롤은 운영
체제 전달 성공을 표시하지 않습니다.

서버 푸시는 여기에서 의도적으로 `unconfigured` 상태입니다. 나중에 활성화하려면
실제 Firebase 프로젝트와 생성된 식별자, `.p8` 키/Key ID/Team ID를 포함한 APNs
푸시 기능, 웹 HTTPS 서비스 워커 등록과 공개 VAPID 키, 공급자 자격 증명이 있는
신뢰할 수 있는 서버 워커/cron이 필요합니다. 이러한 값은 공급자/CI 비밀 저장소에만
보관하고 이 저장소나 Flutter 클라이언트에는 추가하지 않아야 합니다. 향후 워커는
임대를 통해 작업을 가져오고 `(user, device, event, occurrence_key, reminder, method)`
기준으로 중복을 제거한 뒤 제한된 백오프로 다시 시도해야 합니다. 따라서 전달은
정확히 한 번이 아니라 최소 한 번을 보장합니다. 유효하지 않은 공급자 토큰은
비공개로 폐기해야 합니다. `send-reminders` Edge Function은 스케줄러가 호출하므로
`verify_jwt = false`를 사용합니다. 따라서 모든 요청에는 배포에만 존재하는
`REMINDER_WORKER_SECRET`과 일치하는 비어 있지 않은
`x-reminder-worker-secret` 헤더가 있어야 합니다. 워커는 기능 또는 작업 가져오기
RPC보다 먼저 이 비밀을 확인합니다. 이 값은 Edge/CI 비밀 저장소에 보관하고 Flutter
클라이언트, 로그 또는 커밋된 설정에 넣지 마세요.

이 부분의 자격 증명이 필요 없는 검사는 다음과 같습니다.

```sh
flutter pub get
flutter test --no-pub test/notification_platform_static_test.dart \
  test/notification_settings_ui_test.dart \
  test/event_notification_controls_test.dart \
  test/notification_deep_link_static_test.dart
flutter analyze --no-pub
```

네이티브 권한, 재부팅, Doze/Focus, 잠금 화면 개인정보 보호 및 DST 검사에는 실제
Android/iOS/macOS 기기가 필요하며 수동 릴리스 검사로 진행해야 합니다. 운영자가
해당 프로젝트와 서명 메타데이터를 제공하기 전까지 Firebase, APNs, VAPID, 서비스
워커, 워커/cron 및 서명된 릴리스 설정은 외부 차단 요인입니다.

### 일정 검색(기능 7)

일정 검색은 서버 측 활성 그룹 투영 결과입니다. 제목과 설명을 리터럴 일치 방식으로
검색하며(클라이언트 측 스캔이나 퍼지 인덱스가 아님), 제한된 로컬 날짜 기간과 서로
독립적인 활성 멤버 작성자·참여자 필터도 지원합니다. 빈 검색어는 의도적으로 기간·
필터만 사용하는 검색을 뜻합니다. 비어 있지 않은 검색어는 Unicode 스칼라 값
2~100개이면서 최대 400 UTF-8바이트여야 합니다. 선택한 그룹의 IANA 시간대가
반개방 날짜 범위를 정의합니다. UI에 포함되는 종료일은 다음 로컬 자정으로 변환되며,
범위는 최대 366일까지만 설정할 수 있습니다.

`search_events_v1` RPC는 `(starts_at,event_id,occurrence_key)` 기반의 불투명 키셋
커서를 사용하여 완전한 일정·발생 항목 행을 제한된 페이지(기본 50개)로 반환합니다.
재정의 값과 안정적인 발생 항목 식별자를 포함한 실제 반복 발생 항목 필드를 유지하므로
결과를 선택하면 정확한 일정과 발생 항목이 열립니다. 검색 결과는 캘린더 범위
스냅샷이나 커서를 바꾸지 않습니다. 입력에는 디바운스를 적용하며, 취소, 사용자·
그룹·필터 전환 및 오래된 응답은 컨트롤러 세대로 격리합니다.

RPC는 검색하거나 개수를 세기 전에 인증, 그룹 존재 여부·수명 주기 및 활성 멤버십을
검사합니다. 외부인, 비활성 멤버, 보관 그룹 및 없는 그룹에는 모두 동일한 사용 불가
응답을 반환하며, 작성자·참여자 ID는 해당 그룹의 활성 멤버여야 합니다. `public`/
`anon`의 공개 실행 권한은 폐기하고 `authenticated`에만 부여합니다. 함수는 빈
`search_path`를 사용합니다. 제목·설명·멤버 데이터·검색어는 URL이나 로그에 넣지
않습니다. 결과는 `/event/:id` 또는 `/event/:seriesId?occurrence=...`에서 열 수
있으며, 선택한 날짜는 그룹 시간대에 맞게 갱신됩니다.

이 부분의 자격 증명이 필요 없는 검사는 다음과 같습니다.

```sh
flutter test --no-pub test/event_search_core_test.dart \
  test/event_search_ui_test.dart \
  test/sql_event_search_static_test.dart
flutter analyze --no-pub
bash supabase/tests/run_event_search_upgrade.sh
```

업그레이드 실행기는 격리된 로컬 PostgreSQL 클러스터에 마이그레이션을 적용하고
멱등성을 확인하기 위해 다시 적용한 뒤, 실제 인증 역할 클레임으로
`event_search.sql` 픽스처를 실행합니다(pgTAP을 사용할 수 없으면 자체 어설션으로
대체). 릴리스를 검증하려면 폐기 가능한 Auth/Postgres 배포에서
`supabase db reset`을 실행하고 소유자·멤버·비활성·외부인 계정을 만든 다음, 실제
JWT로 RLS 거부, Unicode·특수 문자, 날짜·DST, 작성자·참여자 및 1,000개 이상 행의
누락·중복 없는 커서 검사를 반복합니다. Flutter 앱에서 디바운스·취소·재시도와
정확한 발생 항목 탐색을 확인한 다음, 320x568, 2배 텍스트, 300 px 키보드 인셋,
하드웨어 포커스, VoiceOver/TalkBack 및 웹·네이티브 대상에서 반복합니다. 이러한
실제 서비스·부하·네트워크·실기기 검사는 이 체크아웃 외부 작업이며 여기에서
실행했다고 주장하지 않습니다.

## Flutter 개발

1. 커밋된 자리표시자 참고 파일로 `.env.example`을 유지합니다. Flutter 3.44 이상에서는
   이 파일을 무시되는 `.env.local` 파일로 복사한 뒤 두 공개 값을 배포 값으로
   교체합니다. 운영자가 Flutter 앱을 제공하는 공개 HTTPS 출처를 소유한 경우에만
   `INVITE_BASE_URL`을 설정합니다.

   ```sh
   cp .env.example .env.local
   ```

   커밋된 예시는 Flutter의 `.env` 키-값 형식을 사용합니다. Flutter 3.44 이상에서
   `--dart-define-from-file`로 불러올 때는 이 형식 또는 같은 키 세 개를 가진 JSON
   객체를 사용할 수 있습니다. 서비스 역할 키, 데이터베이스 비밀번호/URI 또는
   그 밖의 서버 전용 자격 증명을 Flutter, 소스 제어 또는 모바일 바이너리에 절대
   넣지 마세요.
2. Flutter 의존성을 설치하고 무시되는 파일에서 컴파일 시간 값을 불러와 앱을
   실행합니다.

   ```sh
   flutter pub get
   flutter run --dart-define-from-file=.env.local
   ```

   로컬 웹 콜백을 검사하려면 커밋된 Supabase 프로필에서 허용한 포트로 Chrome을
   실행합니다.

   ```sh
   flutter run -d chrome --web-port 3000 \
     --dart-define-from-file=.env.local
   ```

   `--dart-define-from-file`에는 `.env` 키-값 파일이나 JSON 파일을 사용할 수 있습니다.
   `.env.local`은 저장소의 `.gitignore`에서 무시됩니다. 다른 로컬 비밀 관리자가
   값을 제공한다면 개별 `--dart-define` 플래그를 계속 사용할 수 있습니다.

3. Supabase API가 호스트에 바인딩되어 있다면 다음 API 주소를 사용합니다.

   | 클라이언트 | API URL |
   | --- | --- |
   | iOS 시뮬레이터 | `http://127.0.0.1:54321` |
   | Android 에뮬레이터 | `http://10.0.2.2:54321` |
   | 실제 iOS/Android 기기 | 로컬 전용 검사에서는 `http://<developer-LAN-IP>:54321` |

   이 HTTP 주소는 로컬 전용 검사에 사용합니다. 특히 릴리스 프로필에서는 Android
   평문 정책과 iOS App Transport Security가 연결을 차단할 수 있으므로 가능하면
   HTTPS 역방향 프록시나 터널을 사용하세요. 로컬 HTTP를 피할 수 없다면 디버그
   전용 전송 예외를 명시적으로 사용하고 스토어 빌드에서는 제거하세요. 실제 기기는
   개발 호스트로 라우팅할 수 있어야 합니다. 공유 기기·스테이징·프로덕션에서는
   HTTPS 호스트 이름과 신뢰할 수 있는 인증서를 사용하고 인증서 검증을 끄지 마세요.

### 런타임 설정과 릴리스 실패 차단 동작

디버그 및 프로필 빌드에서는 `SUPABASE_URL`과 `SUPABASE_PUBLISHABLE_KEY`를 생략할
수 있습니다. 이 의도적인 미리 보기 경로는 메모리 내 데모 저장소를 사용합니다.
릴리스 빌드에는 두 공개 값이 모두 필요합니다. 둘 중 하나가 없거나 Supabase
초기화에 실패하면 앱은 한국어 설정 오류 차단 화면을 표시하고 로컬 데모 저장소를
생성하거나 사용하지 않습니다. 차단 화면에는 비밀 값이 절대 표시되지 않습니다.
보호된 빌드 환경에서 실제 배포 값을 공급하여 프로덕션 산출물을 빌드하고,
클라이언트에는 publishable(anon) 키만 사용하세요.

### Android 릴리스 서명

Android 애플리케이션 ID와 Kotlin 네임스페이스는 `com.herbcookey.moduly`입니다.
릴리스 빌드에서는 디버그 키 저장소를 사용하지 않습니다. 안전한 위치에 업로드 키
저장소를 만들고 커밋된 템플릿을 복사한 뒤 값을 입력합니다.

```sh
cp android/key.properties.example android/key.properties
keytool -genkeypair -v -keystore android/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias moduly
```

`android/key.properties`와 `*.jks`/`*.keystore` 파일은 git에서 무시됩니다. CI에서는
대신 `MODULY_ANDROID_KEYSTORE_FILE`, `MODULY_ANDROID_KEYSTORE_PASSWORD`,
`MODULY_ANDROID_KEY_ALIAS`, `MODULY_ANDROID_KEY_PASSWORD`를 통해 같은 값을
제공합니다. 값 또는 키 저장소가 하나라도 없으면 릴리스 빌드가 해결 방법을 포함한
오류와 함께 실패합니다. 디버그 및 프로필 빌드에는 서명 키가 필요하지 않습니다.

## 자체 호스팅 Supabase(Docker 방식)

Docker와 Supabase CLI가 있는 전용 개발/CI 호스트에서 다음 단계를 실행합니다.
아래 내용은 안내일 뿐이며 이 체크아웃에서는 실행하지 않습니다.

```sh
# 선택한 호스트에서 이 저장소를 기준으로 실행합니다.
supabase start                 # 로컬 Docker 스택 시작
supabase status                # API URL과 publishable 키를 로컬 환경에 복사
supabase db reset              # 마이그레이션과 supabase/seed.sql 적용
```

기존 자체 호스팅 배포에서는 API를 TLS 역방향 프록시(Caddy, Nginx 또는 관리형 부하
분산기) 뒤에 두고, Auth 서비스에 공개 사이트·리디렉션 URL을 설정한 뒤
`supabase db push`(또는 배포의 검토된 마이그레이션 작업)로 마이그레이션을
적용합니다. 데이터베이스와 Studio 포트는 비공개로 유지하세요. Postgres `54322`와
Studio `54323`은 루프백 또는 VPN/관리자 네트워크에 바인딩하고 공개 인터넷에 절대
노출하지 않아야 합니다. 역방향 프록시를 통해 API 포트만 노출하고 JWT·데이터베이스
비밀을 교체하며, 백업과 로그는 모바일 클라이언트 외부에 보관하세요.

커밋된 `supabase/config.toml`에는 로컬 포트와 Auth 리디렉션이 문서화되어 있습니다.
새 스택을 처음 초기화할 때는 사용자가 없을 수 있으므로 시드가 안내를 출력하고 데모
행을 건너뜁니다. 로컬 사용자 한 명을 가입시킨 다음 `supabase db seed`를 실행하거나
`supabase/seed.sql`을 실행하여 인증 사용자를 초기화하지 않고 데모 그룹과 종일
일정을 만듭니다.

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

### Auth 콜백 리디렉션 허용 목록

네이티브(iOS, Android, macOS)의 이메일 확인, 비밀번호 복구 및 OAuth 링크는 정확히
`moduly://auth-callback` 사용자 지정 URI 스킴으로 돌아옵니다. 호스팅된 Supabase
프로젝트에서는 **Dashboard → Authentication → URL Configuration → Redirect URLs**에
이 값을 정확히 추가하고 설정을 저장합니다.

웹에서 클라이언트는 현재 브라우저 출처를 기준으로 콜백을 결정하고
`/auth-callback`을 사용합니다. 예를 들면 다음과 같습니다.
`https://planner.example.com/auth-callback` 또는
`http://localhost:3000/auth-callback`. 앱을 제공할 수 있는 각 배포 출처·경로를 같은
Supabase Redirect URLs 허용 목록에 추가합니다. 로컬 CLI 프로필은
`supabase/config.toml`에서 localhost 패턴을 이미 허용합니다. 로컬 스택을 실행할
때 추가 스테이징 또는 프로덕션 출처가 있다면 이 파일에 등록하세요.

호스팅된 웹 서버는 `/auth-callback` 직접 요청(쿼리 문자열 포함)을 앱의 나머지
부분에 사용하는 것과 동일한 Flutter `index.html` SPA 대체 경로로 제공해야 합니다.
이 재작성 규칙이 없으면 Flutter가 시작되기 전에 OAuth 또는 이메일 반환이 서버
404가 될 수 있습니다. 결정기는 출처 루트에 이 콜백을 생성하므로 하위 경로에
배포한다면 그에 상응하는 루트 별칭을 제공하거나, 호스팅 설정에서 정확한 콜백
URL을 노출해야 합니다.

허용 목록은 프로젝트 설정이며 SQL 마이그레이션이나 클라이언트로 변경할 수
없습니다. 네이티브 앱을 배포하는 모든 환경에 네이티브 사용자 지정 스킴 항목을
유지하고, 호스팅된 모든 웹 배포에는 웹 출처 항목을 유지하세요.

### 초대 링크와 공유

소유자는 초대 코드를 만든 직후 한 번만 확인할 수 있습니다. 대화상자에서 형식화된
코드를 복사하거나 운영 체제 공유 시트를 열 수 있습니다. `INVITE_BASE_URL`이
유효하게 설정된 HTTPS 출처일 때만 공유 가능한 URL을 추가하며, 그렇지 않으면
코드만 공유합니다. Supabase API URL은 애플리케이션 출처로 사용하지 않으며, 이
저장소에서 프로덕션 호스트 이름을 임의로 만들지 않습니다. 목록에 표시된 초대
행에는 평문 토큰이 없으므로 복사·공유 기능은 의도적으로 생성 결과에서만
제공됩니다.

네이티브 대체 링크는 등록된 `moduly://invite/<token>` 스킴을 사용합니다. 기존
`moduly://auth-callback` 스킴은 Supabase 인증 및 비밀번호 복구용으로 분리되어
있습니다. Flutter 리스너는 Supabase 인증 초기화가 완료되기 전에 링크를 포착하고,
콜드 스타트 값을 버퍼링하며, 웜 스타트와 초기 전달의 중복을 제거합니다. 인증·복구
콜백 매개변수는 항상 Supabase가 관리합니다. 초대 미리 보기와 참여는 인증된
사용자가 그룹을 명시적으로 확인한 뒤에만 진행됩니다.

웹 빌드는 Flutter의 경로 URL 전략을 사용하므로
`https://<configured-origin>/invite/<token>` 직접 요청과 새로 고침을 호스팅
공급자가 동일한 `web/index.html` SPA 진입점으로 재작성해야 합니다.
`/auth-callback`에도 같은 재작성 규칙이 필요합니다(쿼리 문자열 포함). 앱은
브라우저 경로에서 토큰을 즉시 제거하고 수명이 짧은 대기 중 초대 상태에 보관합니다.
로그인 리디렉션을 재개할 수 있도록 메모리에 보관하며, 가능한 경우 탭 범위
`sessionStorage`에서도 복원합니다. 토큰은 쿼리 매개변수, 로그, 분석 또는 공개
미리 보기 모델에 절대 넣지 않습니다. 현재 빌드는 의도적으로 해시 형식 링크를
생성하지 않습니다. SPA 재작성을 제공할 수 없는 호스트는 웹 초대 링크를 활성화하기
전에 재작성 규칙을 추가해야 합니다.

검증된 HTTPS 링크를 사용하려면 Flutter 변경 사항 외에도 운영자가 소유한 플랫폼
연결 파일이 필요합니다.

* Android App Links에는 최종 호스트와 `android:autoVerify="true"`가 지정된 별도의
  `https` 인텐트 필터, 그리고 `com.herbcookey.moduly` 패키지와 모든 릴리스 서명
  인증서의 SHA-256 지문을 포함하는
  `https://<host>/.well-known/assetlinks.json`이 필요합니다. 기기에서
  `adb shell pm verify-app-links --re-verify com.herbcookey.moduly`로 확인하세요.
* iOS Universal Links에는 서명된 Associated Domains 권한의 `applinks:<host>`와,
  실제 Apple Team ID 및 `com.herbcookey.moduly` 앱 ID를 포함하는
  `https://<host>/.well-known/apple-app-site-association`이 필요합니다(`.json`
  접미사나 리디렉션 사용 불가). 하위 도메인마다 고유한 권한과 연결 파일이
  필요합니다.

운영자가 실제 호스트·서명 메타데이터를 제공하기 전에는 HTTPS 인텐트 필터, Apple
권한, Team ID, 연결 파일, Windows MSIX/레지스트리 항목 또는 Linux `.desktop`
등록을 커밋하지 않습니다. 따라서 데스크톱 사용자 지정 스킴 전달은 설치 프로그램의
책임입니다. 패키징되지 않은 Windows/Linux 빌드에서는 웹 URL이나 수동 코드를
사용하세요.

### 데스크톱 사용자 지정 스킴 패키징

macOS Runner는 `macos/Runner/Info.plist`에 `moduly`를 등록하므로 패키징된 macOS
빌드가 네이티브 콜백을 받을 수 있습니다. Windows 등록은 설치 프로그램이
담당합니다. `app_links`에는 패키징된 MSIX 매니페스트를 통한 프로토콜 활성화가
문서화되어 있으며, 패키징되지 않은 빌드와 디버그 실행에는 이 저장소가 소유하지
않는 명시적 Windows 런타임 또는 레지스트리 등록이 필요합니다. Linux도 마찬가지로
애플리케이션 활성화 처리와 `x-scheme-handler/moduly` MIME 항목의 설치 프로그램
등록이 필요합니다. 데스크톱 딥 링크를 출시하기 전에 이러한 플랫폼별 설치 단계를
추가하세요. 이 저장소는 의도적으로 Windows MSIX/레지스트리 등록이나 Linux
`.desktop` 파일을 제공하지 않습니다. 해당 설치 단계가 마련되기 전에는 Windows/
Linux에서 웹 콜백을 사용하고 네이티브 데스크톱 콜백 지원을 아직 출시되지 않은
기능으로 취급하세요.

macOS 샌드박스 Release 및 Debug/Profile 권한에는 Supabase의 외부 HTTPS 호출을
위한 `com.apple.security.network.client`가 포함됩니다. 서명 설정을 재정의할 때도
이 권한을 유지하고 서명된 빌드로 스모크 테스트하세요. 이 권한이 없으면 샌드박스
macOS 빌드가 설정된 서비스에 연결할 수 없습니다.

### 소셜 로그인 공급자 설정

로그인 화면은 Supabase `signInWithOAuth`를 통해 Google, Apple, Kakao를 제공합니다.
네이티브 빌드는 `moduly://auth-callback`을 보내고 웹 빌드는 현재 출처에
`/auth-callback`을 더해 보냅니다. 공급자 클라이언트 비밀은 Supabase Dashboard
(또는 로컬 Supabase 비밀 환경)에만 유지해야 하며 Flutter에 컴파일하거나 이
저장소에 보관해서는 안 됩니다. **Dashboard → Authentication → Providers**에서
각 공급자를 활성화하고 클라이언트 ID/비밀을 설정한 뒤, 위에서 설명한 네이티브
및/또는 웹 콜백 URI를 허용 목록에 추가하세요.

앱은 브라우저 실행 결과를 잠정 상태로 취급하고 형식화된 Supabase 인증 이벤트가
올 때까지 접근 권한을 부여하지 않습니다. 공급자가 비활성화되어 있거나 브라우저
실행에 실패하거나 사용자가 취소하면 UI는 한국어 오류를 표시하고 데모 세션을
만들지 않습니다. Apple OAuth 자격 증명에는 공급자의 일반적인 Apple Developer
설정과 비밀 교체가 필요합니다. 이 브라우저 기반 OAuth 경로는 네이티브 Apple
권한을 추가하거나 Apple 비밀을 포함하지 않습니다.

### iOS 번들 및 서명

iOS 애플리케이션 번들 식별자는 `com.herbcookey.moduly`이며 단위 테스트 번들은
`com.herbcookey.moduly.RunnerTests` 계열을 사용합니다.
`ios/Flutter/Debug.xcconfig`와 `Release.xcconfig`는 무시되는 `Signing.xcconfig`
파일을 선택적으로 포함합니다. 로컬 Xcode 계정을 사용하려면
`ios/Flutter/Signing.xcconfig.example`을 복사하고 `DEVELOPMENT_TEAM`을 해당
계정에 표시된 Team ID로 설정합니다. 복사한 파일이나 프로비저닝 프로필 세부 정보를
커밋하지 마세요.

CI에서는 검증되지 않은 Team ID를 하드 코딩하지 말고 보호된 변수에서 빌드 시간에
팀 값을 주입해야 합니다.

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

서명 ID와 일치하는 프로비저닝 프로필을 사용할 수 있기 전에는
`flutter build ios --release --no-codesign`으로 iOS 릴리스를 확인합니다.

### 스토어 제출 전 개인정보처리방침과 이용약관

`docs/privacy-policy-ko.md`와 `docs/terms-of-service-ko.md`의 한국어 초안은 앱의
설정 화면과 로그아웃 상태의 로그인·가입 화면에서도 확인할 수 있습니다. 이
문서에는 저장소에서 확인할 수 없는 운영자 신원, 연락처 주소, 보유 기간, 처리자
계약, 데이터 리전, 국외 이전 또는 지원 URL을 의도적으로 명시하지 않았습니다.
이 문서는 법률 자문이 아닙니다.

스토어 빌드를 게시하기 전에 실제 운영자는 다음 작업을 해야 합니다.

1. 배포된 Supabase 프로젝트를 기준으로 데이터 흐름 설명을 검토하고 운영자 신원,
   주소, 실제 연락 방법, 보유·삭제 절차, 처리자·하위 처리자와 리전 정보 및 필요한
   연령·유료 서비스·관할 조항을 작성합니다.
2. 앱이 제공될 관할 지역에 맞게 최종 문서를 검토받습니다. 정책이나 약관이 바뀌면
   앱 내부 사본과 호스팅된 사본을 동기화합니다.
3. 두 Markdown 문서를 운영자가 관리하는 도메인·저장소(예: 운영자 소유 정적 호스팅
   프로젝트)에 공개 정적 HTTPS 페이지로 게시합니다. 추측한 URL이나 비공개 저장소
   URL을 제출하지 마세요. 이 체크아웃은 공개 정책 호스트를 소유하지 않습니다.
4. 로그아웃 상태에서 최종 페이지를 열어 확인하고, 호스트를 배포하고 URL을 검증한
   뒤에만 실제 개인정보처리방침 페이지 URL을 관련 스토어 등록 정보에 추가합니다.
   이용약관 페이지는 같은 운영자 관리 사이트와 앱에서 연결할 수 있습니다.

이 저장소에는 지원 URL이 설정되어 있지 않습니다. 운영자는 자리표시자를 복사하는
대신 릴리스 전에 실제 연락 경로를 제공해야 합니다.

## 마이그레이션과 정적 검사

- `supabase/migrations/202608110001_schema.sql`은 확장, 테이블, 제약 조건, 인덱스,
  트리거, 프로필·그룹 소유자 훅 및 감사 기록 쓰기를 생성합니다.
- `supabase/migrations/202608110002_rls_rpc.sql`은 도우미 함수, RLS 정책, 최소 권한
  부여, 초대·그룹·일정·멤버 RPC 및 속도 제한을 생성합니다.
- `supabase/migrations/202608140003_account_deletion.sql`은 소유·작성 행 외래 키에
  인증된 계정 삭제 정책을 명시합니다. `delete-account` Edge Function을 배포하기
  전에 검토된 마이그레이션 작업으로 적용하세요.
- `supabase/migrations/20260906154329_persist_group_description_event_color.sql`은
  그룹 설명과 부호 없는 일정 색상을 백필하고 제약 조건을 적용한 뒤, `create_group`
  RPC를 설명을 인식하는 시그니처와 최소 권한 부여 방식으로 교체합니다.
- `supabase/migrations/20260907130001_group_management.sql`은 경쟁 상태에도 안전한
  단일 소유자 불변 조건, 버전 기반 수정·이전·보관·나가기 RPC 및 인증된
  `account_deletion_preflight()` JSON 계약을 추가합니다.
- `supabase/migrations/20260907130002_event_members.sql`은 RLS로 보호된
  `event_members` 할당 관계, 작성자 백필, 참여자를 인식하는 생성·수정·교체 RPC,
  상위 일정 버전 무효화 및 나가기·비활성화 시 정리를 추가합니다. 이 관계는
  의도적으로 `supabase_realtime` 게시에 추가하지 않습니다.
- `supabase/migrations/20260907130003_calendar_range.sql`은 제한된 시간대 인식
  캘린더 범위 RPC와 불투명 키셋 페이지 구분을 추가합니다.
- `supabase/migrations/20260907130004_invite_links.sql`은 범위가 좁은 인증된 초대
  미리 보기 RPC를 추가합니다. 정제된 그룹 메타데이터만 반환하며, Bearer 토큰은
  저장되거나 미리 보기 엔드포인트에서 반환되지 않습니다.
- `supabase/migrations/20260907130005_recurrence.sql`은 안정적인 반복 발생 항목
  확장·재정의 및 발생 항목을 인식하는 범위 읽기를 추가합니다.
- `supabase/migrations/20260907130006_reminders.sql`은 로컬 알림 설정과 비공개
  서버 소유 전달 대기열을 추가합니다.
- `supabase/migrations/20260907171029_event_search.sql`은 작성자·참여자 필터와
  발생 항목 인식 키셋 커서를 사용하는 제한된 인증 제목·설명 검색 RPC를 추가합니다.
- `supabase/seed.sql`은 인증 사용자를 만들거나 초대 평문 토큰을 저장하지 않는
  멱등적 로컬 전용 데모 시드입니다.

SQL 마이그레이션을 순서대로 검토하고 Supabase CLI 또는 검토된 마이그레이션 작업을
통해 적용하세요. Flutter 테스트 스위트에는 정적 보안 검사가 포함되어 있어 Docker
없이도 CI에서 누락된 RLS, 토큰 해싱 또는 낙관적 잠금 절을 찾을 수 있습니다.
프로덕션 파이프라인에서는 실제 JWT 역할로 pgTAP·통합 테스트도 실행하고 소유자·
멤버, 폐기·만료·최대 사용 횟수, 오래된 버전 및 소프트 삭제 사례를 검사해야 합니다.

## 현재 기능과 후속 작업

현재 UI·원격 어댑터는 이메일/비밀번호 인증, 이메일 확인과 비밀번호 복구, 그룹
선택, 멤버 목록, 소유자의 멤버 제거, 만료·최대 사용 횟수 제어가 있는 초대 생성·
목록·폐기, 일정 생성·수정, 시간 지정·종일·반복 일정, 참여자 할당·필터링, 작성자와
그룹 소유자 사이의 참여자 권한, 낙관적 충돌 처리, 상위 일정 실시간 새로 고침,
제한된 서버 측 일정 검색, 로컬 알림 및 소유 데이터 정리를 명시하는 인증된 셀프서비스
계정 삭제를 지원합니다. 백엔드는 다음 UI 개선을 위한 프로필·시간대 레코드도
제공합니다. 유용한 후속 작업으로는 프로필 수정, 첨부 파일 저장소, 페이지 구분·속도
제한 보존 작업, 배포 시 TLS·비밀 관리, 백업 및 전체 pgTAP/RLS 통합 테스트 스위트가
있습니다.

### 수동 그룹·계정 검증

폐기 가능한 Supabase 스택에서 마이그레이션을 순서대로 적용하고
(`supabase db reset`) 인증된 사용자 두 명을 만듭니다. 실제 JWT 역할로 다음을
검증합니다. Flutter 클라이언트는 행위자 ID를 전송하지 않습니다.

1. 소유자가 `Asia/Seoul`로 그룹을 만들고 설명과 정확한 IANA 시간대를 수정한 뒤,
   새로 고침 후 새 값이 표시되는지 확인합니다. 잘못된 시간대와 오래된 `version`은
   대화상자 초안을 잃지 않고 거부되어야 합니다.
2. 멤버는 확인 후 나가서 `/groups`로 이동할 수 있고, 소유자에게는 이전·보관
   안내가 표시되어야 합니다. 이전 목록에는 소유자가 아닌 활성 멤버만 표시되고
   소유자는 정확히 한 명만 변경되어야 합니다. 보관하려면 정확한 그룹 이름을
   입력해야 하며 보관한 그룹은 활성 읽기에서 제거되어야 합니다.
3. 계정 삭제 화면을 열어 사전 검사에 소유한 활성·보관 그룹과 연쇄 삭제 수가 모두
   표시되는지 확인합니다. 유지할 그룹은 먼저 이전하거나 보관한 다음 정확한 삭제
   문구를 확인하고, Edge 응답에 `deleted: true`와 검증된 `summary`가 포함되는지
   확인합니다.

이 검사에는 실행 중인 Auth/Postgres/Edge 배포가 필요하므로 이 체크아웃에서는
실행하지 않습니다. Docker/Supabase 서비스를 의도적으로 설치하거나 시작하지 않기
때문에 CI에서는 Dart·위젯 동작과 정적 SQL·Edge 계약만 검사합니다. 검토된 배포
전에 `flutter test test/account_deletion_test.dart test/navigation_test.dart
test/group_management_core_test.dart`로 집중 테스트를 실행하고
`flutter analyze --no-pub`을 실행하세요.

### 수동 일정 참여자 검증

다음 항목은 릴리스 체크리스트이며 이 체크아웃에서 실행했다는 뜻이 아닙니다.
폐기 가능한 Supabase/Auth/Postgres 배포, 실제 인증 세션 두 개 이상, 상위 `events`
테이블에 활성화된 Realtime이 필요합니다.

1. `supabase db reset`(또는 검토된 배포 작업)으로 마이그레이션을 순서대로
   적용합니다. 활성 그룹 소유자, 일반 멤버인 일정 작성자, 다른 활성 멤버, 비활성
   멤버 및 다른 그룹의 외부인을 만듭니다. 자격 증명이 필요 없는 Dart·정적 계약
   검사를 위해 `flutter test --no-pub test/event_members_core_test.dart
   test/event_members_ui_test.dart test/sql_event_members_static_test.dart`를 실행합니다.
   격리된 업그레이드 검증은
   `bash supabase/tests/run_group_management_upgrade.sh`로 실행할 수 있습니다. 로컬
   PostgreSQL `initdb`, `pg_ctl`, `psql`이 필요하며 원격 서비스에는 절대 연결하지
   않습니다. pgTAP 픽스처는 `supabase/tests/event_members.sql`입니다. 배포의 pgTAP
   실행기를 통해 실행하세요. 예를 들어 폐기 가능한 데이터베이스에서
   `supabase test db` 또는 `psql -f supabase/tests/event_members.sql`을 사용합니다.
2. 인증된 작성자로 활성 참여자가 여러 명인 일정을 만듭니다. 생성 시 `member_ids`
   입력을 생략하거나 `null`로 지정하면 작성자가 기본값이 되는지, 빈 목록을
   명시적으로 전달하면 참여자 없는 일정이 생성되는지 확인합니다. 기존 목록을
   명시적으로 지우고 빈 상태가 유지되는지 확인합니다. 본문과 참여자를 함께
   수정한 다음 변경되지 않은 목록으로 반복하여, 무동작일 때 낙관적 잠금 `version`이
   증가하지 않는지 확인합니다.
3. 그룹 소유자로 작성자 소유 일정을 엽니다. 참여자 체크박스와 `참여자 저장하기`는
   작동하지만 제목·메모·날짜·시간·색상 및 삭제는 읽기 전용이거나 사용할 수 없는지
   확인합니다. 일반 참여자나 외부인에게 일정은 활성 그룹 안에서만 보여야 하며,
   참여자·본문 쓰기 기능을 제공해서는 안 됩니다. RPC 경계에서 비활성 및 다른
   그룹의 대상 ID를 시도하여 일부 할당도 바꾸지 않고 원자적으로 거부하는지
   확인합니다. 오래된 일정 버전에서도 마찬가지로 초안이 유지되어야 합니다.
4. 두 번째 세션에서 할당된 일반 멤버를 비활성화하거나 나가게 합니다. 현재
   `event_members` 행이 정리되고, 영향을 받은 각 상위 일정 버전이 한 번 증가하며,
   재활성화 후에도 할당이 없고, 새 일정 읽기가 정리된 할당을 복원하지 않는지
   확인합니다. 상위 `events` 실시간 신호 때문에 클라이언트가 하위 할당을 일괄
   조회하는지 확인합니다. `event_members` DELETE 페이로드는 기대하지 마세요.
   삭제된 행을 DELETE/RLS 권한 검사로 안전하게 확인하면서 UUID 노출 위험을 막을
   수 없으므로, 하위 테이블은 의도적으로 `supabase_realtime`에서 제외됩니다.
5. 실제 iOS 및 Android 기기에서 VoiceOver와 TalkBack으로 편집기 체크박스, 저장
   버튼, 참여자 필터 및 일정 카드를 조작합니다. 하드웨어 키보드 포커스 순서,
   Space/Enter 활성화, 최소 48 px 대상, 한국어 레이블(`모든 참여자`, `이전 멤버`),
   그리고 비활성 또는 알 수 없는 신원이 텍스트나 접근성 출력에 나타나지 않는지
   확인합니다. 320x568 뷰포트, 2배 텍스트 및 300 px 하단 키보드 인셋 조건에서도
   반복합니다. 상위 화면과 함께 스크롤되는 편집기에서 RenderFlex/AlertDialog
   오버플로 없이 참여자 행과 저장 동작에 접근할 수 있어야 합니다.

위의 실제 Auth, RLS, 멤버십 수명 주기, 상위 일정 Realtime 무효화 및 실기기 접근성
검사는 이 저장소 외부의 제약 사항이며, 설정된 배포와 기기를 사용할 수 있을 때까지
실행되지 않은 상태입니다. 서비스 역할·비밀 키는 Supabase/CI 비밀 저장소에
보관하고 Flutter, 이 README 또는 테스트 픽스처에 절대 넣지 마세요.
