import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/schedule_repository.dart';

void main() {
  group('LocalScheduleRepository', () {
    test('UTC 경계로 일정을 만들고 버전을 원자적으로 증가시킨다', () async {
      final repository = LocalScheduleRepository();
      final localStart = DateTime(2026, 2, 3, 9, 30);
      final localEnd = localStart.add(const Duration(hours: 1));

      final created = await repository.createEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'Timezone check',
          startAt: localStart,
          endAt: localEnd,
        ),
      );

      expect(created.startAt.isUtc, isTrue);
      expect(created.endAt.isUtc, isTrue);
      expect(created.startAt, localStart.toUtc());
      expect(created.endAt, localEnd.toUtc());
      expect(created.version, 1);

      final updated = await repository.updateEvent(
        created.copyWith(title: 'Updated'),
        expectedVersion: created.version,
      );
      expect(updated.version, created.version + 1);
      expect(updated.title, 'Updated');

      await expectLater(
        repository.updateEvent(
          created.copyWith(title: 'Stale write'),
          expectedVersion: created.version,
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test('계약 범위 안에서 그룹 설명과 일정 색상을 저장한다', () async {
      final repository = LocalScheduleRepository();
      final maxDescription = List<String>.filled(10000, 'd').join();
      final group = await repository.createGroup(
        'demo-user',
        '  New group  ',
        maxDescription,
      );
      expect(group.name, 'New group');
      expect(group.description, maxDescription);

      final created = await repository.createEvent(
        'demo-user',
        group.id,
        EventDraft(
          title: 'Colored event',
          note: maxDescription,
          startAt: DateTime.utc(2026, 2, 3, 9),
          endAt: DateTime.utc(2026, 2, 3, 10),
          colorValue: 0xffffffff,
        ),
      );
      expect(created.colorValue, 0xffffffff);
      expect(created.note, maxDescription);

      final updated = await repository.updateEvent(
        created.copyWith(colorValue: 0),
        expectedVersion: created.version,
      );
      expect(updated.colorValue, 0);

      await expectLater(
        repository.createGroup(
          'demo-user',
          'Too long description',
          '${maxDescription}x',
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.createEvent(
          'demo-user',
          group.id,
          EventDraft(
            title: 'Invalid color',
            startAt: DateTime.utc(2026, 2, 3, 9),
            endAt: DateTime.utc(2026, 2, 3, 10),
            colorValue: -1,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.createEvent(
          'demo-user',
          group.id,
          EventDraft(
            title: 'Too long note',
            note: '${maxDescription}x',
            startAt: DateTime.utc(2026, 2, 3, 9),
            endAt: DateTime.utc(2026, 2, 3, 10),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.updateEvent(
          created.copyWith(colorValue: 0x100000000),
          expectedVersion: created.version,
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        repository.updateEvent(
          created.copyWith(note: '${maxDescription}x'),
          expectedVersion: created.version,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('소프트 삭제가 Realtime 스트림에서 일정을 숨긴다', () async {
      final repository = LocalScheduleRepository();
      final created = await repository.createEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'Delete me',
          startAt: DateTime.utc(2026, 2, 3, 9),
          endAt: DateTime.utc(2026, 2, 3, 10),
        ),
      );

      expect(
        (await repository.watchEvents('demo-group').first).any(
          (event) => event.id == created.id,
        ),
        isTrue,
      );
      await repository.softDeleteEvent(
        created.id,
        expectedVersion: created.version,
      );
      expect(
        (await repository.watchEvents('demo-group').first).any(
          (event) => event.id == created.id,
        ),
        isFalse,
      );
    });

    test('종일 일정이 종료일을 제외하는 경계를 사용한다', () async {
      final repository = LocalScheduleRepository();
      final start = DateTime(2026, 10, 31);
      final end = DateTime(2026, 11, 1);
      final event = await repository.createEvent(
        'demo-user',
        'demo-group',
        EventDraft(title: 'All day', startAt: start, endAt: end, allDay: true),
      );

      expect(event.allDay, isTrue);
      expect(event.endAt.isAfter(event.startAt), isTrue);
      // 기기가 현지 달력 날짜의 DateTime을 제공해도 UTC 시간대 초안은 정규
      // UTC 자정 경계로 저장된다.
      expect(event.startAt, DateTime.utc(2026, 10, 31));
      expect(event.endAt, DateTime.utc(2026, 11, 1));
    });

    test('현지(KST 방식) UTC 종일 날짜와 메타데이터를 함께 정규화한다', () async {
      final repository = LocalScheduleRepository();
      // 저장된 일정 시간대가 UTC여도 KST 기기는 달력 날짜 DateTime을 만들 수
      // 있다. 어댑터는 이전 UTC 날짜가 되는 현지 시각을 보존하면 안 된다.
      // 양쪽 경계와 날짜 전용 메타데이터는 같은 UTC 자정을 나타내야 한다.
      final start = DateTime(2026, 10, 31);
      final end = DateTime(2026, 11, 2);
      final event = await repository.createEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'UTC all-day',
          startAt: start,
          endAt: end,
          allDay: true,
          timezone: 'UTC',
        ),
      );

      expect(event.startAt, DateTime.utc(2026, 10, 31));
      expect(event.endAt, DateTime.utc(2026, 11, 2));
      expect(event.allDayStartDate, DateTime(2026, 10, 31));
      expect(event.allDayEndDate, DateTime(2026, 11, 2));
    });

    test('잘못된 초안과 소유자가 아닌 사용자의 쓰기를 거부한다', () async {
      final repository = LocalScheduleRepository();
      await expectLater(
        repository.createEvent(
          'demo-user',
          'demo-group',
          EventDraft(
            title: '   ',
            startAt: DateTime.utc(2026, 2, 3, 10),
            endAt: DateTime.utc(2026, 2, 3, 9),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      final event = await repository.createEvent(
        'demo-user',
        'demo-group',
        EventDraft(
          title: 'Owner only',
          startAt: DateTime.utc(2026, 2, 3, 10),
          endAt: DateTime.utc(2026, 2, 3, 11),
        ),
      );
      await expectLater(
        repository.updateEvent(
          event.copyWith(title: 'Spoofed'),
          expectedVersion: event.version,
          actorId: 'member-jin',
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
      await expectLater(
        repository.softDeleteEvent(
          event.id,
          expectedVersion: event.version,
          actorId: 'member-jin',
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test('소유자는 멤버를 비활성화할 수 있지만 자신은 비활성화할 수 없다', () async {
      final repository = LocalScheduleRepository();
      final removed = await repository.setMemberActive(
        'demo-group',
        'member-jin',
        false,
        actorId: 'demo-user',
      );
      expect(removed.isActive, isFalse);
      expect(
        (await repository.membersForGroup(
          'demo-group',
        )).any((member) => member.id == 'member-jin'),
        isFalse,
      );
      await expectLater(
        repository.setMemberActive(
          'demo-group',
          'demo-user',
          false,
          actorId: 'demo-user',
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });

    test('초대 메타데이터가 소유자 취소와 버전 충돌을 지원한다', () async {
      final repository = LocalScheduleRepository();
      final invite = await repository.createInviteCodeWithOptions(
        'demo-group',
        ttl: const Duration(days: 2),
        maxUses: 3,
      );
      expect(invite.token, isNotEmpty);
      expect(
        (await repository.inviteCodesForGroup('demo-group')),
        hasLength(1),
      );
      final revoked = await repository.revokeInviteCode(
        invite.id,
        expectedVersion: invite.version,
        actorId: 'demo-user',
      );
      expect(revoked.isRevoked, isTrue);
      await expectLater(
        repository.revokeInviteCode(
          invite.id,
          expectedVersion: invite.version,
          actorId: 'demo-user',
        ),
        throwsA(isA<ScheduleConflictException>()),
      );
    });
  });
}
