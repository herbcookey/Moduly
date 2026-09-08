import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;
  late String repository;
  late String readme;

  setUpAll(() {
    migration = File(
      'supabase/migrations/20260906154329_persist_group_description_event_color.sql',
    ).readAsStringSync().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    repository = File(
      'lib/repositories/schedule_repository.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    readme = File('README.md').readAsStringSync().toLowerCase();
  });

  test('저장된 표시 열을 채우고 제약 조건을 적용한다', () {
    expect(
      migration,
      contains(
        'alter table public.groups add column if not exists description text;',
      ),
    );
    expect(
      migration,
      contains(
        "update public.groups set description = '' where description is null;",
      ),
    );
    expect(migration, contains("alter column description set default ''"));
    expect(migration, contains('alter column description set not null'));
    expect(migration, contains('groups_description_length_check'));
    expect(migration, contains('check (char_length(description) <= 10000)'));

    expect(
      migration,
      contains(
        'alter table public.events add column if not exists color_value bigint;',
      ),
    );
    expect(
      migration,
      contains(
        'update public.events set color_value = 4282874742 where color_value is null;',
      ),
    );
    expect(
      migration,
      contains('alter column color_value set default 4282874742'),
    );
    expect(migration, contains('alter column color_value set not null'));
    expect(migration, contains('events_color_value_range_check'));
    expect(migration, contains('check (color_value between 0 and 4294967295)'));
  });

  test('create_group을 원자적으로 교체하고 보안 계약을 유지한다', () {
    expect(migration, contains('begin;'));
    expect(
      migration,
      contains('drop function if exists public.create_group(text, text);'),
    );
    expect(
      migration,
      contains(
        'drop function if exists public.create_group(text, text, text);',
      ),
    );
    expect(migration, contains('create function public.create_group('));
    expect(migration, contains('p_name text'));
    expect(migration, contains("p_timezone text default 'utc'"));
    expect(migration, contains("p_description text default ''"));
    expect(migration, contains('security definer'));
    expect(migration, contains('set search_path = public, auth'));
    expect(
      migration,
      contains(
        'insert into public.groups (owner_id, name, timezone, description)',
      ),
    );
    expect(migration, contains("coalesce(p_description, '')"));
    expect(
      migration,
      contains(
        'revoke execute on function public.create_group(text, text, text) from public, anon, authenticated;',
      ),
    );
    expect(
      migration,
      contains(
        'grant execute on function public.create_group(text, text, text) to authenticated;',
      ),
    );
    expect(migration, contains('commit;'));
  });

  test('기존 RLS 아래에서 필요한 열 권한만 확장한다', () {
    expect(
      migration,
      contains('grant insert (description) on public.groups to authenticated;'),
    );
    expect(
      migration,
      contains('grant update (description) on public.groups to authenticated;'),
    );
    expect(
      migration,
      contains('grant insert (color_value) on public.events to authenticated;'),
    );
    expect(
      migration,
      contains('grant update (color_value) on public.events to authenticated;'),
    );
  });

  test('설명과 색상을 select, 쓰기, 파서, Realtime 전 과정에서 매핑한다', () {
    expect(
      repository,
      contains(
        "select( 'id,name,description,timezone,version,memberships!inner(user_id,is_active)',",
      ),
    );
    expect(
      repository,
      contains("select('id,name,description,timezone,version')"),
    );
    expect(repository, contains("'p_description': description.trim()"));
    expect(
      repository,
      contains(
        'LocalScheduleRepository._validateGroupDescription(description)',
      ),
    );
    expect(repository, contains('draft.note.trim().length > 10000'));
    expect(repository, contains('event.note.trim().length > 10000'));
    expect(repository, contains("'color_value': draft.colorValue"));
    expect(repository, contains("'color_value': event.colorValue"));
    expect(repository, contains('_validateColorValue(draft.colorValue)'));
    expect(repository, contains('_validateColorValue(event.colorValue)'));
    expect(repository, contains("description: '\${row['description'] ?? ''}'"));
    expect(repository, contains("_colorValue(row['color_value'], 0xff477b76)"));
    expect(repository, contains('parsed >= 0 && parsed <= 0xffffffff'));
    expect(
      repository,
      contains(".from('events') .stream(primaryKey: const <String>['id'])"),
    );
  });

  test('영속성 계약을 문서화한다', () {
    expect(readme, contains('그룹 설명은 `create_group`이 저장하는 선택적 텍스트'));
    expect(readme, contains('최대 10,000자로 제한'));
    expect(readme, contains('부호 없는 32비트 argb 정수'));
    expect(readme, contains('4,294,967,295'));
    expect(readme, contains('4,282,874,742'));
    expect(
      readme,
      contains('20260906154329_persist_group_description_event_color.sql'),
    );
  });
}
