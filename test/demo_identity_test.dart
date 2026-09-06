import 'package:flutter_test/flutter_test.dart';

import 'package:moduly/core/demo_identity.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';

void main() {
  test('local demo auth and members use Donghyun consistently', () async {
    final auth = AuthRepository();
    final user = await auth.signIn(demoUserEmail, 'planner');
    expect(user.id, demoUserId);
    expect(user.displayName, demoUserName);

    final repository = LocalScheduleRepository();
    final seededMembers = await repository.membersForGroup('demo-group');
    expect(
      seededMembers.firstWhere((member) => member.id == demoUserId).name,
      demoUserName,
    );

    final createdGroup = await repository.createGroup(
      demoUserId,
      '새 그룹',
      '테스트 그룹',
    );
    final createdOwner = (await repository.membersForGroup(
      createdGroup.id,
    )).single;
    expect(createdOwner.name, demoUserName);

    const joinedUserId = 'joined-demo-user';
    final joinedGroup = await repository.joinGroup(joinedUserId, 'family');
    expect(joinedGroup.id, 'demo-group');
    final joinedMember = (await repository.membersForGroup(
      joinedGroup.id,
    )).firstWhere((member) => member.id == joinedUserId);
    expect(joinedMember.name, demoUserName);
  });
}
