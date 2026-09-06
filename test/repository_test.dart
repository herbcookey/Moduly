import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/models/app_models.dart';
import 'package:moduly/repositories/schedule_repository.dart';

void main() {
  group('LocalScheduleRepository', () {
    test(
      'creates events with UTC boundaries and increments versions atomically',
      () async {
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
      },
    );

    test(
      'persists group descriptions and event colors within the contract',
      () async {
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
      },
    );

    test('soft delete hides an event from the realtime stream', () async {
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

    test('all-day event uses an exclusive end boundary', () async {
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
      // UTC timezone drafts are persisted at the canonical UTC-midnight
      // boundary, even when the device supplied local wall-date DateTimes.
      expect(event.startAt, DateTime.utc(2026, 10, 31));
      expect(event.endAt, DateTime.utc(2026, 11, 1));
    });

    test(
      'canonicalizes local (KST-style) UTC all-day dates and metadata together',
      () async {
        final repository = LocalScheduleRepository();
        // A device in KST can construct a wall-date DateTime while the
        // persisted event timezone is UTC. The adapter must not retain the
        // local instant (which would be the prior UTC date); both boundaries
        // and date-only metadata must describe the same UTC midnights.
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
      },
    );

    test('rejects invalid drafts and non-owner writes', () async {
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

    test('owner can deactivate a member but not the owner', () async {
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

    test(
      'invite metadata supports owner revocation and version conflicts',
      () async {
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
      },
    );
  });
}
