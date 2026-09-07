import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import 'package:moduly/app.dart';
import 'package:moduly/core/config/app_config.dart';
import 'package:moduly/models/app_models.dart';
import 'package:moduly/platform/browser_location_source.dart';
import 'package:moduly/platform/invite_share_service.dart';
import 'package:moduly/repositories/auth_repository.dart';
import 'package:moduly/repositories/schedule_repository.dart';
import 'package:moduly/screens/group_picker_screen.dart';
import 'package:moduly/screens/invite_preview_screen.dart';
import 'package:moduly/screens/auth_screens.dart';
import 'package:moduly/state/app_state.dart';

const _inviteUser = PlannerUser(
  id: 'invite-user',
  email: 'invite@example.com',
  displayName: 'Invite User',
);

const _inviteConfig = AppConfig(
  supabaseUrl: '',
  supabasePublishableKey: '',
  inviteBaseUrl: 'https://planner.example.test',
);

const _inviteGroup = PlannerGroup(
  id: 'invite-group',
  name: '초대 테스트 그룹',
  description: '초대된 일정방 설명',
  timezone: 'Asia/Seoul',
  ownerId: 'invite-owner',
);

class _InviteAuth extends AuthRepository {
  _InviteAuth(this._user);

  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();
  final PlannerUser? _user;

  @override
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  @override
  PlannerUser? get currentUser => _user;

  @override
  void dispose() {
    unawaited(_events.close());
    super.dispose();
  }
}

class _InviteRepository extends LocalScheduleRepository {
  _InviteRepository({
    this.failPreview = false,
    this.rateLimitPreview = false,
    this.alreadyMember = false,
    this.expiredPreview = false,
    this.failJoin = false,
    this.joinCommittedFailure = false,
  });

  bool failPreview;
  bool rateLimitPreview;
  final bool alreadyMember;
  final bool expiredPreview;
  final bool failJoin;
  final bool joinCommittedFailure;
  int previewCalls = 0;
  int joinCalls = 0;
  InviteCode? _createdInvite;

  InvitePreview get _preview => InvitePreview(
    groupId: _inviteGroup.id,
    groupName: _inviteGroup.name,
    groupDescription: _inviteGroup.description,
    groupTimezone: _inviteGroup.timezone,
    expiresAt: DateTime.now().toUtc().add(
      expiredPreview ? const Duration(minutes: -1) : const Duration(days: 1),
    ),
    alreadyMember: alreadyMember,
  );

  @override
  Future<List<PlannerGroup>> groupsForUser(String userId) async =>
      <PlannerGroup>[_inviteGroup];

  @override
  Future<List<PlannerMember>> membersForGroup(String groupId) async =>
      const <PlannerMember>[];

  @override
  Future<List<InviteCode>> inviteCodesForGroup(String groupId) async {
    final invite = _createdInvite;
    if (invite == null || invite.groupId != groupId) {
      return const <InviteCode>[];
    }
    // Listing never returns bearer material, even though the creation RPC
    // returned it once to the one-shot dialog.
    return <InviteCode>[
      InviteCode(
        id: invite.id,
        groupId: invite.groupId,
        expiresAt: invite.expiresAt,
        maxUses: invite.maxUses,
        usesCount: invite.usesCount,
        version: invite.version,
        token: null,
        revokedAt: invite.revokedAt,
        createdAt: invite.createdAt,
        updatedAt: invite.updatedAt,
      ),
    ];
  }

  @override
  Stream<List<PlannerEvent>> watchEventsForUser(
    String userId,
    String groupId,
  ) => Stream<List<PlannerEvent>>.value(const <PlannerEvent>[]);

  @override
  Future<InvitePreview> previewInvite({
    required String userId,
    required String token,
  }) async {
    previewCalls++;
    if (rateLimitPreview) throw const InviteRateLimitException();
    if (failPreview) {
      throw const InviteUnavailableException.invalidOrExpired();
    }
    return _preview;
  }

  @override
  Future<PlannerGroup> joinGroup(String userId, String inviteCode) async {
    joinCalls++;
    if (joinCommittedFailure) throw const InviteJoinCommittedException();
    if (failJoin) throw const InviteUnavailableException.invalidOrExpired();
    return _inviteGroup;
  }

  @override
  Future<InviteCode> createInviteCodeWithOptions(
    String groupId, {
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) async {
    final now = DateTime.now().toUtc();
    final invite = InviteCode(
      id: 'invite-test',
      groupId: groupId,
      expiresAt: now.add(ttl),
      maxUses: maxUses,
      usesCount: 0,
      version: 1,
      token: '2345ABCDEFGH',
      createdAt: now,
      updatedAt: now,
    );
    _createdInvite = invite;
    return invite;
  }
}

class _RecordingInviteShareService implements InviteShareService {
  String? code;
  Uri? link;
  Rect? origin;
  bool fail = false;

  @override
  Future<ShareResult> shareInvite({
    required String code,
    Uri? link,
    Rect? sharePositionOrigin,
  }) async {
    if (fail) throw StateError('share failed');
    this.code = code;
    this.link = link;
    origin = sharePositionOrigin;
    return const ShareResult('selected', ShareResultStatus.success);
  }
}

Future<(GoRouter, _InviteRepository)> _pumpInviteApp(
  WidgetTester tester, {
  AppConfig config = _inviteConfig,
  BrowserLocationSource? browserLocation,
  PlannerUser? user,
  bool failPreview = false,
  bool rateLimitPreview = false,
  bool alreadyMember = false,
  bool expiredPreview = false,
  bool failJoin = false,
  bool joinCommittedFailure = false,
  InviteShareService? shareService,
}) async {
  final auth = _InviteAuth(user);
  final repository = _InviteRepository(
    failPreview: failPreview,
    rateLimitPreview: rateLimitPreview,
    alreadyMember: alreadyMember,
    expiredPreview: expiredPreview,
    failJoin: failJoin,
    joinCommittedFailure: joinCommittedFailure,
  );
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(auth),
        scheduleRepositoryProvider.overrideWithValue(repository),
        if (browserLocation != null)
          browserLocationSourceProvider.overrideWithValue(browserLocation),
        if (shareService != null)
          inviteShareServiceProvider.overrideWithValue(shareService),
      ],
      child: const ModulyApp(),
    ),
  );
  await tester.pumpAndSettle();
  final element = find.byType(ModulyApp).evaluate().first;
  final container = ProviderScope.containerOf(element);
  return (container.read(routerProvider), repository);
}

String _routerLocation(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('direct invite captures then replaces the token route', (
    tester,
  ) async {
    final (router, _) = await _pumpInviteApp(tester);

    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('/invite/2345ABCDEFGH'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoginScreen)),
    );
    expect(container.read(plannerControllerProvider).hasPendingInvite, isTrue);
    expect(_routerLocation(router), '/login');
  });

  testWidgets('malformed invite paths never become pending or visible', (
    tester,
  ) async {
    final (router, _) = await _pumpInviteApp(tester);
    router.go('/invite/2345ABCDEFGH?source=untrusted');
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ModulyApp)),
    );
    expect(container.read(plannerControllerProvider).hasPendingInvite, isFalse);
    expect(find.text('2345ABCDEFGH'), findsNothing);
    expect(_routerLocation(router), '/login');
  });

  testWidgets('nested web base path uses the complete browser location', (
    tester,
  ) async {
    final (router, _) = await _pumpInviteApp(
      tester,
      config: const AppConfig(
        supabaseUrl: '',
        supabasePublishableKey: '',
        inviteBaseUrl: 'https://planner.example.test/app',
      ),
      browserLocation: StaticBrowserLocationSource(
        Uri.parse('https://planner.example.test/app/invite/2345ABCDEFGH'),
      ),
    );
    // PathUrlStrategy presents the stripped path to GoRouter.
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(_routerLocation(router), '/login');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoginScreen)),
    );
    expect(container.read(plannerControllerProvider).hasPendingInvite, isTrue);
  });

  testWidgets('nested web base rejects wrong origin, root, and repetition', (
    tester,
  ) async {
    const nested = AppConfig(
      supabaseUrl: '',
      supabasePublishableKey: '',
      inviteBaseUrl: 'https://planner.example.test/app',
    );
    for (final browserUri in <Uri>[
      Uri.parse('https://other.example.test/app/invite/2345ABCDEFGH'),
      Uri.parse('https://planner.example.test/invite/2345ABCDEFGH'),
      Uri.parse('https://planner.example.test/app/app/invite/2345ABCDEFGH'),
    ]) {
      final (router, _) = await _pumpInviteApp(
        tester,
        config: nested,
        browserLocation: StaticBrowserLocationSource(browserUri),
      );
      router.go('/invite/2345ABCDEFGH');
      await tester.pumpAndSettle();

      expect(_routerLocation(router), '/login');
      final element = find.byType(ModulyApp).evaluate().first;
      final container = ProviderScope.containerOf(element);
      expect(
        container.read(plannerControllerProvider).hasPendingInvite,
        isFalse,
      );
    }
  });

  testWidgets('invite-shaped unmatched paths are scrubbed before error UI', (
    tester,
  ) async {
    final (router, _) = await _pumpInviteApp(tester);
    router.go('/wrong-root/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(_routerLocation(router), '/login');
    expect(find.text('요청한 페이지를 열 수 없어요. 링크를 다시 확인해 주세요.'), findsNothing);
    expect(find.text('2345ABCDEFGH'), findsNothing);
    final element = find.byType(ModulyApp).evaluate().first;
    final container = ProviderScope.containerOf(element);
    expect(container.read(plannerControllerProvider).hasPendingInvite, isFalse);
  });

  testWidgets('signed-out invite flow has a token-free cancel action', (
    tester,
  ) async {
    final (router, _) = await _pumpInviteApp(tester);
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(find.text('초대 흐름 취소'), findsOneWidget);
    await tester.tap(find.text('초대 흐름 취소'));
    await tester.pumpAndSettle();

    expect(_routerLocation(router), '/login');
    expect(find.text('초대 흐름 취소'), findsNothing);
    expect(find.text('2345ABCDEFGH'), findsNothing);
    final element = find.byType(ModulyApp).evaluate().first;
    final container = ProviderScope.containerOf(element);
    expect(container.read(plannerControllerProvider).hasPendingInvite, isFalse);
  });

  testWidgets('logged-out invite resumes on the preview after auth', (
    tester,
  ) async {
    final (router, _) = await _pumpInviteApp(tester);
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoginScreen)),
    );
    final controller = container.read(plannerControllerProvider);
    expect(controller.hasPendingInvite, isTrue);

    // Model the auth repository's successful session event without exposing
    // a bearer token through the route or widget API.
    controller
      ..user = _inviteUser
      ..authFlowState = AuthFlowState.signedIn
      ..notifyListeners();
    await tester.pumpAndSettle();

    expect(find.byType(InvitePreviewScreen), findsOneWidget);
    expect(find.text(_inviteGroup.name), findsOneWidget);
  });

  testWidgets('authenticated invite previews before an explicit single join', (
    tester,
  ) async {
    final (router, repository) = await _pumpInviteApp(
      tester,
      user: _inviteUser,
    );

    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(find.byType(InvitePreviewScreen), findsOneWidget);
    expect(find.text(_inviteGroup.name), findsOneWidget);
    expect(find.text(_inviteGroup.description), findsOneWidget);
    expect(repository.previewCalls, 1);
    expect(repository.joinCalls, 0);

    // The first tap owns the operation; the second tap sees the disabled
    // accepting state and cannot issue a duplicate repository call.
    await tester.tap(find.text('이 그룹에 참여'));
    await tester.tap(find.text('이 그룹에 참여'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(repository.joinCalls, 1);
    expect(_routerLocation(router), '/home');
  });

  testWidgets(
    'expired accept stays on safe invite error instead of navigating',
    (tester) async {
      final (router, repository) = await _pumpInviteApp(
        tester,
        user: _inviteUser,
        expiredPreview: true,
      );
      router.go('/invite/2345ABCDEFGH');
      await tester.pumpAndSettle();

      expect(find.text('이 그룹에 참여'), findsOneWidget);
      await tester.tap(find.text('이 그룹에 참여'));
      await tester.pumpAndSettle();

      expect(repository.joinCalls, 0);
      expect(_routerLocation(router), '/invite');
      expect(find.text('초대 링크가 만료되었거나 더 이상 유효하지 않아요.'), findsOneWidget);
      expect(find.byType(GroupPickerScreen), findsNothing);
    },
  );

  testWidgets(
    'accept exception stays on safe invite error instead of navigating',
    (tester) async {
      final (router, repository) = await _pumpInviteApp(
        tester,
        user: _inviteUser,
        failJoin: true,
      );
      router.go('/invite/2345ABCDEFGH');
      await tester.pumpAndSettle();

      await tester.tap(find.text('이 그룹에 참여'));
      await tester.pumpAndSettle();

      expect(repository.joinCalls, 1);
      expect(_routerLocation(router), '/invite');
      expect(find.text('초대 링크가 만료되었거나 더 이상 유효하지 않아요.'), findsOneWidget);
      expect(find.byType(GroupPickerScreen), findsNothing);
    },
  );

  testWidgets('already-member committed-safe failure does not navigate', (
    tester,
  ) async {
    final (router, repository) = await _pumpInviteApp(
      tester,
      user: _inviteUser,
      alreadyMember: true,
      joinCommittedFailure: true,
    );
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    await tester.tap(find.text('그룹 목록으로 이동'));
    await tester.pumpAndSettle();

    expect(repository.joinCalls, 1);
    expect(_routerLocation(router), '/invite');
    expect(find.text('초대 링크가 만료되었거나 더 이상 유효하지 않아요.'), findsOneWidget);
    expect(find.byType(GroupPickerScreen), findsNothing);
  });

  testWidgets('cancel clears the pending invite and returns to groups', (
    tester,
  ) async {
    final (router, _) = await _pumpInviteApp(tester, user: _inviteUser);
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(_routerLocation(router), '/groups');
    expect(find.byType(GroupPickerScreen), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(GroupPickerScreen)),
    );
    expect(container.read(plannerControllerProvider).hasPendingInvite, isFalse);
  });

  testWidgets('unavailable preview has a safe retry and no token text', (
    tester,
  ) async {
    final (router, repository) = await _pumpInviteApp(
      tester,
      user: _inviteUser,
      failPreview: true,
    );
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(find.text('초대 링크가 만료되었거나 더 이상 유효하지 않아요.'), findsOneWidget);
    expect(find.text('2345ABCDEFGH'), findsNothing);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(repository.joinCalls, 0);
  });

  testWidgets('rate limited preview keeps a distinct safe retry message', (
    tester,
  ) async {
    final (router, repository) = await _pumpInviteApp(
      tester,
      user: _inviteUser,
      rateLimitPreview: true,
    );
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(find.text('요청이 너무 많아요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
    expect(find.text('2345ABCDEFGH'), findsNothing);
    expect(repository.joinCalls, 0);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('요청이 너무 많아요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
  });

  testWidgets('already-member invite clears pending before group navigation', (
    tester,
  ) async {
    final (router, repository) = await _pumpInviteApp(
      tester,
      user: _inviteUser,
      alreadyMember: true,
    );
    router.go('/invite/2345ABCDEFGH');
    await tester.pumpAndSettle();

    expect(find.text('이미 참여 중인 그룹이에요.'), findsOneWidget);
    expect(find.text('그룹 목록으로 이동'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(InvitePreviewScreen)),
    );
    await tester.tap(find.text('그룹 목록으로 이동'));
    await tester.tap(find.text('그룹 목록으로 이동'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // Already-member previews still use the authoritative idempotent join RPC
    // once; the controller clears this exact pending generation afterward.
    expect(repository.joinCalls, 1);
    expect(container.read(plannerControllerProvider).hasPendingInvite, isFalse);
    expect(_routerLocation(router), '/groups');
  });

  testWidgets('members show one-shot copy/share and listed token-free notice', (
    tester,
  ) async {
    final share = _RecordingInviteShareService();
    await _pumpInviteApp(
      tester,
      user: const PlannerUser(
        id: 'invite-owner',
        email: 'owner@example.com',
        displayName: 'Owner',
      ),
      shareService: share,
    );

    // Use the regular group-picker flow to reach Members without manufacturing
    // token state in the widget test.
    await tester.tap(find.text('초대 테스트 그룹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('멤버').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 코드'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('만들기'));
    await tester.pumpAndSettle();

    expect(find.text('초대 코드가 준비됐어요'), findsOneWidget);
    expect(find.text('코드 복사'), findsOneWidget);
    expect(find.text('공유'), findsOneWidget);
    await tester.tap(find.text('코드 복사'));
    await tester.pump();
    // Clipboard channels are unavailable in a pure widget test; the control
    // must still remain mounted and usable when that platform call fails.
    expect(find.text('코드 복사'), findsOneWidget);

    await tester.tap(find.text('공유'));
    await tester.pumpAndSettle();
    expect(share.code, isNotNull);
    expect(share.link, isNotNull);
    expect(share.origin, isNotNull);

    share.fail = true;
    await tester.tap(find.text('공유'));
    await tester.pumpAndSettle();
    expect(find.text('공유 창을 열지 못했어요. 코드를 복사해 주세요.'), findsOneWidget);

    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.text('복사와 공유는 생성 직후에만 가능해요.'), findsOneWidget);
  });

  testWidgets(
    'invite controls remain reachable at large text on a narrow view',
    (tester) async {
      tester.view
        ..physicalSize = const Size(640, 1136)
        ..devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (router, _) = await _pumpInviteApp(tester, user: _inviteUser);
      router.go('/invite/2345ABCDEFGH');
      await tester.pumpAndSettle();

      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('그룹에 참여')), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '이 그룹에 참여'),
      );
      expect(
        button.style?.minimumSize?.resolve(<WidgetState>{})?.height ?? 48,
        greaterThanOrEqualTo(48),
      );
      semantics.dispose();
    },
  );
}
