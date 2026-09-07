// 공개 생성자 매개변수 이름은 비공개 필드와 의도적으로 다르게 둔다.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/invite_link.dart';
import '../core/invite_code_utils.dart';
import '../core/pending_invite_store.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
import '../repositories/auth_repository.dart';
import '../repositories/schedule_repository.dart';

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromEnvironment(),
);

/// 앱은 Supabase에 연결된 것처럼 로컬 데모를 조용히 표시하지 않고,
/// 원격 초기화 실패를 사용자에게 알린다.
final supabaseReadyProvider = Provider<bool>((ref) => false);
final supabaseInitializationErrorProvider = Provider<String?>((ref) => null);

/// 릴리스 설정/초기화 실패가 있을 때 main.dart만 설정한다. 설정 화면의
/// 진단 정보와 분리해 두면 디버그/프로필 빌드는 로컬 데모를 계속 사용할
/// 수 있고, 릴리스 빌드는 컨트롤러나 로컬 저장소를 만들기 전에 차단된다.
final releaseConfigurationErrorProvider = Provider<String?>((ref) => null);

/// 로컬 미리보기 어댑터를 선택할 수 있는지 나타낸다. main.dart가 일반
/// 위젯 트리를 만들기 전에 릴리스 오류를 전달하며, 이 공급자는 추가
/// 방어 계층으로 저장소 계층도 안전하게 차단한다.
final localDemoAllowedProvider = Provider<bool>((ref) {
  return ref.watch(releaseConfigurationErrorProvider) == null;
});

final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (!config.hasSupabase || !ref.watch(supabaseReadyProvider)) return null;
  return Supabase.instance.client;
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final releaseError = ref.watch(releaseConfigurationErrorProvider);
  final allowDemo = ref.watch(localDemoAllowedProvider);
  final repository = client != null
      ? AuthRepository(client: client)
      : allowDemo
      ? AuthRepository()
      : ConfigurationBlockedAuthRepository(
          releaseError ?? '운영 서비스 설정을 확인해 주세요.',
        );
  ref.onDispose(repository.dispose);
  return repository;
});

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client != null) return SupabaseScheduleRepository(client);
  final releaseError = ref.watch(releaseConfigurationErrorProvider);
  final allowDemo = ref.watch(localDemoAllowedProvider);
  return allowDemo
      ? LocalScheduleRepository()
      : ConfigurationBlockedScheduleRepository(
          releaseError ?? '운영 서비스 설정을 확인해 주세요.',
        );
});

/// 라우팅과 인증 화면에서 사용하는 상위 수준 인증 흐름 상태다.
///
/// 확인 대기 상태는 성공적인 가입 결과이므로 [PlannerController.errorMessage]와
/// 분리해 둔다. 복구 이벤트도 새 비밀번호를 설정할 수 있는 유효한 임시
/// 세션을 뜻한다.
enum AuthFlowState {
  signedOut,
  signedIn,
  pendingEmailConfirmation,
  passwordRecovery,
}

/// Coalesced metadata refresh request emitted by a group lifecycle signal.
/// Keeping the operation context with the request lets a delayed roster read
/// fail closed when selection, identity, or planner revision changes before
/// the debounce timer fires.
class _GroupMetadataRefreshRequest {
  const _GroupMetadataRefreshRequest({
    required this.operation,
    required this.userId,
    required this.groupId,
  });

  final int operation;
  final String userId;
  final String groupId;
}

final plannerControllerProvider = ChangeNotifierProvider<PlannerController>((
  ref,
) {
  final controller = PlannerController(
    auth: ref.watch(authRepositoryProvider),
    repository: ref.watch(scheduleRepositoryProvider),
  );
  return controller;
});

class PlannerController extends ChangeNotifier {
  PlannerController({
    required AuthRepository auth,
    required ScheduleRepository repository,
    Duration oauthTimeout = const Duration(minutes: 2),
    Duration? socialAuthTimeout,
    PendingInviteStore? pendingInviteStore,
    Duration pendingInviteTtl = const Duration(minutes: 30),
  }) : _auth = auth,
       _repository = repository,
       _oauthTimeout = socialAuthTimeout ?? oauthTimeout,
       _pendingInviteStore =
           pendingInviteStore ?? createDefaultPendingInviteStore(),
       _pendingInviteTtl = pendingInviteTtl {
    if (pendingInviteTtl <= Duration.zero) {
      throw ArgumentError.value(
        pendingInviteTtl,
        'pendingInviteTtl',
        'must be positive',
      );
    }
    _authSubscription = _auth.onAuthStateChange.listen(
      _enqueueAuthEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (_disposed) return;
        errorMessage = _friendlyError(error);
        notifyListeners();
      },
    );
    _pendingHydration = _hydratePendingInvite();
    unawaited(bootstrap());
  }

  final AuthRepository _auth;
  final ScheduleRepository _repository;
  final Duration _oauthTimeout;
  final PendingInviteStore _pendingInviteStore;
  final Duration _pendingInviteTtl;
  late final Future<void> _pendingHydration;

  PlannerUser? user;
  List<PlannerGroup> groups = const <PlannerGroup>[];
  List<PlannerMember> members = const <PlannerMember>[];
  List<InviteCode> _invites = const <InviteCode>[];

  /// Invite rows are never allowed to retain the one-shot plaintext token at
  /// the controller boundary.  A repository/fake may return a token-bearing
  /// row, but every list assignment is defensively copied with `token: null`.
  List<InviteCode> get invites => _invites;

  set invites(Iterable<InviteCode> value) {
    _invites = List<InviteCode>.unmodifiable(value.map(_inviteWithoutToken));
  }

  List<PlannerEvent> _events = const <PlannerEvent>[];
  List<PlannerEvent> get events => _events;

  /// Preserve the public assignment used by older test doubles while keeping
  /// every event snapshot immutable at the controller boundary.
  set events(Iterable<PlannerEvent> value) {
    _events = List<PlannerEvent>.unmodifiable(value);
  }

  PlannerGroup? selectedGroup;
  DateTime selectedDay = DateTime.now();
  CalendarViewMode calendarView = CalendarViewMode.day;
  EventRange? selectedEventRange;
  bool hasMoreEvents = false;
  bool isLoadingEvents = false;
  bool isLoadingMoreEvents = false;
  String? rangeError;
  String? selectedMemberId;
  bool showAllMembers = true;
  bool isLoading = true;
  bool isSaving = false;
  bool isOffline = false;
  bool darkMode = false;
  double textScale = 1;
  String? errorMessage;
  AuthFlowState authFlowState = AuthFlowState.signedOut;
  String? pendingConfirmationEmail;
  String? passwordResetRequestedEmail;
  AuthEventType? lastAuthEvent;
  StreamSubscription<AuthRepositoryEvent>? _authSubscription;
  StreamSubscription<List<PlannerEvent>>? _eventSubscription;
  StreamSubscription<void>? _eventInvalidationSubscription;
  StreamSubscription<PlannerGroup?>? _groupLifecycleSubscription;
  Timer? _groupMetadataRefreshTimer;
  _GroupMetadataRefreshRequest? _pendingGroupMetadataRefresh;
  bool _groupMetadataRefreshInFlight = false;
  int _groupMetadataRefreshToken = 0;
  Future<void> _authEventQueue = Future<void>.value();
  int _authEventGeneration = 0;
  String? _queuedAuthIdentity;
  bool _authOperationInFlight = false;
  int _authOperationToken = 0;
  int _authOperationGeneration = 0;
  bool _authStateChangingOperationInFlight = false;
  // Planner operation owned by an explicit sign-out. Supabase can emit its
  // local SIGNED_OUT event before the remote revoke Future completes (and may
  // then report a revoke failure); that event must preserve this operation's
  // token so the caller can still surface the failure.
  int? _signOutOperationToken;
  String? _signOutFailureMessage;
  // Do not start a new auth owner while an explicit sign-out is still
  // revoking the previous SDK session. Supabase may emit SIGNED_OUT before
  // the revoke Future settles, so this gate serializes the next operation.
  Future<void>? _signOutSettlement;
  Completer<void>? _signOutSettlementCompleter;
  bool _ignoreExternalIdentityEvents = false;
  // OAuth has no callback request id in Supabase's public event payload. Once
  // a launch times out/fails, retain a tombstone so a late provider callback
  // cannot switch accounts after a different explicit login commits.
  bool _staleSocialAuthFence = false;
  String? _staleSocialExpectedIdentity;
  // A recovery event can be followed by userUpdated before its queued
  // handler runs. Keep that intent long enough for the coalesced update to
  // pass the social tombstone's account check.
  String? _queuedPasswordRecoveryIdentity;
  // Tracks whether the fenced identity came from an explicit auth result.
  // While a newer password operation is still waiting, a mismatched provider
  // event is ignored; once a result is committed, the same mismatch fails
  // closed and revokes the SDK session.
  bool _staleSocialIdentityCommitted = false;
  bool _staleSocialPendingMismatchObserved = false;
  bool _fencedIdentityRevocationInFlight = false;
  Future<void>? _fencedIdentityRevocation;
  SocialAuthProvider? _socialAuthProviderInFlight;
  Timer? _oauthTimeoutTimer;
  int _socialAuthGeneration = 0;
  int _socialAuthOperationToken = 0;
  // 비동기 일정방 작업은 이 세대 값과 사용자/선택된 일정방을 함께
  // 확인한 뒤에만 결과를 커밋한다. 로그아웃이나 새 선택이 진행 중인
  // 동안 먼저 시작한 요청이 늦게 도착해 개인 데이터를 되살리지 않게
  // 한다.
  int _plannerRevision = 0;
  int _plannerSessionGeneration = 0;
  int _operationToken = 0;
  // Monotonic planner-operation generation used to prevent an older
  // conflict-reload continuation from overwriting a newer operation's error.
  // Conflict-owned refreshes preserve this value across their internal
  // loadGroups/selectGroup sequence; every external operation advances it.
  int _operationGeneration = 0;
  int _savingOperationToken = 0;
  bool _inviteCodeInFlight = false;
  int _groupOperationToken = 0;
  EventRangeCursor? _rangeCursor;
  int _rangeGeneration = 0;
  bool _rangeRefreshInFlight = false;
  int? _rangeRefreshOwnerGeneration;
  bool _rangeLoadMoreInFlight = false;
  int? _rangeLoadMoreOwnerGeneration;
  bool _rangeRefreshQueued = false;
  Timer? _rangeInvalidationTimer;
  String? _rangeKey;
  final Set<String> _terminalGroupOperations = <String>{};
  // Leave/archive and a remote lifecycle tombstone are terminal from the
  // controller's point of view.  Keeping this separate from the in-flight
  // operation set prevents a stale groups refresh from reintroducing private
  // data after the mutation has succeeded.  A successful explicit rejoin
  // clears the tombstone for an ordinary (non-archived) leave.
  final Set<String> _terminalGroupTombstones = <String>{};
  int _inviteOperation = 0;
  // Pending invite intents are intentionally independent from planner
  // clearing/auth operation generations.  An intent captured while signed
  // out must survive the first successful login, but an explicit sign-out or
  // subsequent identity switch must invalidate it synchronously.
  String? _pendingInviteToken;
  DateTime? _pendingInviteExpiresAt;
  String? _pendingInviteReturnRoute;
  String? _pendingInviteBoundUserId;
  PendingInviteState _pendingInviteState = PendingInviteState.none;
  InvitePreview? _pendingInvitePreview;
  String? _pendingInviteError;
  int _pendingInviteGeneration = 0;
  int _pendingInviteSessionGeneration = 0;
  // Planner/group operations advance `_plannerRevision` without clearing an
  // invite intent.  Capture the revision at each preview/accept attempt so a
  // callback that belongs to an older selected-group context cannot commit a
  // projection into a newer one.
  int _pendingInvitePlannerRevision = 0;
  int _pendingInviteAcceptGeneration = 0;
  bool _pendingInvitePreviewInFlight = false;
  bool _pendingInviteAcceptInFlight = false;
  Future<InvitePreview?>? _pendingInvitePreviewFuture;
  int _pendingInvitePreviewRequestCounter = 0;
  int? _pendingInvitePreviewActiveRequestId;
  int? _pendingInvitePreviewFutureGeneration;
  String? _pendingInvitePreviewFutureToken;
  String? _pendingInvitePreviewFutureUserId;
  int? _pendingInvitePreviewFutureSessionGeneration;
  int? _pendingInvitePreviewFuturePlannerRevision;
  Timer? _pendingInviteExpiryTimer;
  Future<void> _pendingStoreQueue = Future<void>.value();
  StreamSubscription<Uri>? _inviteLinkSubscription;
  bool _disposed = false;

  bool get isAuthenticated => user != null;

  /// Whether this adapter can perform an authoritative point lookup for a
  /// detail route. Legacy full-stream test/double adapters intentionally do
  /// not opt into this path.
  bool get supportsEventById =>
      _usesBoundedEventRangeReads && _repository is EventByIdReadCapability;

  bool get _usesBoundedEventRangeReads {
    final repository = _repository;
    if (repository is SupabaseScheduleRepository ||
        repository is ConfigurationBlockedScheduleRepository) {
      return true;
    }
    if (repository is LocalScheduleRepository) {
      return repository.useBoundedEventRangeReads;
    }
    return repository is BoundedEventRangeReadCapability;
  }

  bool get _requiresExactEventMutationResults {
    final repository = _repository;
    if (repository is LocalScheduleRepository) {
      return repository.requireExactEventMutationResults;
    }
    // Any non-local adapter that advertises participant mutation is a
    // production capability and must echo the exact persisted assignment.
    // Older non-capability adapters are allowed only the omitted-field legacy
    // creator fallback below; explicit member lists fail before mutation.
    return repository is EventMemberAssignmentCapability;
  }

  /// 인증 UI와 경로 보호에서 편하게 사용할 수 있는 별칭이다.
  AuthFlowState get authState => authFlowState;
  AuthFlowState get authStatus => authFlowState;
  String? get pendingEmailConfirmation => pendingConfirmationEmail;
  bool get isAwaitingEmailConfirmation =>
      authFlowState == AuthFlowState.pendingEmailConfirmation;
  bool get isInPasswordRecovery =>
      authFlowState == AuthFlowState.passwordRecovery;
  bool get isSocialAuthInFlight => _socialAuthProviderInFlight != null;
  bool get isOAuthInFlight => isSocialAuthInFlight;
  SocialAuthProvider? get socialAuthProviderInFlight =>
      _socialAuthProviderInFlight;

  /// Public invite projection.  The bearer token remains private to this
  /// controller and its ephemeral store; UI code receives only sanitized
  /// preview/status data.
  PendingInviteSnapshot? get pendingInvite {
    if (_pendingInviteState == PendingInviteState.none) return null;
    return PendingInviteSnapshot(
      state: _pendingInviteState,
      preview: _pendingInvitePreview,
      error: _pendingInviteError,
      generation: _pendingInviteGeneration,
      returnRoute: _pendingInviteReturnRoute,
      expiresAt: _pendingInviteExpiresAt,
    );
  }

  PendingInviteSnapshot? get pendingInviteSnapshot => pendingInvite;
  PendingInviteState get pendingInviteState => _pendingInviteState;
  InvitePreview? get pendingInvitePreview => _pendingInvitePreview;
  String? get pendingInviteError => _pendingInviteError;
  String? get pendingInviteReturnRoute => _pendingInviteReturnRoute;
  bool get hasPendingInvite => _pendingInviteToken != null;
  bool get isPreviewingInvite => _pendingInvitePreviewInFlight;
  bool get isAcceptingInvite => _pendingInviteAcceptInFlight;

  /// Binds platform deep-link intake without coupling the controller to a
  /// native/web plugin.  A replacement stream retires the previous
  /// subscription; every URI is validated before it can create state.
  void bindInviteLinkStream(
    Stream<Uri> links, {
    AppConfig? config,
    required bool isRelease,
    bool allowLocalhostHttp = true,
  }) {
    final effectiveConfig = config ?? AppConfig.fromEnvironment();
    unawaited(_inviteLinkSubscription?.cancel());
    _inviteLinkSubscription = links.listen((uri) {
      captureInviteUri(
        uri,
        config: effectiveConfig,
        isRelease: isRelease,
        allowLocalhostHttp: allowLocalhostHttp,
      );
    });
  }

  List<PlannerEvent> get visibleEvents {
    final selected = dateOnly(selectedDay);
    final viewTimezone = selectedGroup?.timezone;
    final filtered = events.where((event) {
      final overlaps = viewTimezone == null
          ? _legacyEventOverlapsSelectedDay(event, selected)
          : eventOverlapsCalendarDate(event, selected, viewTimezone);
      final memberMatches =
          showAllMembers ||
          selectedMemberId == null ||
          event.memberIds.contains(selectedMemberId);
      return overlaps && memberMatches && !event.isDeleted;
    }).toList();
    filtered.sort((a, b) {
      final byStart = a.startAt.compareTo(b.startAt);
      return byStart != 0 ? byStart : a.id.compareTo(b.id);
    });
    return filtered;
  }

  bool _legacyEventOverlapsSelectedDay(PlannerEvent event, DateTime selected) {
    final start = dateOnly(selected);
    final end = calendarDateAdd(start, 1);
    if (event.allDay) {
      final eventStartDate = dateOnly(
        event.allDayStartDate ?? utcToWallTime(event.startAt, event.timezone),
      );
      final eventEndDate = dateOnly(
        event.allDayEndDate ?? utcToWallTime(event.endAt, event.timezone),
      );
      return !start.isBefore(eventStartDate) && start.isBefore(eventEndDate);
    }
    final eventStart = utcToWallTime(event.startAt, event.timezone);
    final eventEnd = utcToWallTime(event.endAt, event.timezone);
    return eventStart.isBefore(end) && eventEnd.isAfter(start);
  }

  Future<void> bootstrap() async {
    final operation = ++_plannerRevision;
    isLoading = true;
    notifyListeners();
    PlannerUser? existing;
    try {
      await _pendingHydration;
      existing = _auth.currentUser;
      if (existing != null) {
        user = existing;
        authFlowState = AuthFlowState.signedIn;
        _bindPendingInviteToUser(existing.id);
        await loadGroups();
      } else {
        authFlowState = AuthFlowState.signedOut;
      }
    } catch (error) {
      if (_plannerRevision == operation) {
        errorMessage = _friendlyError(error);
      }
    } finally {
      // loadGroups starts its own operation. Do not let this older bootstrap
      // turn off a spinner owned by a newer auth/load request.
      if (_plannerRevision == operation) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _hydratePendingInvite() async {
    // A slow storage read must not be able to resurrect an intent that was
    // explicitly cleared (or invalidated by a newer auth/planner session)
    // while the read was pending.
    final hydrationGeneration = _pendingInviteGeneration;
    final hydrationSessionGeneration = _plannerSessionGeneration;
    PendingInviteRecord? stored;
    try {
      stored = await _pendingInviteStore.readRecord();
    } catch (_) {
      stored = null;
    }
    if (_disposed ||
        _pendingInviteToken != null ||
        hydrationGeneration != _pendingInviteGeneration ||
        hydrationSessionGeneration != _plannerSessionGeneration ||
        stored == null) {
      return;
    }
    final normalized = normalizeStrictInviteToken(stored.token);
    if (normalized == null) {
      _queuePendingStoreClear();
      return;
    }
    // The store has already enforced its persisted expiry.  Legacy stores
    // without a deadline get a bounded in-tab fallback.
    final expiresAt =
        stored.expiresAt ?? DateTime.now().toUtc().add(_pendingInviteTtl);
    if (!expiresAt.isAfter(DateTime.now().toUtc())) {
      _queuePendingStoreClear();
      return;
    }
    _pendingInviteToken = normalized;
    _pendingInviteExpiresAt = expiresAt;
    _pendingInviteBoundUserId = user?.id;
    _pendingInviteSessionGeneration = _plannerSessionGeneration;
    _pendingInvitePlannerRevision = _plannerRevision;
    _pendingInviteState = PendingInviteState.captured;
    _pendingInvitePreview = null;
    _pendingInviteError = null;
    _schedulePendingInviteExpiry(expiresAt, _pendingInviteGeneration);
    notifyListeners();
  }

  /// Captures a strictly validated link while keeping the raw URI out of
  /// controller state.  Invalid or unconfigured links are ignored so a
  /// malformed deep link cannot become a user-visible token oracle.
  bool captureInviteUri(
    Uri uri, {
    required AppConfig config,
    Uri? currentOrigin,
    required bool isRelease,
    bool allowLocalhostHttp = true,
    String? returnRoute,
  }) {
    final parsed = InviteLinkParser.tryParse(
      uri,
      config: config,
      currentOrigin: currentOrigin,
      isRelease: isRelease,
      allowLocalhostHttp: allowLocalhostHttp,
    );
    if (parsed == null) return false;
    return captureInviteToken(parsed.token, returnRoute: returnRoute);
  }

  /// Captures a canonical token supplied by platform routing.  Manual code
  /// entry continues through [joinGroup]; this method intentionally rejects
  /// the local `family` demo magic code and display separators.
  bool captureInviteToken(String token, {String? returnRoute}) {
    final normalized = normalizeStrictInviteToken(token);
    if (normalized == null) return false;
    if (_pendingInviteToken == normalized &&
        _pendingInviteState != PendingInviteState.none &&
        _pendingInviteExpiresAt != null &&
        _pendingInviteExpiresAt!.isAfter(DateTime.now().toUtc())) {
      return true;
    }
    ++_pendingInviteGeneration;
    _pendingInviteToken = normalized;
    _pendingInviteExpiresAt = DateTime.now().toUtc().add(_pendingInviteTtl);
    _pendingInviteBoundUserId = user?.id;
    _pendingInviteSessionGeneration = _plannerSessionGeneration;
    _pendingInvitePlannerRevision = _plannerRevision;
    _pendingInviteReturnRoute = _sanitizeInviteReturnRoute(returnRoute);
    _pendingInviteState = PendingInviteState.captured;
    _pendingInvitePreview = null;
    _pendingInviteError = null;
    _pendingInvitePreviewInFlight = false;
    _pendingInviteAcceptInFlight = false;
    final generation = _pendingInviteGeneration;
    final expiresAt = _pendingInviteExpiresAt!;
    _schedulePendingInviteExpiry(expiresAt, generation);
    _queuePendingStoreWrite(normalized, expiresAt, generation);
    notifyListeners();
    return true;
  }

  Future<InvitePreview?> previewPendingInvite() async {
    await _pendingHydration;
    final token = _pendingInviteToken;
    final current = user;
    if (token == null) return null;
    if (current == null) {
      throw const AuthException('로그인 세션을 다시 확인해 주세요.');
    }
    if (_pendingInviteExpiresAt == null ||
        !_pendingInviteExpiresAt!.isAfter(DateTime.now().toUtc())) {
      _expirePendingInvite();
      return null;
    }
    final capability = _repository;
    if (capability is! InvitePreviewCapability) {
      const error = ScheduleCapabilityException('초대 미리보기를 지원하지 않는 저장소입니다.');
      _setPendingInviteError(error);
      throw error;
    }
    final previewCapability = capability as InvitePreviewCapability;
    if (_pendingInviteBoundUserId == null) {
      _bindPendingInviteToUser(current.id);
    }
    if (_pendingInviteBoundUserId != current.id) {
      _clearPendingInvite();
      return null;
    }
    final generation = _pendingInviteGeneration;
    final sessionGeneration = _plannerSessionGeneration;
    final plannerRevision = _plannerRevision;
    _pendingInvitePlannerRevision = plannerRevision;
    if (_matchesPendingInvitePreviewFuture(
      generation: generation,
      token: token,
      userId: current.id,
      sessionGeneration: sessionGeneration,
      plannerRevision: plannerRevision,
    )) {
      // A second route/widget callback for this same intent joins the
      // existing request instead of issuing another oracle call.
      return _pendingInvitePreviewFuture!;
    }
    final requestId = ++_pendingInvitePreviewRequestCounter;
    _pendingInvitePreviewActiveRequestId = requestId;
    final future = _previewPendingInviteRequest(
      capability: previewCapability,
      token: token,
      userId: current.id,
      generation: generation,
      sessionGeneration: sessionGeneration,
      plannerRevision: plannerRevision,
      requestId: requestId,
    );
    _pendingInvitePreviewFuture = future;
    _pendingInvitePreviewFutureGeneration = generation;
    _pendingInvitePreviewFutureToken = token;
    _pendingInvitePreviewFutureUserId = current.id;
    _pendingInvitePreviewFutureSessionGeneration = sessionGeneration;
    _pendingInvitePreviewFuturePlannerRevision = plannerRevision;
    try {
      return await future;
    } finally {
      if (identical(_pendingInvitePreviewFuture, future)) {
        _clearPendingInvitePreviewFuture();
      }
    }
  }

  Future<InvitePreview?> _previewPendingInviteRequest({
    required InvitePreviewCapability capability,
    required String token,
    required String userId,
    required int generation,
    required int sessionGeneration,
    required int plannerRevision,
    required int requestId,
  }) async {
    _pendingInvitePreviewInFlight = true;
    _pendingInviteState = PendingInviteState.loading;
    _pendingInviteError = null;
    notifyListeners();
    try {
      final preview = await capability.previewInvite(
        userId: userId,
        token: token,
      );
      if (!_isCurrentPendingInvite(
        generation: generation,
        token: token,
        userId: userId,
        sessionGeneration: sessionGeneration,
        plannerRevision: plannerRevision,
      )) {
        return null;
      }
      _pendingInvitePreview = preview;
      _pendingInviteState = PendingInviteState.ready;
      _pendingInviteError = null;
      return preview;
    } catch (error) {
      if (_isCurrentPendingInvite(
        generation: generation,
        token: token,
        userId: userId,
        sessionGeneration: sessionGeneration,
        plannerRevision: plannerRevision,
      )) {
        _setPendingInviteError(error, notify: false);
      }
      rethrow;
    } finally {
      if (_isActivePendingInvitePreviewRequest(
        requestId: requestId,
        generation: generation,
        token: token,
        userId: userId,
        sessionGeneration: sessionGeneration,
        plannerRevision: plannerRevision,
      )) {
        _pendingInvitePreviewInFlight = false;
        if (_pendingInviteState == PendingInviteState.loading) {
          _pendingInviteState = PendingInviteState.captured;
        }
        notifyListeners();
      }
    }
  }

  Future<InvitePreview?> retryPendingInvite() => previewPendingInvite();

  /// Performs the explicit accept exactly once.  The pending token is
  /// cleared immediately after the server join commits, before selecting the
  /// group, so a subsequent group-load failure cannot cause a second join.
  Future<PlannerGroup?> acceptPendingInvite() async {
    await _pendingHydration;
    final token = _pendingInviteToken;
    final current = user;
    final preview = _pendingInvitePreview;
    if (token == null || current == null || preview == null) return null;
    if (_pendingInviteState != PendingInviteState.ready ||
        _pendingInviteAcceptInFlight) {
      return null;
    }
    // A preview can intentionally report `alreadyMember: true` even when
    // the token has since expired/revoked/exhausted. The membership may have
    // changed between preview and accept, so never trust this hint to bypass
    // the authoritative idempotent join RPC. Only a non-member with a locally
    // expired preview is terminal before making that request.
    if (!preview.alreadyMember && preview.isExpired) {
      _expirePendingInvite();
      return null;
    }
    final generation = _pendingInviteGeneration;
    final sessionGeneration = _plannerSessionGeneration;
    final plannerRevision = _pendingInvitePlannerRevision;
    final userId = current.id;
    _pendingInviteAcceptGeneration = generation;
    _pendingInviteAcceptInFlight = true;
    _pendingInviteState = PendingInviteState.accepting;
    _pendingInviteError = null;
    notifyListeners();
    var committed = false;
    try {
      final joined = await _repository.joinGroup(userId, token);
      committed = true;
      if (!_isCurrentPendingInvite(
        generation: generation,
        token: token,
        userId: userId,
        sessionGeneration: sessionGeneration,
        plannerRevision: plannerRevision,
      )) {
        // The join RPC has already committed. If only the selected planner
        // context became stale, clear this exact generation before returning
        // so a caller cannot retry the same bearer token. A newer token or
        // identity has its own generation and remains untouched.
        _clearPendingInviteIfCurrent(
          generation: generation,
          token: token,
          userId: userId,
          sessionGeneration: sessionGeneration,
        );
        return null;
      }
      _clearPendingInvite();
      if (!groups.any((candidate) => candidate.id == joined.id)) {
        groups = <PlannerGroup>[...groups, joined];
      }
      try {
        await selectGroup(joined.id);
      } catch (error) {
        if (user?.id == userId && !_disposed) {
          errorMessage = _friendlyError(error);
          notifyListeners();
        }
      }
      return joined;
    } catch (error) {
      if (error is InviteJoinCommittedException) {
        // The repository has already committed membership but could not load
        // the resulting group projection. Clear this exact bearer intent even
        // when a planner revision changed; retrying would submit the token a
        // second time. A newer token or identity remains untouched.
        final exactPendingContext = _isCurrentPendingInvite(
          generation: generation,
          token: token,
          userId: userId,
          sessionGeneration: sessionGeneration,
          plannerRevision: plannerRevision,
        );
        _clearPendingInviteIfCurrent(
          generation: generation,
          token: token,
          userId: userId,
          sessionGeneration: sessionGeneration,
        );
        if (exactPendingContext && !_disposed && user?.id == userId) {
          errorMessage = _friendlyError(error);
          notifyListeners();
        }
        rethrow;
      }
      if (!committed &&
          _isCurrentPendingInvite(
            generation: generation,
            token: token,
            userId: userId,
            sessionGeneration: sessionGeneration,
            plannerRevision: plannerRevision,
          )) {
        _setPendingInviteError(error, notify: false);
      }
      rethrow;
    } finally {
      if (_pendingInviteAcceptGeneration == generation &&
          _pendingInviteToken == token &&
          user?.id == userId &&
          _pendingInviteBoundUserId == userId &&
          _pendingInviteSessionGeneration == sessionGeneration &&
          _plannerSessionGeneration == sessionGeneration &&
          _plannerRevision == plannerRevision) {
        _pendingInviteAcceptInFlight = false;
        notifyListeners();
      }
    }
  }

  void cancelPendingInvite() => _clearPendingInvite();

  /// Account-deletion flows can use the same privacy fence as explicit
  /// cancellation without depending on the invite implementation details.
  void clearPendingInvite() => _clearPendingInvite();

  void _bindPendingInviteToUser(String userId) {
    final token = _pendingInviteToken;
    if (token == null || userId.trim().isEmpty) return;
    final bound = _pendingInviteBoundUserId;
    if (bound != null && bound != userId) {
      _clearPendingInvite();
      return;
    }
    _pendingInviteBoundUserId = userId;
    _pendingInviteSessionGeneration = _plannerSessionGeneration;
    _pendingInvitePlannerRevision = _plannerRevision;
  }

  bool _isCurrentPendingInvite({
    required int generation,
    required String token,
    required String userId,
    required int sessionGeneration,
    int? plannerRevision,
  }) {
    return !_disposed &&
        generation == _pendingInviteGeneration &&
        token == _pendingInviteToken &&
        user?.id == userId &&
        _pendingInviteBoundUserId == userId &&
        _pendingInviteSessionGeneration == sessionGeneration &&
        _plannerSessionGeneration == sessionGeneration &&
        (plannerRevision == null || _plannerRevision == plannerRevision);
  }

  void _clearPendingInviteIfCurrent({
    required int generation,
    required String token,
    required String userId,
    required int sessionGeneration,
  }) {
    if (_disposed ||
        generation != _pendingInviteGeneration ||
        token != _pendingInviteToken ||
        user?.id != userId ||
        _pendingInviteBoundUserId != userId ||
        _pendingInviteSessionGeneration != sessionGeneration ||
        _plannerSessionGeneration != sessionGeneration) {
      return;
    }
    _clearPendingInvite();
  }

  void _setPendingInviteError(Object error, {bool notify = true}) {
    if (error is InviteUnavailableException) {
      // Expiry retires the generation, so the preview finally block will not
      // emit its usual state-change notification. Always notify here even
      // when the caller suppressed the transient catch notification.
      _expirePendingInvite(error: error, notify: true);
      return;
    }
    _pendingInviteError = _friendlyError(error);
    _pendingInviteState = PendingInviteState.error;
    if (notify) notifyListeners();
  }

  /// Retires the bearer token and persisted intent while retaining a
  /// token-free terminal error long enough for the landing page to explain
  /// why no preview is available. The route can be dismissed without a
  /// subsequent retry accidentally probing an expired token.
  void _expirePendingInvite({
    Object error = const InviteUnavailableException.invalidOrExpired(),
    bool notify = true,
  }) {
    if (_pendingInviteToken == null &&
        _pendingInviteState == PendingInviteState.none) {
      return;
    }
    ++_pendingInviteGeneration;
    _pendingInviteToken = null;
    _pendingInviteExpiresAt = null;
    _pendingInviteReturnRoute = null;
    _pendingInviteBoundUserId = null;
    _pendingInvitePlannerRevision = 0;
    _pendingInvitePreview = null;
    _pendingInviteError = _friendlyError(error);
    _pendingInviteState = PendingInviteState.error;
    _pendingInvitePreviewInFlight = false;
    _pendingInviteAcceptInFlight = false;
    _clearPendingInvitePreviewFuture();
    _pendingInviteExpiryTimer?.cancel();
    _pendingInviteExpiryTimer = null;
    _queuePendingStoreClear();
    if (notify) notifyListeners();
  }

  void _clearPendingInvite() {
    if (_pendingInviteState == PendingInviteState.none &&
        _pendingInviteToken == null) {
      // Even before hydration has completed, an explicit cancel/sign-out is a
      // privacy fence. Advance the generation so a slow persisted-store read
      // cannot repopulate the just-cleared intent, and clear any stale record
      // best-effort without emitting a no-op notification.
      ++_pendingInviteGeneration;
      _clearPendingInvitePreviewFuture();
      _pendingInviteExpiryTimer?.cancel();
      _pendingInviteExpiryTimer = null;
      _queuePendingStoreClear();
      return;
    }
    ++_pendingInviteGeneration;
    _pendingInviteToken = null;
    _pendingInviteExpiresAt = null;
    _pendingInviteReturnRoute = null;
    _pendingInviteBoundUserId = null;
    _pendingInvitePlannerRevision = 0;
    _pendingInvitePreview = null;
    _pendingInviteError = null;
    _pendingInviteState = PendingInviteState.none;
    _pendingInvitePreviewInFlight = false;
    _pendingInviteAcceptInFlight = false;
    _clearPendingInvitePreviewFuture();
    _pendingInviteExpiryTimer?.cancel();
    _pendingInviteExpiryTimer = null;
    _queuePendingStoreClear();
    notifyListeners();
  }

  void _schedulePendingInviteExpiry(DateTime expiresAt, int generation) {
    _pendingInviteExpiryTimer?.cancel();
    final delay = expiresAt.difference(DateTime.now().toUtc());
    _pendingInviteExpiryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        _pendingInviteExpiryTimer = null;
        if (_disposed ||
            generation != _pendingInviteGeneration ||
            _pendingInviteToken == null ||
            _pendingInviteExpiresAt != expiresAt) {
          return;
        }
        _expirePendingInvite();
      },
    );
  }

  void _clearPendingInvitePreviewFuture() {
    _pendingInvitePreviewFuture = null;
    _pendingInvitePreviewActiveRequestId = null;
    _pendingInvitePreviewFutureGeneration = null;
    _pendingInvitePreviewFutureToken = null;
    _pendingInvitePreviewFutureUserId = null;
    _pendingInvitePreviewFutureSessionGeneration = null;
    _pendingInvitePreviewFuturePlannerRevision = null;
  }

  bool _isActivePendingInvitePreviewRequest({
    required int requestId,
    required int generation,
    required String token,
    required String userId,
    required int sessionGeneration,
    required int plannerRevision,
  }) {
    return !_disposed &&
        _pendingInvitePreviewActiveRequestId == requestId &&
        generation == _pendingInviteGeneration &&
        token == _pendingInviteToken &&
        user?.id == userId &&
        _pendingInviteBoundUserId == userId &&
        _pendingInviteSessionGeneration == sessionGeneration &&
        _plannerSessionGeneration == sessionGeneration &&
        _pendingInvitePreviewFutureGeneration == generation &&
        _pendingInvitePreviewFutureToken == token &&
        _pendingInvitePreviewFutureUserId == userId &&
        _pendingInvitePreviewFutureSessionGeneration == sessionGeneration &&
        _pendingInvitePreviewFuturePlannerRevision == plannerRevision;
  }

  bool _matchesPendingInvitePreviewFuture({
    required int generation,
    required String token,
    required String userId,
    required int sessionGeneration,
    required int plannerRevision,
  }) {
    return _pendingInvitePreviewFuture != null &&
        _pendingInvitePreviewFutureGeneration == generation &&
        _pendingInvitePreviewFutureToken == token &&
        _pendingInvitePreviewFutureUserId == userId &&
        _pendingInvitePreviewFutureSessionGeneration == sessionGeneration &&
        _pendingInvitePreviewFuturePlannerRevision == plannerRevision;
  }

  void _queuePendingStoreWrite(
    String token,
    DateTime expiresAt,
    int generation,
  ) {
    _pendingStoreQueue = _pendingStoreQueue.then((_) async {
      if (_disposed || generation != _pendingInviteGeneration) return;
      try {
        await _pendingInviteStore.write(token, expiresAt);
      } catch (_) {
        // Persistence is best effort; live controller state remains valid.
      }
    });
  }

  void _queuePendingStoreClear() {
    _pendingStoreQueue = _pendingStoreQueue.then((_) async {
      try {
        await _pendingInviteStore.clear();
      } catch (_) {
        // Best effort and intentionally silent.
      }
    });
  }

  static String? _sanitizeInviteReturnRoute(String? route) {
    if (route == null || route.isEmpty || route != route.trim()) return null;
    if (!route.startsWith('/') || route.contains('?') || route.contains('#')) {
      return null;
    }
    if (route == '/invite' || route.startsWith('/invite/')) return null;
    if (route == '/auth-callback' || route.startsWith('/auth-callback/')) {
      return null;
    }
    return route;
  }

  Future<void> signIn(String email, String password) async {
    await _runAuth(() => _auth.signIn(email, password));
  }

  /// 브라우저 기반 소셜 로그인을 시작한다. 저장소는 브라우저가 실행됐다는
  /// 사실만 보고하며, 이 컨트롤러는 콜백에서 발생한 타입 지정 인증 이벤트를
  /// 실제 로그인 결과로 처리한다.
  Future<void> signInWithOAuth(SocialAuthProvider provider) async {
    await _awaitSignOutSettlement();
    await _awaitFencedIdentityRevocation();
    if (_authOperationInFlight || _socialAuthProviderInFlight != null) {
      const error = AuthException(socialAuthBusyMessage);
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = ++_operationToken;
    if (_signOutOperationToken != null && _signOutOperationToken != operation) {
      _signOutOperationToken = null;
      _signOutFailureMessage = null;
    }
    final generation = ++_socialAuthGeneration;
    _socialAuthOperationToken = operation;
    _socialAuthProviderInFlight = provider;
    // This is an intentional new OAuth request, so it owns a fresh callback
    // stream instead of inheriting a prior timed-out launch's tombstone.
    _staleSocialAuthFence = false;
    _staleSocialExpectedIdentity = null;
    _queuedPasswordRecoveryIdentity = null;
    _staleSocialIdentityCommitted = false;
    _staleSocialPendingMismatchObserved = false;
    _ignoreExternalIdentityEvents = false;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    _oauthTimeoutTimer?.cancel();
    _oauthTimeoutTimer = Timer(_oauthTimeout, () {
      if (!_isCurrentSocialAuth(operation, generation)) return;
      errorMessage = socialAuthTimeoutMessage;
      _fenceStaleSocialAuth();
      _finishSocialAuth(operation, generation);
    });
    try {
      final launched = await _auth
          .signInWithOAuth(provider)
          .timeout(
            _oauthTimeout,
            onTimeout: () => Future<bool>.error(
              const AuthException(socialAuthTimeoutMessage),
            ),
          );
      if (!_isCurrentSocialAuth(operation, generation)) return;
      if (!launched) {
        throw const AuthException(socialAuthLaunchFailedMessage);
      }
    } catch (error) {
      final friendly = _friendlySocialError(error);
      if (_isCurrentSocialAuth(operation, generation)) {
        errorMessage = friendly;
        // A provider callback may arrive after launch failure/timeout. Keep
        // that callback fenced until a subsequent explicit auth operation
        // commits an identity.
        _fenceStaleSocialAuth();
        _finishSocialAuth(operation, generation);
      }
      throw AuthException(friendly);
    }
  }

  /// 제공자 중심 호출자를 위해 유지하는 별칭이다.
  Future<void> signInWithProvider(SocialAuthProvider provider) =>
      signInWithOAuth(provider);

  Future<void> oauthSignIn(SocialAuthProvider provider) =>
      signInWithOAuth(provider);

  Future<AuthSignUpResult> signUp(
    String email,
    String password,
    String name,
  ) async {
    await _awaitSignOutSettlement();
    await _awaitFencedIdentityRevocation();
    final operation = _beginAuthOperation(sessionChanging: true);
    final generation = _authOperationGeneration;
    errorMessage = null;
    pendingConfirmationEmail = null;
    _startSaving(operation);
    notifyListeners();
    try {
      final result = await _auth.signUp(email, password, name);
      if (!_isCurrentAuthOperation(operation, generation)) {
        _revokeStaleAuthResultIfSignedOut();
        return result;
      }
      if (result.requiresEmailConfirmation) {
        // 세션이 없는 Supabase 사용자는 인증된 상태가 아니다. 확인 응답과
        // 함께 사용자 객체가 반환됐다는 이유만으로 활성 플래너 사용자로
        // 보존하지 않는다.
        user = null;
        authFlowState = AuthFlowState.pendingEmailConfirmation;
        pendingConfirmationEmail = result.email;
        // A new explicit email-confirmation flow owns the pending address,
        // even when a previous OAuth launch left a stale social fence.  The
        // matching-address check below still rejects unrelated callbacks.
        if (_staleSocialAuthFence) {
          _staleSocialExpectedIdentity = null;
          _staleSocialIdentityCommitted = false;
        }
        await _clearPlannerData(invalidateOperation: false, clearSaving: false);
        if (_staleSocialPendingMismatchObserved) {
          _failClosedForFencedIdentity();
        }
      } else {
        final authenticated = result.user;
        if (authenticated == null) {
          throw const AuthException('가입을 완료할 수 없습니다. 다시 시도해 주세요.');
        }
        await _commitAuthenticatedUser(authenticated, operation, generation);
      }
      return result;
    } catch (error) {
      if (_isCurrentAuthOperation(operation, generation)) {
        errorMessage = _friendlyError(error);
        if (_staleSocialPendingMismatchObserved) {
          _failClosedForFencedIdentity();
        }
      }
      rethrow;
    } finally {
      _finishAuthOperation(operation, generation);
      _finishSaving(operation);
    }
  }

  Future<void> _runAuth(Future<PlannerUser> Function() operation) async {
    await _awaitSignOutSettlement();
    await _awaitFencedIdentityRevocation();
    final authOperation = _beginAuthOperation(sessionChanging: true);
    final generation = _authOperationGeneration;
    errorMessage = null;
    _startSaving(authOperation);
    notifyListeners();
    try {
      final authenticated = await operation();
      if (!_isCurrentAuthOperation(authOperation, generation)) {
        _revokeStaleAuthResultIfSignedOut();
        return;
      }
      await _commitAuthenticatedUser(authenticated, authOperation, generation);
    } catch (error) {
      if (_isCurrentAuthOperation(authOperation, generation)) {
        errorMessage = _friendlyError(error);
        if (_staleSocialPendingMismatchObserved) {
          _failClosedForFencedIdentity();
        }
      }
      rethrow;
    } finally {
      _finishAuthOperation(authOperation, generation);
      _finishSaving(authOperation);
    }
  }

  Future<void> signOut() async {
    // Serialize consecutive explicit sign-outs as well as new auth requests.
    // The first call owns the SDK revoke; a second call waits until that
    // ownership has settled before taking a new operation token.
    await _awaitSignOutSettlement();
    final operation = ++_operationToken;
    final settlementCompleter = Completer<void>();
    final settlement = settlementCompleter.future;
    _signOutSettlement = settlement;
    _signOutSettlementCompleter = settlementCompleter;
    _signOutOperationToken = operation;
    _signOutFailureMessage = null;
    _invalidateAuthOperations();
    _finishSocialAuth();
    _queuedAuthIdentity = null;
    _staleSocialAuthFence = true;
    _ignoreExternalIdentityEvents = true;
    // Keep an existing stale-social tombstone active, but forget the identity
    // it previously committed.  A callback for that account after sign-out
    // must not be accepted as a new session.
    _staleSocialExpectedIdentity = null;
    _queuedPasswordRecoveryIdentity = null;
    _staleSocialIdentityCommitted = false;
    _staleSocialPendingMismatchObserved = false;
    // Explicit sign-out is a terminal privacy boundary for invite intents.
    _clearPendingInvite();
    try {
      // Clear local state before waiting for a potentially slow remote revoke.
      // The clear helper mutates synchronously before its first await.
      final clear = _clearPlannerData(invalidateOperation: false);
      authFlowState = AuthFlowState.signedOut;
      pendingConfirmationEmail = null;
      passwordResetRequestedEmail = null;
      errorMessage = null;
      notifyListeners();
      await clear;
      await _awaitFencedIdentityRevocation();

      Object? failure;
      StackTrace? failureStack;
      try {
        await _auth.signOut();
      } catch (error, stackTrace) {
        failure = error;
        failureStack = stackTrace;
      }
      if (!_isOperationCurrent(operation, userId: null)) return;
      authFlowState = AuthFlowState.signedOut;
      pendingConfirmationEmail = null;
      passwordResetRequestedEmail = null;
      // Sign-out failures can contain provider/server details even when the
      // repository is replaced by a test double. Keep the UI and rethrown
      // exception on the same stable, user-safe session message.
      final safeFailure = failure == null
          ? null
          : const AuthException(authSessionErrorMessage);
      _signOutFailureMessage = safeFailure?.message;
      errorMessage = _signOutFailureMessage;
      notifyListeners();
      if (failure != null) {
        Error.throwWithStackTrace(
          safeFailure!,
          failureStack ?? StackTrace.current,
        );
      }
    } finally {
      if (identical(_signOutSettlement, settlement)) {
        _signOutSettlement = null;
        _signOutSettlementCompleter = null;
        _signOutOperationToken = null;
      }
      if (!settlementCompleter.isCompleted) {
        settlementCompleter.complete();
      }
    }
  }

  /// 대기 중인 가입 확인 이메일을 다시 보낸다.
  ///
  /// [email]을 생략하면 가장 최근 대기 결과의 이메일을 사용한다. UI가
  /// 인증 흐름 상태를 바꾸지 않고 다시 시도할 수 있도록 가입과 분리된
  /// 작업으로 제공한다.
  Future<void> resendSignupConfirmation([String? email]) async {
    await _awaitSignOutSettlement();
    await _awaitFencedIdentityRevocation();
    final target = (email ?? pendingConfirmationEmail)?.trim() ?? '';
    final operation = _beginAuthOperation(sessionChanging: false);
    final generation = _authOperationGeneration;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      await _auth.resendSignupConfirmation(target);
      if (_isCurrentAuthOperation(operation, generation)) {
        pendingConfirmationEmail = target;
      }
    } catch (error) {
      if (_isCurrentAuthOperation(operation, generation)) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      _finishAuthOperation(operation, generation);
      _finishSaving(operation);
    }
  }

  /// 확인 화면에서 사용하는 별칭이다.
  Future<void> resendConfirmationEmail([String? email]) =>
      resendSignupConfirmation(email);

  /// 비밀번호 복구 이메일을 보내고 확인 UI에 요청한 주소를 기록한다.
  /// 이 작업은 사용자를 인증하지 않는다.
  Future<void> requestPasswordReset(String email) async {
    await _awaitSignOutSettlement();
    await _awaitFencedIdentityRevocation();
    final target = email.trim();
    final operation = _beginAuthOperation(sessionChanging: false);
    final generation = _authOperationGeneration;
    _startSaving(operation);
    errorMessage = null;
    passwordResetRequestedEmail = null;
    notifyListeners();
    try {
      await _auth.requestPasswordReset(target);
      if (_isCurrentAuthOperation(operation, generation)) {
        passwordResetRequestedEmail = target;
      }
    } catch (error) {
      // 계정 없음 오류를 포함한 제공자 응답을 복구 UI에 노출하지 않는다.
      // 존재하는 주소와 알 수 없는 주소가 호출자에게 구분되지 않아야 한다.
      final safeError = target.isEmpty
          ? const AuthException('이메일을 입력해 주세요.')
          : const AuthException(passwordResetRequestErrorMessage);
      if (_isCurrentAuthOperation(operation, generation)) {
        errorMessage = safeError.message;
      }
      throw safeError;
    } finally {
      _finishAuthOperation(operation, generation);
      _finishSaving(operation);
    }
  }

  /// 저장소/Supabase 작업 이름에 맞춘 별칭이다.
  Future<void> resetPasswordForEmail(String email) =>
      requestPasswordReset(email);

  /// 짧은 작업 이름을 사용하는 비밀번호 복구 UI용 별칭이다.
  Future<void> sendPasswordReset(String email) => requestPasswordReset(email);

  /// 비밀번호 복구 딥링크를 처리한 뒤 새 비밀번호를 적용한다.
  Future<PlannerUser> updateRecoveredPassword(String password) async {
    if (password.length < 8) {
      const error = AuthException('8자 이상 입력해 주세요.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    await _awaitSignOutSettlement();
    await _awaitFencedIdentityRevocation();
    final operation = _beginAuthOperation(sessionChanging: true);
    final generation = _authOperationGeneration;
    final revision = _plannerRevision;
    final userId = user?.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await _auth.updateRecoveredPassword(password);
      if (!_isCurrentAuthOperation(operation, generation) ||
          !_isOperationCurrent(
            operation,
            userId: userId,
            plannerRevision: revision,
          )) {
        _revokeStaleAuthResultIfSignedOut();
        return updated;
      }
      _assertAuthResultSessionConsistency(updated);
      user = updated;
      authFlowState = AuthFlowState.signedIn;
      await loadGroups();
      return updated;
    } catch (error) {
      if (_isCurrentAuthOperation(operation, generation) &&
          _isOperationCurrent(
            operation,
            userId: userId,
            plannerRevision: revision,
          )) {
        errorMessage = _friendlyError(error);
        if (_staleSocialPendingMismatchObserved) {
          _failClosedForFencedIdentity();
        }
      }
      rethrow;
    } finally {
      _finishAuthOperation(operation, generation);
      _finishSaving(operation);
    }
  }

  /// 이 작업을 단순히 `updatePassword`라고 부르는 복구 화면용 별칭이다.
  Future<PlannerUser> updatePassword(String password) =>
      updateRecoveredPassword(password);

  Future<PlannerUser> changePassword(String password) =>
      updateRecoveredPassword(password);

  Future<PlannerUser> updateDisplayName(String displayName) async {
    final operation = _beginOperation();
    final revision = _plannerRevision;
    final userId = user?.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await _auth.updateDisplayName(displayName);
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        plannerRevision: revision,
      )) {
        return updated;
      }
      final updatedMembers = members
          .map(
            (member) => member.id == updated.id
                ? PlannerMember(
                    id: member.id,
                    name: updated.displayName ?? member.name,
                    email: member.email,
                    isOwner: member.isOwner,
                    isActive: member.isActive,
                    removedAt: member.removedAt,
                    avatarColor: member.avatarColor,
                  )
                : member,
          )
          .toList(growable: false);
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        plannerRevision: revision,
      )) {
        return updated;
      }
      user = updated;
      members = updatedMembers;
      return updated;
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      _finishSaving(operation);
    }
  }

  String _friendlySocialError(Object error) {
    final message = (error is AuthException ? error.message : error.toString())
        .toLowerCase();
    if (message.contains('cancel') ||
        message.contains('canceled') ||
        message.contains('취소')) {
      return socialAuthCancelledMessage;
    }
    if (message.contains('unsupported provider') ||
        message.contains('provider is disabled') ||
        message.contains('provider disabled') ||
        message.contains('provider not enabled') ||
        message.contains('not enabled') ||
        message.contains('provider configuration')) {
      return socialAuthProviderDisabledMessage;
    }
    if (error is AuthException &&
        (message == socialAuthBusyMessage.toLowerCase() ||
            message == socialAuthDemoMessage.toLowerCase() ||
            message == socialAuthLaunchFailedMessage.toLowerCase() ||
            message == socialAuthCancelledMessage.toLowerCase() ||
            message == socialAuthTimeoutMessage.toLowerCase())) {
      return error.message;
    }
    return socialAuthUnknownErrorMessage;
  }

  int _beginOperation() {
    _operationGeneration++;
    return ++_operationToken;
  }

  int _beginAuthOperation({required bool sessionChanging}) {
    // Auth requests use a generation separate from planner revisions. A
    // group refresh may advance [_operationToken] while the auth request is
    // still the owner of the auth spinner.
    final operation = _beginOperation();
    if (_signOutOperationToken != null && _signOutOperationToken != operation) {
      _signOutOperationToken = null;
      _signOutFailureMessage = null;
    }
    _authOperationGeneration++;
    _authOperationToken = operation;
    _authOperationInFlight = true;
    _authStateChangingOperationInFlight = sessionChanging;
    _queuedAuthIdentity = user?.id;
    if (sessionChanging && _staleSocialAuthFence) {
      // A new explicit password/recovery operation must own its eventual
      // result; do not let a prior timed-out callback match the old account
      // while this request is pending.
      _staleSocialExpectedIdentity = null;
      _staleSocialIdentityCommitted = false;
      _staleSocialPendingMismatchObserved = false;
    }
    return operation;
  }

  void _invalidateAuthOperations() {
    _authOperationGeneration++;
    _authOperationToken = 0;
    _authOperationInFlight = false;
    _authStateChangingOperationInFlight = false;
  }

  void _fenceStaleSocialAuth() {
    _staleSocialAuthFence = true;
    _staleSocialExpectedIdentity = null;
    _staleSocialIdentityCommitted = false;
    _staleSocialPendingMismatchObserved = false;
    _ignoreExternalIdentityEvents = true;
  }

  void _recordSocialAuthIdentity(String? identity) {
    if (!_staleSocialAuthFence || identity == null) return;
    _staleSocialExpectedIdentity ??= identity;
  }

  void _commitSocialAuthIdentity(String? identity) {
    if (!_staleSocialAuthFence || identity == null) return;
    // An explicit password/recovery result is a new owner.  It may replace
    // the identity recorded for an earlier timed-out social launch.
    _staleSocialExpectedIdentity = identity;
    _staleSocialIdentityCommitted = true;
    _staleSocialPendingMismatchObserved = false;
  }

  bool _isAllowedWhileSocialAuthFenced(
    AuthRepositoryEvent event,
    String? incomingId,
  ) {
    if (!_staleSocialAuthFence) return true;
    if (event.type != AuthEventType.signedIn &&
        event.type != AuthEventType.userUpdated) {
      return true;
    }
    // A direct password operation owns the result, not its provider event;
    // suppress callbacks until that operation returns a user. Email
    // confirmation is allowed once the pending address is known and matches.
    // Check this exception before the expected identity so a new sign-up can
    // intentionally establish a different account after an older login.
    final incomingEmail = event.user?.email.trim().toLowerCase();
    final pendingEmail = pendingConfirmationEmail?.trim().toLowerCase();
    if (pendingEmail != null &&
        pendingEmail.isNotEmpty &&
        incomingEmail == pendingEmail) {
      return true;
    }
    final expected = _staleSocialExpectedIdentity;
    if (expected != null) return incomingId == expected;
    final queuedRecovery = _queuedPasswordRecoveryIdentity;
    if (queuedRecovery != null && incomingId == queuedRecovery) return true;
    if (authFlowState == AuthFlowState.passwordRecovery &&
        _authOperationToken == 0) {
      return true;
    }
    return false;
  }

  void _failClosedForFencedIdentity({bool showError = true}) {
    if (_disposed || _fencedIdentityRevocationInFlight) return;
    _fencedIdentityRevocationInFlight = true;
    // Publish the gate before any synchronous notifications so a listener
    // that immediately retries auth cannot race the remote revoke.
    final completion = Completer<void>();
    final revocation = completion.future;
    _fencedIdentityRevocation = revocation;
    ++_authEventGeneration;
    _invalidateAuthOperations();
    _finishSocialAuth();
    _queuedAuthIdentity = null;
    _queuedPasswordRecoveryIdentity = null;
    _staleSocialExpectedIdentity = null;
    _staleSocialIdentityCommitted = false;
    _ignoreExternalIdentityEvents = true;
    // Clear private planner state synchronously before revoking the SDK
    // session. The revocation itself is best effort; either outcome remains
    // a signed-out, privacy-preserving controller state.
    unawaited(_clearPlannerData());
    authFlowState = AuthFlowState.signedOut;
    pendingConfirmationEmail = null;
    passwordResetRequestedEmail = null;
    errorMessage = showError ? authSessionErrorMessage : null;
    notifyListeners();
    unawaited(_revokeFencedIdentitySession(completion, revocation));
  }

  Future<void> _revokeFencedIdentitySession(
    Completer<void> completion,
    Future<void> revocation,
  ) async {
    try {
      await _auth.signOut();
    } catch (_) {
      if (!_disposed) {
        // Never expose provider/server details while preserving the safe
        // signed-out state established above.
        errorMessage = authSessionErrorMessage;
        notifyListeners();
      }
    } finally {
      _fencedIdentityRevocationInFlight = false;
      if (identical(_fencedIdentityRevocation, revocation)) {
        _fencedIdentityRevocation = null;
      }
      if (!completion.isCompleted) completion.complete();
    }
  }

  void _revokeStaleAuthResultIfSignedOut() {
    if (_disposed ||
        _authOperationInFlight ||
        authFlowState != AuthFlowState.signedOut ||
        user != null ||
        _auth.currentUser == null) {
      return;
    }
    // A stale password request can still establish a Supabase session after
    // sign-out. Treat that late completion like an unexpected identity event
    // and revoke it without exposing a provider error.
    _failClosedForFencedIdentity(showError: false);
  }

  Future<void> _awaitFencedIdentityRevocation() async {
    final pending = _fencedIdentityRevocation;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      // Revocation failures are already represented by the safe session error
      // above. Auth operations may retry only after the attempt settles.
    }
  }

  Future<void> _awaitSignOutSettlement() async {
    final pending = _signOutSettlement;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      // The explicit sign-out caller surfaces its own safe error. Waiting auth
      // operations may proceed only after the revoke attempt has settled.
    }
  }

  bool _isCurrentAuthOperation(int operation, int generation) {
    return !_disposed &&
        _authOperationToken == operation &&
        _authOperationGeneration == generation;
  }

  void _finishAuthOperation(int operation, int generation) {
    if (!_isCurrentAuthOperation(operation, generation)) return;
    _authOperationToken = 0;
    _authOperationInFlight = false;
    _authStateChangingOperationInFlight = false;
  }

  Future<void> _commitAuthenticatedUser(
    PlannerUser authenticated,
    int operation,
    int generation,
  ) async {
    if (!_isCurrentAuthOperation(operation, generation)) return;
    _assertAuthResultSessionConsistency(authenticated);
    final previousId = user?.id;
    if (previousId != null && previousId != authenticated.id) {
      _clearPendingInvite();
    }
    if (previousId != authenticated.id ||
        groups.isNotEmpty ||
        _hasGroupScopedData) {
      await _clearPlannerData(invalidateOperation: false, clearSaving: false);
      if (!_isCurrentAuthOperation(operation, generation)) return;
    }
    user = authenticated;
    _bindPendingInviteToUser(authenticated.id);
    if (_staleSocialAuthFence) {
      _commitSocialAuthIdentity(authenticated.id);
    } else {
      _ignoreExternalIdentityEvents = false;
    }
    _queuedAuthIdentity = authenticated.id;
    authFlowState = AuthFlowState.signedIn;
    pendingConfirmationEmail = null;
    errorMessage = null;
    await loadGroups();
  }

  void _assertAuthResultSessionConsistency(PlannerUser authenticated) {
    if (!_staleSocialPendingMismatchObserved) return;
    final sdkUser = _auth.currentUser;
    if (sdkUser != null && sdkUser.id != authenticated.id) {
      // A provider callback changed the SDK session while this explicit auth
      // operation was pending. Without callback request IDs, accepting either
      // account would leave the controller and Supabase on different JWTs;
      // revoke both and fail closed instead.
      _failClosedForFencedIdentity();
      throw const AuthException(authSessionErrorMessage);
    }
  }

  bool _isOperationCurrent(
    int operation, {
    required String? userId,
    String? groupId,
    int? plannerRevision,
  }) {
    if (_disposed || _operationToken != operation) return false;
    if (plannerRevision != null && _plannerRevision != plannerRevision) {
      return false;
    }
    if (user?.id != userId) return false;
    if (groupId != null && selectedGroup?.id != groupId) return false;
    return true;
  }

  void _startSaving(int operation) {
    _savingOperationToken = operation;
    isSaving = true;
  }

  void _finishSaving(int operation) {
    if (_savingOperationToken != operation) return;
    _savingOperationToken = 0;
    isSaving = false;
    notifyListeners();
  }

  bool _isCurrentSocialAuth(int operation, int generation) {
    return !_disposed &&
        _socialAuthProviderInFlight != null &&
        _socialAuthOperationToken == operation &&
        _socialAuthGeneration == generation;
  }

  void _finishSocialAuth([int? operation, int? generation]) {
    final active =
        _socialAuthProviderInFlight != null ||
        _socialAuthOperationToken != 0 ||
        _oauthTimeoutTimer != null;
    if (!active) return;
    if (operation != null && _socialAuthOperationToken != operation) return;
    if (generation != null && _socialAuthGeneration != generation) return;
    _oauthTimeoutTimer?.cancel();
    _oauthTimeoutTimer = null;
    final owner = _socialAuthOperationToken;
    _socialAuthOperationToken = 0;
    _socialAuthProviderInFlight = null;
    ++_socialAuthGeneration;
    if (owner != 0 && _savingOperationToken == owner) {
      _savingOperationToken = 0;
      isSaving = false;
      notifyListeners();
    }
  }

  bool _isCurrentAuthEvent(int generation, int authGeneration) {
    return !_disposed &&
        generation == _authEventGeneration &&
        authGeneration == _authOperationGeneration;
  }

  void _enqueueAuthEvent(AuthRepositoryEvent event) {
    if (event.type == AuthEventType.signedOut) {
      // Supabase may emit an initial ambient SIGNED_OUT event while a user is
      // opening an invite in a logged-out tab.  Preserve that pending intent;
      // only an explicit sign-out/known committed identity is a privacy fence.
      if (user != null || _signOutOperationToken != null) {
        _clearPendingInvite();
      }
      // Signed-out is a synchronous fence even when no identity is currently
      // visible. Forget any identity previously committed behind a social
      // tombstone before a delayed callback can be inspected.
      _staleSocialAuthFence = true;
      _staleSocialExpectedIdentity = null;
      _queuedPasswordRecoveryIdentity = null;
      if (_signOutOperationToken == null) {
        _signOutFailureMessage = null;
      }
    } else if (event.type == AuthEventType.passwordRecovery) {
      _queuedPasswordRecoveryIdentity = event.user?.id ?? _auth.currentUser?.id;
    }
    final incomingId = event.type == AuthEventType.signedOut
        ? null
        : event.user?.id ?? _auth.currentUser?.id;
    if (!_isAllowedWhileSocialAuthFenced(event, incomingId)) {
      // Without callback request IDs, preserving the already committed
      // identity is safer while a newer explicit password operation is still
      // pending. Once no operation owns the session, fail closed instead of
      // leaving the SDK and controller on different accounts.
      final pendingExplicitOperation =
          _authOperationInFlight &&
          _authStateChangingOperationInFlight &&
          !_staleSocialIdentityCommitted;
      if (pendingExplicitOperation) {
        _staleSocialPendingMismatchObserved = true;
      }
      if (!pendingExplicitOperation && _socialAuthProviderInFlight == null) {
        _failClosedForFencedIdentity();
      }
      return;
    }
    if ((event.type == AuthEventType.signedIn ||
            event.type == AuthEventType.userUpdated) &&
        _ignoreExternalIdentityEvents &&
        _socialAuthProviderInFlight == null &&
        !_staleSocialAuthFence) {
      // An auth event can be delivered after an explicit sign-out because a
      // provider callback was already queued. Revoke the SDK session as well
      // as clearing planner state; keeping only a signed-out UI would leave
      // the SDK on a different account.
      _failClosedForFencedIdentity();
      return;
    }
    final expectedId = _queuedAuthIdentity ?? user?.id;
    // SIGNED_OUT is a fence even when the controller already has no user:
    // an in-flight password request may still complete with a user later.
    final identityChanged = event.type == AuthEventType.signedOut
        ? true
        : incomingId != null && incomingId != expectedId;
    if (identityChanged) {
      final preserveSignOutOperation =
          event.type == AuthEventType.signedOut &&
          _signOutOperationToken == _operationToken;
      // A switch from one known identity to another is a synchronous privacy
      // boundary.  Clear the bearer intent before the queued planner clear so
      // a caller cannot observe the old token while the auth event is waiting
      // behind an older operation.  The first signed-in event after a logged-
      // out capture intentionally keeps the intent and binds it in the queued
      // handler below; ambient SIGNED_OUT events likewise preserve it.
      if (event.type != AuthEventType.signedOut &&
          (user != null || _queuedAuthIdentity != null)) {
        _clearPendingInvite();
      }
      _queuedAuthIdentity = incomingId;
      ++_authEventGeneration;
      if (event.type == AuthEventType.signedOut) {
        _ignoreExternalIdentityEvents = true;
      }
      // A signed-out/new-identity event supersedes a pending auth request.
      // Preserve an explicit sign-in operation's spinner long enough for its
      // own completion; the operation generation remains independent of the
      // planner revision changed by the privacy clear.
      if (event.type == AuthEventType.signedOut ||
          !_authStateChangingOperationInFlight) {
        _invalidateAuthOperations();
      }
      final preserveSaving =
          _authOperationToken != 0 || _socialAuthProviderInFlight != null;
      // Invalidate and clear before the queued handler waits on an older
      // auth event or group request.
      unawaited(
        _clearPlannerData(
          invalidateOperation: !preserveSignOutOperation,
          clearSaving: !preserveSaving ? true : false,
        ),
      );
    }
    if (event.type == AuthEventType.signedIn ||
        event.type == AuthEventType.signedOut ||
        event.type == AuthEventType.passwordRecovery) {
      _finishSocialAuth();
    }
    final eventGeneration = _authEventGeneration;
    final authGeneration = _authOperationGeneration;

    final next = _authEventQueue.then<void>((_) async {
      if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
      await _handleAuthEvent(event, eventGeneration, authGeneration);
    });
    _authEventQueue = next.catchError((Object error, StackTrace stackTrace) {
      if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
      errorMessage = _friendlyError(error);
      notifyListeners();
    });
  }

  Future<void> _handleAuthEvent(
    AuthRepositoryEvent event,
    int eventGeneration,
    int authGeneration,
  ) async {
    if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
    lastAuthEvent = event.type;
    final previousId = user?.id;
    switch (event.type) {
      case AuthEventType.signedIn:
        final incoming = event.user ?? _auth.currentUser;
        if (incoming == null) break;
        if (previousId != null && previousId != incoming.id) {
          _clearPendingInvite();
        } else if (previousId == null) {
          _bindPendingInviteToUser(incoming.id);
        }
        if (previousId != incoming.id) {
          await _clearPlannerData(
            clearSaving:
                _authOperationToken == 0 && _socialAuthProviderInFlight == null,
          );
          if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
        }
        if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
        user = incoming;
        _bindPendingInviteToUser(incoming.id);
        if (_staleSocialAuthFence) {
          _recordSocialAuthIdentity(incoming.id);
          if (!_authOperationInFlight) {
            _staleSocialIdentityCommitted = true;
          }
        } else {
          _ignoreExternalIdentityEvents = false;
        }
        _queuedAuthIdentity = incoming.id;
        authFlowState = AuthFlowState.signedIn;
        pendingConfirmationEmail = null;
        errorMessage = null;
        // 명시적인 로그인/가입 작업은 자체적으로 일정방을 불러온다. 하지만
        // 다른 탭이나 딥링크에서 발생한 이벤트는 여기서 새로 인증된 사용자의
        // 일정방을 초기화해야 한다.
        if (!_authStateChangingOperationInFlight && previousId != incoming.id) {
          unawaited(loadGroups());
          return;
        }
        break;
      case AuthEventType.signedOut:
        _staleSocialAuthFence = true;
        _staleSocialExpectedIdentity = null;
        _queuedPasswordRecoveryIdentity = null;
        _staleSocialIdentityCommitted = false;
        _staleSocialPendingMismatchObserved = false;
        final preserveSignOutOperation =
            _signOutOperationToken == _operationToken;
        await _clearPlannerData(invalidateOperation: !preserveSignOutOperation);
        if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
        _queuedAuthIdentity = null;
        authFlowState = AuthFlowState.signedOut;
        pendingConfirmationEmail = null;
        passwordResetRequestedEmail = null;
        errorMessage = _signOutFailureMessage;
        break;
      case AuthEventType.userUpdated:
        final incoming = event.user ?? _auth.currentUser;
        if (incoming != null) {
          if (previousId != null && previousId != incoming.id) {
            _clearPendingInvite();
          } else if (previousId == null) {
            _bindPendingInviteToUser(incoming.id);
          }
          if (previousId != incoming.id) {
            await _clearPlannerData(
              clearSaving:
                  _authOperationToken == 0 &&
                  _socialAuthProviderInFlight == null,
            );
            if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) {
              return;
            }
          }
          if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
          user = incoming;
          _bindPendingInviteToUser(incoming.id);
          if (_staleSocialAuthFence) {
            _recordSocialAuthIdentity(incoming.id);
            if (!_authOperationInFlight) {
              _staleSocialIdentityCommitted = true;
            }
          } else {
            _ignoreExternalIdentityEvents = false;
          }
          _queuedAuthIdentity = incoming.id;
          if (previousId != incoming.id &&
              !_authStateChangingOperationInFlight &&
              authFlowState != AuthFlowState.passwordRecovery) {
            unawaited(loadGroups());
          }
        }
        if (user != null && authFlowState != AuthFlowState.passwordRecovery) {
          authFlowState = AuthFlowState.signedIn;
        }
        break;
      case AuthEventType.passwordRecovery:
        final incoming = event.user ?? _auth.currentUser;
        if (incoming != null) {
          if (previousId != null && previousId != incoming.id) {
            _clearPendingInvite();
          } else if (previousId == null) {
            _bindPendingInviteToUser(incoming.id);
          }
          if (previousId != incoming.id) {
            await _clearPlannerData(
              clearSaving:
                  _authOperationToken == 0 &&
                  _socialAuthProviderInFlight == null,
            );
            if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) {
              return;
            }
          }
          if (!_isCurrentAuthEvent(eventGeneration, authGeneration)) return;
          user = incoming;
          _bindPendingInviteToUser(incoming.id);
          _commitSocialAuthIdentity(incoming.id);
          _queuedAuthIdentity = incoming.id;
        }
        authFlowState = AuthFlowState.passwordRecovery;
        errorMessage = null;
        break;
    }
    notifyListeners();
  }

  Future<void> _clearPlannerData({
    bool invalidateOperation = true,
    bool clearSaving = true,
  }) async {
    // A full identity/privacy clear starts a new planner session even when a
    // test double happens to sign back in as the same user id.  Terminal
    // group mutations capture this generation and must not alter a newer
    // session when their old network Future finally settles.
    _plannerSessionGeneration++;
    _plannerRevision++;
    if (invalidateOperation) {
      _operationToken++;
      _operationGeneration++;
    }
    if (clearSaving) _savingOperationToken = 0;
    _inviteOperation++;
    _groupOperationToken = 0;
    _cancelGroupMetadataRefresh();
    _terminalGroupOperations.clear();
    _terminalGroupTombstones.clear();
    _inviteCodeInFlight = false;
    user = null;
    groups = const <PlannerGroup>[];
    selectedGroup = null;
    _resetRangeState();
    selectedEventRange = null;
    events = const <PlannerEvent>[];
    members = const <PlannerMember>[];
    invites = const <InviteCode>[];
    isOffline = false;
    selectedMemberId = null;
    showAllMembers = true;
    isLoading = false;
    if (clearSaving) isSaving = false;
    // Identity changes are privacy-sensitive. Notify before awaiting stream
    // cancellation so old planner widgets disappear synchronously.
    notifyListeners();
    final subscription = _eventSubscription;
    _eventSubscription = null;
    final invalidationSubscription = _eventInvalidationSubscription;
    _eventInvalidationSubscription = null;
    final lifecycleSubscription = _groupLifecycleSubscription;
    _groupLifecycleSubscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // Clearing private state is more important than a failing stream
      // cancellation. The stream callback is still guarded by the revision.
    }
    try {
      await invalidationSubscription?.cancel();
    } catch (_) {
      // Invalidation cancellation is best effort during a privacy clear.
    }
    try {
      await lifecycleSubscription?.cancel();
    } catch (_) {
      // Lifecycle cancellation is best effort during a privacy clear.
    }
  }

  bool get _hasGroupScopedData {
    return selectedGroup != null ||
        members.isNotEmpty ||
        invites.isNotEmpty ||
        events.isNotEmpty ||
        _eventSubscription != null ||
        _eventInvalidationSubscription != null ||
        _groupLifecycleSubscription != null;
  }

  Future<void> _clearGroupScopedData() async {
    _inviteOperation++;
    _inviteCodeInFlight = false;
    _cancelGroupMetadataRefresh();
    _resetRangeState();
    selectedGroup = null;
    members = const <PlannerMember>[];
    invites = const <InviteCode>[];
    events = const <PlannerEvent>[];
    selectedMemberId = null;
    showAllMembers = true;
    isOffline = false;
    final subscription = _eventSubscription;
    _eventSubscription = null;
    final invalidationSubscription = _eventInvalidationSubscription;
    _eventInvalidationSubscription = null;
    final lifecycleSubscription = _groupLifecycleSubscription;
    _groupLifecycleSubscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // A stale subscription cannot keep private data alive. Its callbacks
      // are guarded by the operation revision.
    }
    try {
      await invalidationSubscription?.cancel();
    } catch (_) {
      // Invalidation cancellation is best effort during a group clear.
    }
    try {
      await lifecycleSubscription?.cancel();
    } catch (_) {
      // A lifecycle stream cannot block selected-group invalidation.
    }
  }

  /// Atomically removes [groupId] from the visible list and invalidates every
  /// selected-group callback before waiting for stream cancellation. The
  /// returned Future only represents best-effort subscription cleanup; callers
  /// must not restore the removed group when a subsequent reload fails.
  Future<void> _invalidateGroupScopedData({String? removeGroupId}) {
    // A stale leave/archive completion can arrive after the user has already
    // switched to another group.  Remove the terminal row from the list but
    // do not wipe the new group's selection/cache in that case.  A selected
    // group (or a no-id privacy clear) still takes the full invalidation path.
    final clearSelected =
        removeGroupId == null || selectedGroup?.id == removeGroupId;
    if (removeGroupId != null) {
      _terminalGroupTombstones.add(removeGroupId);
      groups = List<PlannerGroup>.unmodifiable(
        groups.where((group) => group.id != removeGroupId),
      );
    }
    if (!clearSelected) {
      notifyListeners();
      return Future<void>.value();
    }
    _plannerRevision++;
    _operationToken++;
    _operationGeneration++;
    _inviteOperation++;
    _inviteCodeInFlight = false;
    _cancelGroupMetadataRefresh();
    _resetRangeState();
    selectedGroup = null;
    members = const <PlannerMember>[];
    invites = const <InviteCode>[];
    events = const <PlannerEvent>[];
    selectedMemberId = null;
    showAllMembers = true;
    isOffline = false;
    final eventSubscription = _eventSubscription;
    _eventSubscription = null;
    final invalidationSubscription = _eventInvalidationSubscription;
    _eventInvalidationSubscription = null;
    final lifecycleSubscription = _groupLifecycleSubscription;
    _groupLifecycleSubscription = null;
    notifyListeners();
    return Future.wait<void>(<Future<void>>[
      if (eventSubscription != null) eventSubscription.cancel(),
      if (invalidationSubscription != null) invalidationSubscription.cancel(),
      if (lifecycleSubscription != null) lifecycleSubscription.cancel(),
    ]).then<void>((_) {}, onError: (Object error, StackTrace stack) {});
  }

  bool _isCurrentPlannerContext(
    int operation, {
    required String? userId,
    String? selectedGroupId,
    String? groupId,
  }) {
    if (_disposed || _plannerRevision != operation) return false;
    if (user?.id != userId) return false;
    if (selectedGroupId != null && selectedGroup?.id != selectedGroupId) {
      return false;
    }
    if (selectedGroupId == null && selectedGroup != null && groupId == null) {
      return false;
    }
    if (groupId != null && selectedGroup?.id != groupId) return false;
    return true;
  }

  Stream<List<PlannerEvent>> _watchEventsForUser(
    String userId,
    String groupId,
  ) {
    final capability = _repository;
    if (capability is UserScopedEventReadCapability) {
      return (capability as UserScopedEventReadCapability).watchEventsForUser(
        userId,
        groupId,
      );
    }
    // Legacy fakes predate requester-scoped streams. Keep their unscoped read
    // path available only in non-release test/dev builds; production adapters
    // implement UserScopedEventReadCapability and never reach this fallback.
    if (!kReleaseMode) return _repository.watchEvents(groupId);
    return Stream<List<PlannerEvent>>.error(
      const ScheduleCapabilityException('사용자 범위 일정 스트림을 지원하지 않는 저장소입니다.'),
    );
  }

  Future<void> _handleGroupLifecycleUpdate({
    required int operation,
    required String userId,
    required String groupId,
    required PlannerGroup? incoming,
  }) async {
    if (!_isCurrentPlannerContext(
      operation,
      userId: userId,
      groupId: groupId,
    )) {
      return;
    }
    // Repository lifecycle reads are requester/group scoped, but keep the
    // controller closed against a malformed adapter response as well. A
    // cross-group row must never replace the currently selected group.
    if (incoming != null && incoming.id != groupId) return;
    if (incoming == null || incoming.isArchived) {
      // Do not await before clearing state: a remote archive/null event must
      // immediately hide the group's private data and invalidate callbacks.
      final clear = _invalidateGroupScopedData(removeGroupId: groupId);
      await clear;
      return;
    }
    final timezoneChanged = selectedGroup?.timezone != incoming.timezone;
    _replaceGroup(incoming);
    if (timezoneChanged &&
        selectedEventRange != null &&
        _usesBoundedEventRangeReads) {
      _beginSelectedRange(fetch: true);
    }
    // A lifecycle update can also carry an owner/version change (for example
    // after a remote transfer).  Refresh the member and invite projections so
    // edit/transfer affordances do not keep stale roles while preserving the
    // just-updated group object immediately above.
    _scheduleGroupScopedMetadataRefresh(
      operation: operation,
      userId: userId,
      groupId: groupId,
    );
  }

  /// Debounces bursts of membership/group lifecycle notifications into one
  /// complete member/invite projection read.  A second signal that arrives
  /// while the read is in flight is retained and retried after that read, so
  /// an older response cannot become the final roster snapshot.
  void _scheduleGroupScopedMetadataRefresh({
    required int operation,
    required String userId,
    required String groupId,
  }) {
    if (!_isCurrentPlannerContext(
      operation,
      userId: userId,
      groupId: groupId,
    )) {
      return;
    }
    _pendingGroupMetadataRefresh = _GroupMetadataRefreshRequest(
      operation: operation,
      userId: userId,
      groupId: groupId,
    );
    _armGroupMetadataRefreshTimer();
  }

  void _armGroupMetadataRefreshTimer({
    Duration delay = const Duration(milliseconds: 80),
  }) {
    _groupMetadataRefreshTimer?.cancel();
    final token = ++_groupMetadataRefreshToken;
    _groupMetadataRefreshTimer = Timer(delay, () {
      _groupMetadataRefreshTimer = null;
      if (_disposed || token != _groupMetadataRefreshToken) return;
      if (_groupMetadataRefreshInFlight) {
        // The in-flight read's finally block re-arms the timer for the latest
        // pending request. Keep that request intact until then.
        return;
      }
      final request = _pendingGroupMetadataRefresh;
      _pendingGroupMetadataRefresh = null;
      if (request == null) return;
      unawaited(_runGroupScopedMetadataRefresh(request));
    });
  }

  Future<void> _runGroupScopedMetadataRefresh(
    _GroupMetadataRefreshRequest request,
  ) async {
    if (_groupMetadataRefreshInFlight) {
      _pendingGroupMetadataRefresh = request;
      return;
    }
    if (!_isCurrentPlannerContext(
      request.operation,
      userId: request.userId,
      groupId: request.groupId,
    )) {
      return;
    }
    _groupMetadataRefreshInFlight = true;
    try {
      await _refreshGroupScopedMetadata(
        operation: request.operation,
        userId: request.userId,
        groupId: request.groupId,
      );
    } finally {
      _groupMetadataRefreshInFlight = false;
      if (_pendingGroupMetadataRefresh != null && !_disposed) {
        // A signal may have arrived while membersForGroup/inviteCodesForGroup
        // was pending. Re-arm without losing the newest operation context.
        _armGroupMetadataRefreshTimer();
      }
    }
  }

  void _cancelGroupMetadataRefresh() {
    _groupMetadataRefreshTimer?.cancel();
    _groupMetadataRefreshTimer = null;
    _pendingGroupMetadataRefresh = null;
    ++_groupMetadataRefreshToken;
  }

  Future<void> _refreshGroupScopedMetadata({
    required int operation,
    required String userId,
    required String groupId,
  }) async {
    List<PlannerMember>? nextMembers;
    List<InviteCode>? nextInvites;
    try {
      nextMembers = await _repository.membersForGroup(groupId);
    } catch (_) {
      // Realtime group metadata remains usable even if an auxiliary profile
      // projection is temporarily unavailable.
    }
    if (!_isCurrentPlannerContext(
      operation,
      userId: userId,
      groupId: groupId,
    )) {
      return;
    }
    try {
      nextInvites = await _repository.inviteCodesForGroup(groupId);
    } catch (_) {
      // Invite rows are owner-scoped and may legitimately be unavailable to a
      // member; retain the last visible value in that case.
    }
    if (!_isCurrentPlannerContext(
      operation,
      userId: userId,
      groupId: groupId,
    )) {
      return;
    }
    if (nextMembers != null) {
      _setMembersSnapshot(nextMembers);
    }
    if (nextInvites != null) {
      invites = List<InviteCode>.unmodifiable(nextInvites);
    }
    notifyListeners();
  }

  Future<void> loadGroups({bool preserveOperationGeneration = false}) async {
    final current = user;
    if (current == null) return;
    if (!preserveOperationGeneration) _operationGeneration++;
    final operationGeneration = _operationGeneration;
    _operationToken++;
    final operation = ++_plannerRevision;
    final selectedGroupId = selectedGroup?.id;
    isLoading = true;
    // A conflict-owned refresh must not erase a newer operation's diagnostic
    // while its network read is pending.  The caller will restore the
    // original conflict message only when this generation still owns the
    // context after the refresh completes.
    if (!preserveOperationGeneration) errorMessage = null;
    notifyListeners();
    try {
      // Stage the response until the user and selection that initiated this
      // request are still current. A sign-out or a newer refresh must win.
      final fetchedGroups = (await _repository.groupsForUser(current.id))
          .where((group) => !_terminalGroupTombstones.contains(group.id))
          .toList(growable: false);
      if (!_isCurrentPlannerContext(
        operation,
        userId: current.id,
        selectedGroupId: selectedGroupId,
      )) {
        return;
      }
      groups = List<PlannerGroup>.unmodifiable(fetchedGroups);
      isOffline = false;

      if (selectedGroupId != null) {
        final refreshedSelection = fetchedGroups
            .where((group) => group.id == selectedGroupId)
            .firstOrNull;
        if (refreshedSelection == null) {
          // Membership was removed (or the group was deleted). Do not leave
          // the old selection or its events/members reachable.
          _terminalGroupTombstones.add(selectedGroupId);
          await _clearGroupScopedData();
          if (_plannerRevision == operation && user?.id == current.id) {
            isLoading = false;
            notifyListeners();
          }
          return;
        }
        await selectGroup(
          refreshedSelection.id,
          preserveOperationGeneration: preserveOperationGeneration,
          preservedOperationGeneration: operationGeneration,
        );
      } else if (_hasGroupScopedData) {
        // This is defensive for callers that cleared selectedGroup directly;
        // a refresh with no selection must not retain an orphaned cache.
        await _clearGroupScopedData();
      }
    } catch (error) {
      if (_isCurrentPlannerContext(
            operation,
            userId: current.id,
            selectedGroupId: selectedGroupId,
          ) &&
          (!preserveOperationGeneration ||
              _operationGeneration == operationGeneration)) {
        isOffline = true;
        errorMessage = _friendlyError(error);
      }
    } finally {
      if (_isCurrentPlannerContext(
        operation,
        userId: current.id,
        selectedGroupId: selectedGroupId,
      )) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> selectGroup(
    String groupId, {
    bool preserveOperationGeneration = false,
    int? preservedOperationGeneration,
  }) async {
    if (_terminalGroupOperations.contains(groupId)) {
      // A leave/archive completion has already invalidated this group. Ignore
      // stale taps and late list callbacks until the terminal operation ends.
      return;
    }
    final group = groups
        .where((candidate) => candidate.id == groupId)
        .firstOrNull;
    // A terminal mutation or a remote archive may remove the row between a
    // list tap and this callback.  Treat that stale selection as a no-op
    // instead of throwing from `firstWhere` and reviving cached data.
    if (group == null) return;
    final userId = user?.id;
    if (userId == null) return;
    if (!preserveOperationGeneration) _operationGeneration++;
    final selectionGeneration = preserveOperationGeneration
        ? (preservedOperationGeneration ?? _operationGeneration)
        : _operationGeneration;
    _operationToken++;
    final operation = ++_plannerRevision;
    _inviteOperation++;
    _inviteCodeInFlight = false;
    _cancelGroupMetadataRefresh();
    final previousSubscription = _eventSubscription;
    _eventSubscription = null;
    final previousInvalidationSubscription = _eventInvalidationSubscription;
    _eventInvalidationSubscription = null;
    final previousLifecycleSubscription = _groupLifecycleSubscription;
    _groupLifecycleSubscription = null;
    _resetRangeState();
    selectedGroup = group;
    final groupNow = utcToWallTime(DateTime.now().toUtc(), group.timezone);
    selectedDay = dateOnly(groupNow);
    selectedEventRange = _usesBoundedEventRangeReads
        ? _rangeForCalendarSelection(group: group)
        : null;
    if (selectedEventRange != null) {
      _rangeKey = _rangeIdentity(
        selectedEventRange!,
        showAllMembers ? null : selectedMemberId,
      );
      isLoadingEvents = _usesBoundedEventRangeReads;
    }
    selectedMemberId = null;
    showAllMembers = true;
    members = const <PlannerMember>[];
    invites = const <InviteCode>[];
    events = const <PlannerEvent>[];
    isLoading = true;
    if (!preserveOperationGeneration) errorMessage = null;
    notifyListeners();
    try {
      try {
        await previousSubscription?.cancel();
      } catch (_) {
        // A cancelled stream cannot be allowed to block the new selection.
      }
      try {
        await previousInvalidationSubscription?.cancel();
      } catch (_) {
        // A stale invalidation stream cannot block the new selection.
      }
      try {
        await previousLifecycleSubscription?.cancel();
      } catch (_) {
        // A stale lifecycle stream cannot block the new selection.
      }
      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        return;
      }

      // Event and lifecycle streams are privacy/availability-critical. Start
      // both before the auxiliary member/invite reads below: those reads may
      // be slow or remain pending while a remote archive/deactivation still
      // needs to clear the selected group immediately.
      StreamSubscription<List<PlannerEvent>>? nextSubscription;
      StreamSubscription<void>? nextInvalidationSubscription;
      StreamSubscription<PlannerGroup?>? nextLifecycleSubscription;
      var streamFailed = false;
      String? metadataError;

      Future<void> cancelPendingSubscriptions() async {
        final eventSubscription = nextSubscription;
        final invalidationSubscription = nextInvalidationSubscription;
        final lifecycleSubscription = nextLifecycleSubscription;
        nextSubscription = null;
        nextInvalidationSubscription = null;
        nextLifecycleSubscription = null;
        if (identical(_eventSubscription, eventSubscription)) {
          _eventSubscription = null;
        }
        if (identical(_groupLifecycleSubscription, lifecycleSubscription)) {
          _groupLifecycleSubscription = null;
        }
        if (identical(
          _eventInvalidationSubscription,
          invalidationSubscription,
        )) {
          _eventInvalidationSubscription = null;
        }
        for (final subscription in <StreamSubscription<dynamic>>[
          ?eventSubscription,
          ?invalidationSubscription,
          ?lifecycleSubscription,
        ]) {
          try {
            await subscription.cancel();
          } catch (_) {
            // A stale stream cannot block a newer selection or a privacy
            // clear. Its callbacks remain guarded by the operation context.
          }
        }
      }

      final rangeCapability = _repository;
      if (_usesBoundedEventRangeReads &&
          rangeCapability is BoundedEventRangeReadCapability) {
        try {
          final capability = rangeCapability as BoundedEventRangeReadCapability;
          final invalidationStream = capability.watchEventInvalidations(
            userId,
            group.id,
          );
          final subscription = invalidationStream.listen(
            (_) => _scheduleRangeInvalidation(
              operation: operation,
              userId: userId,
              groupId: group.id,
            ),
            onError: (Object error) {
              if (!_isCurrentPlannerContext(
                operation,
                userId: userId,
                groupId: group.id,
              )) {
                return;
              }
              streamFailed = true;
              errorMessage = _friendlyError(error);
              notifyListeners();
            },
          );
          nextInvalidationSubscription = subscription;
          if (!_isCurrentPlannerContext(
            operation,
            userId: userId,
            groupId: group.id,
          )) {
            await cancelPendingSubscriptions();
            return;
          }
          _eventInvalidationSubscription = subscription;
        } catch (error) {
          streamFailed = true;
          metadataError = _friendlyError(error);
        }
      } else {
        try {
          final stream = _watchEventsForUser(userId, group.id);
          final subscription = stream.listen(
            (incoming) {
              if (!_isCurrentPlannerContext(
                operation,
                userId: userId,
                groupId: group.id,
              )) {
                return;
              }
              events = List<PlannerEvent>.unmodifiable(incoming);
              isOffline = false;
              notifyListeners();
            },
            onError: (Object error) {
              if (!_isCurrentPlannerContext(
                operation,
                userId: userId,
                groupId: group.id,
              )) {
                return;
              }
              isOffline = true;
              errorMessage = _friendlyError(error);
              notifyListeners();
            },
          );
          nextSubscription = subscription;
          if (!_isCurrentPlannerContext(
            operation,
            userId: userId,
            groupId: group.id,
          )) {
            await cancelPendingSubscriptions();
            return;
          }
          // Publish the subscription before awaiting metadata so a lifecycle
          // tombstone can cancel it even while either REST read is pending.
          _eventSubscription = subscription;
        } catch (error) {
          streamFailed = true;
          metadataError = _friendlyError(error);
        }
      }

      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        await cancelPendingSubscriptions();
        return;
      }

      if (_repository is GroupLifecycleCapability) {
        try {
          final lifecycleStream = (_repository as GroupLifecycleCapability)
              .watchGroupLifecycle(userId, group.id);
          final subscription = lifecycleStream.listen(
            (incoming) {
              unawaited(
                _handleGroupLifecycleUpdate(
                  operation: operation,
                  userId: userId,
                  groupId: group.id,
                  incoming: incoming,
                ),
              );
            },
            onError: (Object error) {
              if (!_isCurrentPlannerContext(
                operation,
                userId: userId,
                groupId: group.id,
              )) {
                return;
              }
              errorMessage = _friendlyError(error);
              notifyListeners();
            },
          );
          nextLifecycleSubscription = subscription;
          if (!_isCurrentPlannerContext(
            operation,
            userId: userId,
            groupId: group.id,
          )) {
            await cancelPendingSubscriptions();
            return;
          }
          // As with events, publish this before the metadata reads. If the
          // listener synchronously reports a tombstone, the context check
          // below prevents a stale subscription from being retained.
          _groupLifecycleSubscription = subscription;
        } catch (error) {
          metadataError ??= _friendlyError(error);
        }
      }

      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        await cancelPendingSubscriptions();
        return;
      }

      List<PlannerMember> fetchedMembers = const <PlannerMember>[];
      List<InviteCode> fetchedInvites = const <InviteCode>[];
      try {
        fetchedMembers = await _repository.membersForGroup(group.id);
      } catch (error) {
        // 프로필/멤버십 조회 실패가 일정 스트림 시작을 막아서는 안 된다.
        // 실패는 표시하되 일정 데이터를 불러올 수 있다면 일정을 오프라인으로
        // 표시하지 않는다.
        metadataError ??= _friendlyError(error);
      }
      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        await cancelPendingSubscriptions();
        return;
      }
      try {
        fetchedInvites = await _repository.inviteCodesForGroup(group.id);
      } catch (_) {
        // 초대 메타데이터는 소유자 전용이지만 일정 접근은 계속 가능하다.
        fetchedInvites = const <InviteCode>[];
      }
      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        await cancelPendingSubscriptions();
        return;
      }

      _setMembersSnapshot(fetchedMembers);
      invites = List<InviteCode>.unmodifiable(fetchedInvites);
      if (_usesBoundedEventRangeReads &&
          rangeCapability is BoundedEventRangeReadCapability) {
        await _fetchRangeFirstPage(
          force: true,
          preserveCurrentEvents: false,
          advanceGeneration: false,
        );
        if (!_isCurrentPlannerContext(
          operation,
          userId: userId,
          groupId: group.id,
        )) {
          await cancelPendingSubscriptions();
          return;
        }
      }
      if (!preserveOperationGeneration ||
          _operationGeneration == selectionGeneration) {
        errorMessage = metadataError;
        isOffline = streamFailed || rangeError != null;
      }
      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        await cancelPendingSubscriptions();
        return;
      }
    } catch (error) {
      if (_isCurrentPlannerContext(
            operation,
            userId: userId,
            groupId: group.id,
          ) &&
          (!preserveOperationGeneration ||
              _operationGeneration == selectionGeneration)) {
        isOffline = true;
        errorMessage = _friendlyError(error);
      }
    } finally {
      if (_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> createGroup(
    String name,
    String description, {
    String timezone = defaultPlannerTimezone,
  }) async {
    final current = user;
    if (current == null) return;
    if (_groupOperationToken != 0) {
      const error = ScheduleConflictException(
        '그룹 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = _beginOperation();
    _groupOperationToken = operation;
    final revision = _plannerRevision;
    final userId = current.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final group = await _createGroupWithTimezone(
        userId,
        name,
        description,
        timezone: timezone,
      );
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        plannerRevision: revision,
      )) {
        return;
      }
      groups = <PlannerGroup>[...groups, group];
      await selectGroup(group.id);
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      if (_groupOperationToken == operation) _groupOperationToken = 0;
      _finishSaving(operation);
    }
  }

  Future<PlannerGroup> _createGroupWithTimezone(
    String ownerId,
    String name,
    String description, {
    required String timezone,
  }) {
    final capability = _repository;
    // Preserve the old three-positional contract for the historical default
    // timezone. This also lets legacy test doubles override createGroup
    // without accidentally bypassing their controlled Future.
    if (timezone == defaultPlannerTimezone) {
      return _repository.createGroup(ownerId, name, description);
    }
    if (capability is! TimezoneGroupCreationCapability) {
      return Future<PlannerGroup>.error(
        const ScheduleCapabilityException('선택한 시간대를 지원하지 않는 저장소입니다.'),
      );
    }
    return (capability as TimezoneGroupCreationCapability)
        .createGroupWithTimezone(
          ownerId,
          name,
          description,
          timezone: timezone,
        );
  }

  /// Updates the selected group's mutable metadata with optimistic locking.
  /// The form owns its draft values, so a conflict refreshes the latest group
  /// while leaving those values untouched in the screen.
  Future<PlannerGroup> updateGroup({
    required String name,
    required String description,
    String? timezone,
    int? expectedVersion,
  }) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) {
      const error = ScheduleValidationException('그룹을 편집하려면 로그인하고 그룹을 선택해 주세요.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    return _updateGroupCore(
      actorId: current.id,
      group: group,
      name: name,
      description: description,
      timezone: timezone ?? group.timezone,
      expectedVersion: expectedVersion ?? group.version,
    );
  }

  /// Positional alias for screens that use the shorter edit terminology.
  Future<PlannerGroup> editGroup(
    String name,
    String description, {
    String? timezone,
    int? expectedVersion,
  }) => updateGroup(
    name: name,
    description: description,
    timezone: timezone,
    expectedVersion: expectedVersion,
  );

  /// Explicit-version alias useful to preflight/edit flows. The actor is
  /// always the authenticated controller user; a caller-supplied actor is
  /// accepted only as a compatibility check and is never trusted for auth.
  Future<PlannerGroup> updateGroupIfVersion({
    required String groupId,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
    String? actorId,
  }) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null || group.id != groupId) {
      const error = ScheduleValidationException('그룹을 편집하려면 로그인하고 그룹을 선택해 주세요.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    if (actorId != null && actorId != current.id) {
      const error = ScheduleConflictException('현재 로그인한 사용자만 그룹을 편집할 수 있습니다.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    return _updateGroupCore(
      actorId: current.id,
      group: group,
      name: name,
      description: description,
      timezone: timezone,
      expectedVersion: expectedVersion,
    );
  }

  Future<PlannerGroup> _updateGroupCore({
    required String actorId,
    required PlannerGroup group,
    required String name,
    required String description,
    required String timezone,
    required int expectedVersion,
  }) async {
    if (_groupOperationToken != 0) {
      const error = ScheduleConflictException(
        '그룹 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = _beginOperation();
    _groupOperationToken = operation;
    final revision = _plannerRevision;
    final groupId = group.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await _repository.updateGroupIfVersion(
        actorId: actorId,
        groupId: groupId,
        name: name,
        description: description,
        timezone: timezone,
        expectedVersion: expectedVersion,
      );
      if (!_isOperationCurrent(
        operation,
        userId: actorId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return updated;
      }
      _replaceGroup(updated);
      // A metadata edit also refreshes members, invites and realtime events;
      // this ensures a changed timezone immediately updates calendar walls.
      await loadGroups();
      return updated;
    } catch (error) {
      final friendly = _friendlyError(error);
      if (_isOperationCurrent(
        operation,
        userId: actorId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = friendly;
        notifyListeners();
        if (_isConflictError(error)) {
          await _reloadGroupsAfterGroupConflict(
            actorId,
            groupId,
            friendly,
            revision: revision,
          );
        }
      }
      rethrow;
    } finally {
      if (_groupOperationToken == operation) _groupOperationToken = 0;
      _finishSaving(operation);
    }
  }

  /// Leaves the selected group as the authenticated member. The repository
  /// rejects owners; ownership transfer is intentionally a separate action.
  Future<void> leaveGroup() async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) {
      const error = ScheduleValidationException('그룹을 나가려면 로그인하고 그룹을 선택해 주세요.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    if (_groupOperationToken != 0) {
      const error = ScheduleConflictException(
        '그룹 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = _beginOperation();
    _groupOperationToken = operation;
    final revision = _plannerRevision;
    final sessionGeneration = _plannerSessionGeneration;
    final userId = current.id;
    final groupId = group.id;
    _terminalGroupOperations.add(groupId);
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      await _repository.leaveGroup(actorId: userId, groupId: groupId);
      if (_disposed ||
          user?.id != userId ||
          _plannerSessionGeneration != sessionGeneration) {
        return;
      }
      // Invalidate synchronously before any reload/cancellation await. A
      // failing network reload must not resurrect the left group.  This is
      // intentionally performed even when another selection/auth operation
      // made the original leave callback stale; the terminal mutation still
      // has to remove its group row from the visible list.
      final clear = _invalidateGroupScopedData(removeGroupId: groupId);
      await clear;
      if (!_disposed && user?.id == userId && selectedGroup == null) {
        await loadGroups();
      }
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
        notifyListeners();
      }
      _terminalGroupOperations.remove(groupId);
      rethrow;
    } finally {
      if (_groupOperationToken == operation) _groupOperationToken = 0;
      _terminalGroupOperations.remove(groupId);
      _finishSaving(operation);
    }
  }

  Future<void> leaveSelectedGroup() => leaveGroup();

  /// Transfers ownership to an active member and reloads all group-scoped
  /// data so member roles and invite visibility are immediately consistent.
  Future<PlannerGroup> transferGroupOwnership({
    required String newOwnerId,
    int? expectedVersion,
  }) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) {
      const error = ScheduleValidationException(
        '소유권을 이전하려면 로그인하고 그룹을 선택해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    if (_groupOperationToken != 0) {
      const error = ScheduleConflictException(
        '그룹 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = _beginOperation();
    _groupOperationToken = operation;
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = group.id;
    final version = expectedVersion ?? group.version;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await _repository.transferGroupOwnership(
        actorId: userId,
        groupId: groupId,
        newOwnerId: newOwnerId,
        expectedVersion: version,
      );
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return updated;
      }
      _replaceGroup(updated);
      await loadGroups();
      return updated;
    } catch (error) {
      final friendly = _friendlyError(error);
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = friendly;
        notifyListeners();
        if (_isConflictError(error)) {
          await _reloadGroupsAfterGroupConflict(
            userId,
            groupId,
            friendly,
            revision: revision,
          );
        }
      }
      rethrow;
    } finally {
      if (_groupOperationToken == operation) _groupOperationToken = 0;
      _finishSaving(operation);
    }
  }

  Future<PlannerGroup> transferOwnership({
    required String newOwnerId,
    int? expectedVersion,
  }) => transferGroupOwnership(
    newOwnerId: newOwnerId,
    expectedVersion: expectedVersion,
  );

  /// Archives the selected group. The operation is terminal on the
  /// repository; local subscriptions and caches are cleared before the group
  /// list is refreshed.
  Future<void> archiveGroup({int? expectedVersion}) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) {
      const error = ScheduleValidationException('그룹을 보관하려면 로그인하고 그룹을 선택해 주세요.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    if (_groupOperationToken != 0) {
      const error = ScheduleConflictException(
        '그룹 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = _beginOperation();
    _groupOperationToken = operation;
    final revision = _plannerRevision;
    final sessionGeneration = _plannerSessionGeneration;
    final userId = current.id;
    final groupId = group.id;
    final version = expectedVersion ?? group.version;
    _terminalGroupOperations.add(groupId);
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final archivedVersion = await _repository.archiveGroupIfVersion(
        actorId: userId,
        groupId: groupId,
        expectedVersion: version,
      );
      if (_disposed ||
          user?.id != userId ||
          _plannerSessionGeneration != sessionGeneration) {
        return;
      }
      if (archivedVersion <= version) {
        throw const ScheduleConflictException('그룹 보관 버전을 확인할 수 없습니다.');
      }
      // Remove the archived group before awaiting stream cancellation or a
      // network reload. This terminal invalidation survives reload failures
      // and is applied even if a concurrent group switch made this callback
      // stale.
      final clear = _invalidateGroupScopedData(removeGroupId: groupId);
      await clear;
      if (!_disposed && user?.id == userId && selectedGroup == null) {
        await loadGroups();
      }
    } catch (error) {
      final friendly = _friendlyError(error);
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = friendly;
        notifyListeners();
        if (_isConflictError(error)) {
          await _reloadGroupsAfterGroupConflict(
            userId,
            groupId,
            friendly,
            revision: revision,
          );
        }
      }
      _terminalGroupOperations.remove(groupId);
      rethrow;
    } finally {
      if (_groupOperationToken == operation) _groupOperationToken = 0;
      _terminalGroupOperations.remove(groupId);
      _finishSaving(operation);
    }
  }

  Future<void> archiveSelectedGroup({int? expectedVersion}) =>
      archiveGroup(expectedVersion: expectedVersion);

  void _replaceGroup(PlannerGroup updated) {
    final index = groups.indexWhere((group) => group.id == updated.id);
    if (index < 0) {
      groups = <PlannerGroup>[...groups, updated];
    } else {
      final next = <PlannerGroup>[...groups];
      next[index] = updated;
      groups = List<PlannerGroup>.unmodifiable(next);
    }
    selectedGroup = updated;
    notifyListeners();
  }

  Future<void> _reloadGroupsAfterGroupConflict(
    String userId,
    String groupId,
    String message, {
    required int revision,
  }) async {
    if (!_isCurrentPlannerContext(revision, userId: userId, groupId: groupId)) {
      return;
    }
    // Keep a generation marker around the conflict-owned refresh. The
    // refresh itself advances planner revision/tokens, but it must not make a
    // later operation look stale to this continuation. Any external/newer
    // operation advances the marker and wins the error state.
    final reloadGeneration = _operationGeneration;
    await loadGroups(preserveOperationGeneration: true);
    if (_disposed ||
        user?.id != userId ||
        selectedGroup?.id != groupId ||
        _operationGeneration != reloadGeneration) {
      return;
    }
    errorMessage = message;
    notifyListeners();
  }

  Future<void> joinGroup(String inviteCode) async {
    final current = user;
    if (current == null) return;
    if (_groupOperationToken != 0) {
      const error = ScheduleConflictException(
        '그룹 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = _beginOperation();
    _groupOperationToken = operation;
    final revision = _plannerRevision;
    final userId = current.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final group = await _repository.joinGroup(userId, inviteCode);
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        plannerRevision: revision,
      )) {
        return;
      }
      // Joining is the only explicit path that can make a previously left
      // group visible again.  Do this only after the operation/context guard
      // so a stale join completion cannot resurrect another session's data.
      _terminalGroupTombstones.remove(group.id);
      if (!groups.any((candidate) => candidate.id == group.id)) {
        groups = <PlannerGroup>[...groups, group];
      }
      await selectGroup(group.id);
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      if (_groupOperationToken == operation) _groupOperationToken = 0;
      _finishSaving(operation);
    }
  }

  Future<InviteCode> createInviteCode({
    Duration ttl = const Duration(days: 7),
    int maxUses = 20,
  }) async {
    if (_inviteCodeInFlight || isSaving) {
      const error = ScheduleConflictException(
        '초대 코드 생성이 진행 중입니다. 잠시 후 다시 시도해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final group = selectedGroup;
    if (group == null) throw StateError('그룹을 먼저 선택해 주세요.');
    if (!isGroupOwner) {
      throw const ScheduleConflictException('초대 코드를 만들 권한이 없습니다.');
    }
    final currentUserId = user?.id;
    if (currentUserId == null) {
      throw const AuthException('로그인 세션을 다시 확인해 주세요.');
    }
    final revision = _plannerRevision;
    final operation = _beginOperation();
    final inviteOperation = ++_inviteOperation;
    _inviteCodeInFlight = true;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final invite = await _repository.createInviteCodeWithOptions(
        group.id,
        ttl: ttl,
        maxUses: maxUses,
      );
      final isCurrent =
          inviteOperation == _inviteOperation &&
          _isCurrentPlannerContext(
            revision,
            userId: currentUserId,
            groupId: group.id,
          ) &&
          _isOperationCurrent(
            operation,
            userId: currentUserId,
            groupId: group.id,
            plannerRevision: revision,
          );
      if (!isCurrent) {
        // Do not return a plaintext token to a caller whose auth/group
        // context changed while the create RPC was pending.
        throw const InviteOperationStaleException();
      }
      _upsertInvite(invite);
      return invite;
    } catch (error) {
      if (inviteOperation == _inviteOperation &&
          _isOperationCurrent(
            operation,
            userId: currentUserId,
            groupId: group.id,
            plannerRevision: revision,
          )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      if (inviteOperation == _inviteOperation) {
        _inviteCodeInFlight = false;
      }
      _finishSaving(operation);
    }
  }

  bool get isGroupOwner {
    final current = user;
    final group = selectedGroup;
    return current != null &&
        ((group?.ownerId == current.id) ||
            members.any((member) => member.id == current.id && member.isOwner));
  }

  /// Event body writes/deletes remain creator-only.  Group owners receive a
  /// separate participant-list capability and must not gain body edit rights
  /// merely because they can administer the group.
  bool canEditEventParticipants(PlannerEvent event) {
    final current = user;
    final group = selectedGroup;
    if (current == null ||
        group == null ||
        event.groupId != group.id ||
        event.isDeleted) {
      return false;
    }
    final activeMembership = members.any(
      (member) => member.id == current.id && member.isActive,
    );
    if (!activeMembership) return false;
    return event.ownerId == current.id || isGroupOwner;
  }

  /// Loads a detail-route event that may fall outside the current bounded
  /// calendar page. The result is deliberately kept out of [events] so it
  /// cannot disturb page cursors or the selected-range projection; the editor
  /// owns the returned detail snapshot. A late response after sign-out,
  /// identity change, or group switch is discarded rather than exposed.
  Future<PlannerEvent?> loadEventById(String eventId) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) return null;
    if (eventId.trim().isEmpty || eventId != eventId.trim()) {
      throw const ScheduleValidationException('일정 식별자를 확인해 주세요.');
    }
    final inProjection = events
        .where((event) => event.id == eventId && !event.isDeleted)
        .firstOrNull;
    if (inProjection != null) return inProjection;
    final repository = _repository;
    if (!supportsEventById) return null;
    final revision = _plannerRevision;
    final sessionGeneration = _plannerSessionGeneration;
    final userId = current.id;
    final groupId = group.id;
    final capability = repository as EventByIdReadCapability;
    final event = await capability.eventById(
      userId: userId,
      groupId: groupId,
      eventId: eventId,
    );
    if (_disposed ||
        _plannerRevision != revision ||
        _plannerSessionGeneration != sessionGeneration ||
        user?.id != userId ||
        selectedGroup?.id != groupId) {
      return null;
    }
    if (event == null || event.isDeleted) return null;
    if (event.id != eventId || event.groupId != groupId) {
      throw const ScheduleConflictException('일정 응답을 확인할 수 없습니다.');
    }
    return event;
  }

  Future<void> deactivateMember(PlannerMember member) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) return;
    final operation = _beginOperation();
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = group.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      await _repository.setMemberActive(
        groupId,
        member.id,
        false,
        actorId: userId,
      );
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return;
      }
      final refreshedMembers = await _repository.membersForGroup(groupId);
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return;
      }
      _setMembersSnapshot(refreshedMembers);
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      _finishSaving(operation);
    }
  }

  Future<void> revokeInvite(InviteCode invite) async {
    final current = user;
    if (current == null) return;
    final operation = _beginOperation();
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = selectedGroup?.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final revoked = await _repository.revokeInviteCode(
        invite.id,
        expectedVersion: invite.version,
        actorId: userId,
      );
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return;
      }
      final sanitized = _inviteWithoutToken(revoked);
      final nextInvites = invites
          .map((item) => item.id == sanitized.id ? sanitized : item)
          .toList(growable: false);
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return;
      }
      invites = nextInvites;
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      _finishSaving(operation);
    }
  }

  EventRange? _rangeForCalendarSelection({
    PlannerGroup? group,
    DateTime? day,
    CalendarViewMode? mode,
  }) {
    final selectedGroup = group ?? this.selectedGroup;
    if (selectedGroup == null) return null;
    final selected = dateOnly(day ?? selectedDay);
    final selectedMode = mode ?? calendarView;
    return switch (selectedMode) {
      CalendarViewMode.day => calendarDayBounds(
        selected,
        selectedGroup.timezone,
      ).toEventRange(),
      CalendarViewMode.month => calendarMonthBounds(
        selected.year,
        selected.month,
        selectedGroup.timezone,
      ).toEventRange(),
      CalendarViewMode.agenda => calendarAgendaBounds(
        selected.year,
        selected.month,
        selectedGroup.timezone,
      ).toEventRange(),
    };
  }

  String _rangeIdentity(EventRange range, String? participantId) {
    return '${range.viewTimezone}|${range.startUtc.toIso8601String()}|'
        '${range.endUtc.toIso8601String()}|${participantId ?? ''}';
  }

  bool _isCurrentRangeContext({
    required int plannerRevision,
    required int sessionGeneration,
    required int rangeGeneration,
    required String userId,
    required String groupId,
    required EventRange range,
    required String rangeKey,
  }) {
    return !_disposed &&
        _plannerRevision == plannerRevision &&
        _plannerSessionGeneration == sessionGeneration &&
        _rangeGeneration == rangeGeneration &&
        user?.id == userId &&
        selectedGroup?.id == groupId &&
        selectedEventRange == range &&
        _rangeKey == rangeKey;
  }

  void _resetRangeState({bool clearRange = true}) {
    _rangeInvalidationTimer?.cancel();
    _rangeInvalidationTimer = null;
    _rangeGeneration++;
    _rangeKey = null;
    _rangeCursor = null;
    hasMoreEvents = false;
    isLoadingEvents = false;
    isLoadingMoreEvents = false;
    rangeError = null;
    _rangeRefreshQueued = false;
    _rangeRefreshInFlight = false;
    _rangeRefreshOwnerGeneration = null;
    _rangeLoadMoreInFlight = false;
    _rangeLoadMoreOwnerGeneration = null;
    if (clearRange) selectedEventRange = null;
  }

  void _beginSelectedRange({required bool fetch}) {
    final range = _rangeForCalendarSelection();
    if (range == null || !_usesBoundedEventRangeReads) {
      selectedEventRange = null;
      notifyListeners();
      return;
    }
    final participantId = showAllMembers ? null : selectedMemberId;
    final nextKey = _rangeIdentity(range, participantId);
    if (selectedEventRange == range && _rangeKey == nextKey) {
      // Month and agenda cells can change the selected day while keeping the
      // same fetched range. Preserve the current snapshot instead of
      // blanking and reloading an identical page; callers can use the public
      // refresh method when an explicit revalidation is needed.
      notifyListeners();
      return;
    }
    _rangeInvalidationTimer?.cancel();
    _rangeInvalidationTimer = null;
    _rangeGeneration++;
    // A new range supersedes any in-flight first-page/load-more request. Old
    // futures retain their captured generation and therefore cannot clear or
    // overwrite the flags owned by this new request.
    _rangeRefreshQueued = false;
    _rangeRefreshInFlight = false;
    _rangeRefreshOwnerGeneration = null;
    _rangeLoadMoreInFlight = false;
    _rangeLoadMoreOwnerGeneration = null;
    isLoadingMoreEvents = false;
    _rangeKey = nextKey;
    selectedEventRange = range;
    _rangeCursor = null;
    hasMoreEvents = false;
    rangeError = null;
    events = const <PlannerEvent>[];
    isLoadingEvents = fetch;
    notifyListeners();
    if (fetch) {
      unawaited(
        _fetchRangeFirstPage(
          force: true,
          preserveCurrentEvents: false,
          advanceGeneration: false,
        ),
      );
    }
  }

  void _scheduleRangeInvalidation({
    required int operation,
    required String userId,
    required String groupId,
  }) {
    if (!_isCurrentPlannerContext(
      operation,
      userId: userId,
      groupId: groupId,
    )) {
      return;
    }
    _rangeInvalidationTimer?.cancel();
    _rangeInvalidationTimer = Timer(const Duration(milliseconds: 80), () {
      _rangeInvalidationTimer = null;
      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: groupId,
      )) {
        return;
      }
      unawaited(refreshSelectedEventRange(force: true));
    });
  }

  void setCalendarView(CalendarViewMode mode) {
    if (calendarView == mode) return;
    calendarView = mode;
    if (selectedGroup != null && _usesBoundedEventRangeReads) {
      _beginSelectedRange(fetch: true);
      return;
    }
    notifyListeners();
  }

  void setSelectedDay(DateTime day) {
    selectedDay = dateOnly(day);
    if (selectedGroup != null && _usesBoundedEventRangeReads) {
      _beginSelectedRange(fetch: true);
      return;
    }
    notifyListeners();
  }

  void moveSelectedDay(int dayOffset) {
    if (dayOffset == 0) return;
    setSelectedDay(
      DateTime(
        selectedDay.year,
        selectedDay.month,
        selectedDay.day + dayOffset,
      ),
    );
  }

  void jumpToToday() {
    final group = selectedGroup;
    final today = group == null
        ? DateTime.now()
        : utcToWallTime(DateTime.now().toUtc(), group.timezone);
    setSelectedDay(today);
  }

  Future<void> refreshSelectedEventRange({bool force = true}) async {
    if (!_usesBoundedEventRangeReads) {
      // Older adapters do not expose bounded pages, but the home screen's
      // RefreshIndicator still has to refresh their selected-group stream.
      // Route through the established groups/selectGroup lifecycle so the
      // legacy watcher is cancelled and restarted with the same auth guards.
      final current = user;
      final group = selectedGroup;
      if (current == null || group == null) return;
      await loadGroups(preserveOperationGeneration: true);
      return;
    }
    final current = user;
    final group = selectedGroup;
    final range = selectedEventRange ?? _rangeForCalendarSelection();
    if (current == null || group == null || range == null) return;
    if (!force && _rangeCursor == null && events.isNotEmpty) return;
    await _fetchRangeFirstPage(
      force: force,
      preserveCurrentEvents: force && selectedEventRange == range,
      advanceGeneration: force,
    );
  }

  Future<void> _fetchRangeFirstPage({
    required bool force,
    required bool preserveCurrentEvents,
    required bool advanceGeneration,
  }) async {
    final rangeCapability = _repository;
    if (!_usesBoundedEventRangeReads ||
        rangeCapability is! BoundedEventRangeReadCapability) {
      return;
    }
    final capability = rangeCapability as BoundedEventRangeReadCapability;
    final current = user;
    final group = selectedGroup;
    final range = selectedEventRange ?? _rangeForCalendarSelection();
    if (current == null || group == null || range == null) return;
    if (_rangeRefreshInFlight) {
      _rangeRefreshQueued = true;
      return;
    }
    if (!force && events.isNotEmpty) return;
    if (advanceGeneration) {
      _rangeGeneration++;
      _rangeLoadMoreInFlight = false;
      _rangeLoadMoreOwnerGeneration = null;
      isLoadingMoreEvents = false;
    }
    final plannerRevision = _plannerRevision;
    final sessionGeneration = _plannerSessionGeneration;
    final rangeGeneration = _rangeGeneration;
    final participantId = showAllMembers ? null : selectedMemberId;
    final rangeKey = _rangeIdentity(range, participantId);
    _rangeKey = rangeKey;
    selectedEventRange = range;
    _rangeRefreshInFlight = true;
    _rangeRefreshOwnerGeneration = rangeGeneration;
    _rangeCursor = null;
    hasMoreEvents = false;
    isLoadingEvents = true;
    if (!preserveCurrentEvents) events = const <PlannerEvent>[];
    rangeError = null;
    notifyListeners();
    try {
      final page = await capability.eventsForRange(
        userId: current.id,
        groupId: group.id,
        range: range,
        limit: 100,
        participantId: participantId,
      );
      if (!_isCurrentRangeContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        rangeGeneration: rangeGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        rangeKey: rangeKey,
      )) {
        return;
      }
      _validateRangePage(
        page,
        groupId: group.id,
        range: range,
        cursor: null,
        participantId: participantId,
        limit: 100,
      );
      events = List<PlannerEvent>.unmodifiable(page.events);
      _rangeCursor = page.nextCursor;
      hasMoreEvents = page.hasMore;
      rangeError = null;
      isOffline = false;
      notifyListeners();
    } catch (error) {
      if (_isCurrentRangeContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        rangeGeneration: rangeGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        rangeKey: rangeKey,
      )) {
        rangeError = _friendlyError(error);
        isOffline = true;
        // A successful authorization denial is authoritative: retaining a
        // prior group-scoped snapshot would expose private rows after the
        // membership/group became unavailable.  Transport/parse failures are
        // different and intentionally preserve the last-good snapshot during
        // a forced revalidation.
        if (!preserveCurrentEvents || _isAuthoritativeRangeDenial(error)) {
          events = const <PlannerEvent>[];
          _rangeCursor = null;
          hasMoreEvents = false;
        }
        notifyListeners();
      }
    } finally {
      if (_rangeRefreshOwnerGeneration == rangeGeneration) {
        _rangeRefreshInFlight = false;
        _rangeRefreshOwnerGeneration = null;
        isLoadingEvents = false;
        if (_isCurrentRangeContext(
          plannerRevision: _plannerRevision,
          sessionGeneration: _plannerSessionGeneration,
          rangeGeneration: _rangeGeneration,
          userId: current.id,
          groupId: group.id,
          range: range,
          rangeKey: rangeKey,
        )) {
          notifyListeners();
        }
      }
      if (_rangeRefreshQueued && !_disposed) {
        _rangeRefreshQueued = false;
        if (_isCurrentRangeContext(
          plannerRevision: _plannerRevision,
          sessionGeneration: _plannerSessionGeneration,
          rangeGeneration: _rangeGeneration,
          userId: current.id,
          groupId: group.id,
          range: range,
          rangeKey: _rangeKey ?? rangeKey,
        )) {
          unawaited(
            _fetchRangeFirstPage(
              force: true,
              preserveCurrentEvents: true,
              advanceGeneration: true,
            ),
          );
        }
      }
    }
  }

  Future<void> loadMoreEvents() async {
    final rangeCapability = _repository;
    final current = user;
    final group = selectedGroup;
    final range = selectedEventRange;
    final cursor = _rangeCursor;
    if (rangeCapability is! BoundedEventRangeReadCapability ||
        current == null ||
        group == null ||
        range == null ||
        cursor == null ||
        !hasMoreEvents ||
        _rangeLoadMoreInFlight ||
        _rangeRefreshInFlight) {
      return;
    }
    final capability = rangeCapability as BoundedEventRangeReadCapability;
    final plannerRevision = _plannerRevision;
    final sessionGeneration = _plannerSessionGeneration;
    final rangeGeneration = _rangeGeneration;
    final participantId = showAllMembers ? null : selectedMemberId;
    final rangeKey = _rangeIdentity(range, participantId);
    _rangeLoadMoreInFlight = true;
    _rangeLoadMoreOwnerGeneration = rangeGeneration;
    isLoadingMoreEvents = true;
    notifyListeners();
    try {
      final page = await capability.eventsForRange(
        userId: current.id,
        groupId: group.id,
        range: range,
        cursor: cursor,
        limit: 100,
        participantId: participantId,
      );
      if (!_isCurrentRangeContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        rangeGeneration: rangeGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        rangeKey: rangeKey,
      )) {
        return;
      }
      _validateRangePage(
        page,
        groupId: group.id,
        range: range,
        cursor: cursor,
        participantId: participantId,
        limit: 100,
      );
      // A parent invalidation can insert an event that is also present in a
      // page already in flight.  Identical immutable payloads are safe
      // idempotent duplicates; a same-id payload with any changed field is a
      // conflicting response and must fail closed.
      for (final event in page.events) {
        final previous = events
            .where((item) => item.id == event.id)
            .firstOrNull;
        if (previous != null && previous != event) {
          throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
        }
      }
      final merged = <String, PlannerEvent>{
        for (final event in events) event.id: event,
      };
      for (final event in page.events) {
        final previous = merged[event.id];
        if (previous == null || previous.version <= event.version) {
          merged[event.id] = event;
        }
      }
      final ordered = merged.values.toList(growable: false)
        ..sort(_comparePlannerEvents);
      events = List<PlannerEvent>.unmodifiable(ordered);
      _rangeCursor = page.nextCursor;
      hasMoreEvents = page.hasMore;
      rangeError = null;
      isOffline = false;
      notifyListeners();
    } catch (error) {
      if (_isCurrentRangeContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        rangeGeneration: rangeGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        rangeKey: rangeKey,
      )) {
        rangeError = _friendlyError(error);
        isOffline = true;
        notifyListeners();
      }
    } finally {
      if (_rangeLoadMoreOwnerGeneration == rangeGeneration) {
        _rangeLoadMoreInFlight = false;
        _rangeLoadMoreOwnerGeneration = null;
        isLoadingMoreEvents = false;
        if (_isCurrentRangeContext(
          plannerRevision: _plannerRevision,
          sessionGeneration: _plannerSessionGeneration,
          rangeGeneration: _rangeGeneration,
          userId: current.id,
          groupId: group.id,
          range: range,
          rangeKey: rangeKey,
        )) {
          notifyListeners();
        }
      }
    }
  }

  static int _comparePlannerEvents(PlannerEvent left, PlannerEvent right) {
    final byStart = left.startAt.toUtc().compareTo(right.startAt.toUtc());
    return byStart != 0 ? byStart : left.id.compareTo(right.id);
  }

  void _validateRangePage(
    EventRangePage page, {
    required String groupId,
    required EventRange range,
    required EventRangeCursor? cursor,
    required String? participantId,
    required int limit,
  }) {
    if (limit < 1 || limit > 200 || page.events.length > limit) {
      throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
    }
    final seen = <String>{};
    PlannerEvent? previous;
    for (final event in page.events) {
      if (event.groupId != groupId ||
          event.isDeleted ||
          !eventOverlapsCalendarRange(event, range) ||
          !seen.add(event.id) ||
          (participantId != null && !event.memberIds.contains(participantId))) {
        throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
      }
      if (previous != null && _comparePlannerEvents(previous, event) >= 0) {
        throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
      }
      if (cursor != null &&
          (event.startAt.toUtc().isBefore(cursor.startsAtUtc) ||
              (event.startAt.toUtc() == cursor.startsAtUtc &&
                  event.id.compareTo(cursor.eventId) <= 0))) {
        throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
      }
      previous = event;
    }
    if (page.hasMore && page.nextCursor == null) {
      throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
    }
    if (page.nextCursor != null && page.events.isEmpty) {
      throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
    }
    if (page.nextCursor != null && page.events.isNotEmpty) {
      final last = page.events.last;
      if (page.nextCursor!.startsAtUtc != last.startAt.toUtc() ||
          page.nextCursor!.eventId != last.id) {
        throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
      }
    }
  }

  void setMemberFilter(String? memberId) {
    selectedMemberId = memberId;
    showAllMembers = memberId == null;
    if (selectedEventRange != null && _usesBoundedEventRangeReads) {
      _beginSelectedRange(fetch: true);
      return;
    }
    notifyListeners();
  }

  /// Membership refreshes can remove the currently selected member even when
  /// another client performed the deactivation. Clear the stale filter so a
  /// deactivated identity cannot leave the calendar in a misleading state.
  void _setMembersSnapshot(Iterable<PlannerMember> incoming) {
    members = List<PlannerMember>.unmodifiable(incoming);
    final selected = selectedMemberId;
    var filterCleared = false;
    if (selected != null &&
        !members.any((member) => member.id == selected && member.isActive)) {
      selectedMemberId = null;
      showAllMembers = true;
      filterCleared = true;
    }
    if (filterCleared &&
        selectedEventRange != null &&
        _usesBoundedEventRangeReads) {
      _beginSelectedRange(fetch: true);
    }
  }

  Future<void> saveEvent({
    PlannerEvent? existing,
    required EventDraft draft,
  }) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) {
      const error = ScheduleValidationException('일정을 저장하려면 로그인하고 그룹을 선택해 주세요.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final operation = _beginOperation();
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = group.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final requestedMemberIds = canonicalEventMemberIds(draft.memberIds);
      final normalizedDraft = draft.copyWith(
        memberIds: draft.hasExplicitMemberIds ? requestedMemberIds : null,
      );
      if (existing == null) {
        // A capable adapter promises atomic event+participant creation.  A
        // legacy adapter may still create the default creator-only event only
        // when the draft genuinely omitted its participant field.  An
        // explicit empty list is a real unassigned assignment and cannot be
        // silently converted to the creator by an adapter without the
        // capability.
        if (normalizedDraft.hasExplicitMemberIds &&
            _repository is! EventMemberAssignmentCapability) {
          throw const ScheduleCapabilityException('일정 멤버 지정을 지원하지 않는 저장소입니다.');
        }
        final created = await _repository.createEvent(
          userId,
          groupId,
          normalizedDraft,
        );
        if (!_isOperationCurrent(
          operation,
          userId: userId,
          groupId: groupId,
          plannerRevision: revision,
        )) {
          return;
        }
        final normalizedCreated = _validatedEventMutationResult(
          created,
          expectedGroupId: groupId,
          expectedOwnerId: userId,
          expectedVersion: 1,
          requestedMemberIds: normalizedDraft.hasExplicitMemberIds
              ? requestedMemberIds
              : <String>[userId],
          // Only pre-capability adapters may need the historical client
          // default when their response omitted the creator assignment.
          // A capable adapter promises the exact persisted member set, so
          // an omitted creator in its response is malformed rather than a
          // value the controller may fabricate locally.
          allowLegacyCreatorDefault: !_requiresExactEventMutationResults,
        );
        _upsertEvent(normalizedCreated);
      } else {
        if (existing.groupId != groupId || existing.isDeleted) {
          throw const ScheduleConflictException('일정을 찾을 수 없습니다.');
        }
        if (existing.ownerId != userId) {
          throw const ScheduleConflictException('이 일정은 작성자만 변경할 수 있습니다.');
        }
        final existingMemberIds = canonicalEventMemberIds(existing.memberIds);
        final membersChanged = !_sameMemberIdSet(
          existingMemberIds,
          requestedMemberIds,
        );
        if (membersChanged && _repository is! EventMemberAssignmentCapability) {
          throw const ScheduleCapabilityException('일정 멤버 지정을 지원하지 않는 저장소입니다.');
        }
        final updated = await _repository.updateEvent(
          existing.copyWith(
            title: normalizedDraft.title,
            note: normalizedDraft.note,
            startAt: normalizedDraft.startAt.toUtc(),
            endAt: normalizedDraft.endAt.toUtc(),
            allDay: normalizedDraft.allDay,
            memberIds: requestedMemberIds,
            colorValue: normalizedDraft.colorValue,
            timezone: normalizedDraft.timezone,
            allDayStartDate: normalizedDraft.allDayStartDate,
            allDayEndDate: normalizedDraft.allDayEndDate,
            clearAllDayDates: !normalizedDraft.allDay,
          ),
          expectedVersion: existing.version,
          actorId: userId,
        );
        if (!_isOperationCurrent(
          operation,
          userId: userId,
          groupId: groupId,
          plannerRevision: revision,
        )) {
          return;
        }
        _upsertEvent(
          _validatedEventMutationResult(
            updated,
            expectedEventId: existing.id,
            expectedGroupId: groupId,
            expectedOwnerId: existing.ownerId,
            expectedVersion: existing.version + 1,
            requestedMemberIds: requestedMemberIds,
          ),
        );
      }
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      _finishSaving(operation);
    }
  }

  Future<void> replaceEventMembers(
    PlannerEvent event,
    Iterable<String> memberIds,
  ) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) {
      const error = ScheduleValidationException(
        '일정 멤버를 변경하려면 로그인하고 그룹을 선택해 주세요.',
      );
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    if (!canEditEventParticipants(event)) {
      const error = ScheduleConflictException('이 일정의 멤버를 변경할 권한이 없습니다.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final repository = _repository;
    if (repository is! EventMemberAssignmentCapability) {
      const error = ScheduleCapabilityException('일정 멤버 지정을 지원하지 않는 저장소입니다.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
    }
    final EventMemberAssignmentCapability capability =
        repository as EventMemberAssignmentCapability;
    late final List<String> normalizedMemberIds;
    try {
      normalizedMemberIds = canonicalEventMemberIds(memberIds);
    } catch (error) {
      errorMessage = _friendlyError(error);
      notifyListeners();
      rethrow;
    }
    final operation = _beginOperation();
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = group.id;
    final expectedResultVersion =
        _sameMemberIdSet(event.memberIds, normalizedMemberIds)
        ? event.version
        : event.version + 1;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final updated = await capability.replaceEventMembers(
        event.id,
        memberIds: normalizedMemberIds,
        expectedVersion: event.version,
        actorId: userId,
      );
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return;
      }
      _upsertEvent(
        _validatedEventMutationResult(
          updated,
          expectedEventId: event.id,
          expectedGroupId: groupId,
          expectedOwnerId: event.ownerId,
          expectedVersion: expectedResultVersion,
          requestedMemberIds: normalizedMemberIds,
        ),
      );
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      _finishSaving(operation);
    }
  }

  static bool _sameMemberIdSet(Iterable<String> left, Iterable<String> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
  }

  PlannerEvent _validatedEventMutationResult(
    PlannerEvent incoming, {
    String? expectedEventId,
    required String expectedGroupId,
    required String expectedOwnerId,
    required int expectedVersion,
    required Iterable<String> requestedMemberIds,
    bool allowLegacyCreatorDefault = false,
  }) {
    if ((expectedEventId != null && incoming.id != expectedEventId) ||
        incoming.groupId != expectedGroupId ||
        incoming.ownerId != expectedOwnerId ||
        incoming.version != expectedVersion ||
        incoming.isDeleted) {
      throw const ScheduleConflictException('일정 변경 응답을 확인할 수 없습니다.');
    }
    final requested = canonicalEventMemberIds(requestedMemberIds);
    final returned = canonicalEventMemberIds(incoming.memberIds);
    if (!_sameMemberIdSet(requested, returned)) {
      if (!(allowLegacyCreatorDefault &&
          returned.isEmpty &&
          requested.length == 1 &&
          requested.single == expectedOwnerId)) {
        throw const ScheduleConflictException('일정 멤버 변경 응답을 확인할 수 없습니다.');
      }
      return incoming.copyWith(memberIds: requested);
    }
    return incoming.copyWith(memberIds: returned);
  }

  void _upsertEvent(PlannerEvent incoming) {
    final selectedGroupId = selectedGroup?.id;
    if (selectedGroupId != null && incoming.groupId != selectedGroupId) return;
    final normalizedIds = canonicalEventMemberIds(incoming.memberIds);
    final normalizedIncoming = incoming.copyWith(memberIds: normalizedIds);
    final index = events.indexWhere(
      (event) => event.id == normalizedIncoming.id,
    );
    if (selectedEventRange != null &&
        (normalizedIncoming.isDeleted ||
            !eventOverlapsCalendarRange(
              normalizedIncoming,
              selectedEventRange!,
            ) ||
            (!showAllMembers &&
                selectedMemberId != null &&
                !normalizedIncoming.memberIds.contains(selectedMemberId)))) {
      if (index >= 0) {
        final next = <PlannerEvent>[...events]..removeAt(index);
        events = List<PlannerEvent>.unmodifiable(next);
      }
      return;
    }
    if (index == -1) {
      final next = <PlannerEvent>[...events, normalizedIncoming]
        ..sort(_comparePlannerEvents);
      events = List<PlannerEvent>.unmodifiable(next);
      return;
    }
    if (events[index].version > normalizedIncoming.version) return;
    final next = <PlannerEvent>[...events];
    next[index] = normalizedIncoming;
    next.sort(_comparePlannerEvents);
    events = List<PlannerEvent>.unmodifiable(next);
  }

  /// Merge an invite returned by a mutation with an in-flight lifecycle
  /// metadata refresh. Both responses can contain the same row id; replacing
  /// by id keeps the visible projection canonical instead of prepending a
  /// duplicate when the mutation Future settles last. The creation RPC is the
  /// one-shot plaintext boundary; cached/listed rows must never retain it.
  void _upsertInvite(InviteCode incoming) {
    final sanitized = _inviteWithoutToken(incoming);
    final index = invites.indexWhere((invite) => invite.id == sanitized.id);
    if (index == -1) {
      invites = <InviteCode>[sanitized, ...invites];
      return;
    }
    final next = <InviteCode>[...invites];
    next[index] = sanitized;
    invites = List<InviteCode>.unmodifiable(next);
  }

  static InviteCode _inviteWithoutToken(InviteCode incoming) {
    return InviteCode(
      id: incoming.id,
      groupId: incoming.groupId,
      expiresAt: incoming.expiresAt,
      maxUses: incoming.maxUses,
      usesCount: incoming.usesCount,
      version: incoming.version,
      token: null,
      revokedAt: incoming.revokedAt,
      createdAt: incoming.createdAt,
      updatedAt: incoming.updatedAt,
    );
  }

  Future<void> deleteEvent(PlannerEvent event) async {
    final current = user;
    if (current == null) return;
    final operation = _beginOperation();
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = selectedGroup?.id;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      await _repository.softDeleteEvent(
        event.id,
        expectedVersion: event.version,
        actorId: userId,
      );
      if (!_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        return;
      }
      if (selectedEventRange != null) {
        final next = <PlannerEvent>[
          ...events.where((candidate) => candidate.id != event.id),
        ];
        events = List<PlannerEvent>.unmodifiable(next);
        notifyListeners();
      }
    } catch (error) {
      if (_isOperationCurrent(
        operation,
        userId: userId,
        groupId: groupId,
        plannerRevision: revision,
      )) {
        errorMessage = _friendlyError(error);
      }
      rethrow;
    } finally {
      _finishSaving(operation);
    }
  }

  void toggleDarkMode(bool value) {
    darkMode = value;
    notifyListeners();
  }

  void setTextScale(double value) {
    textScale = value.clamp(0.9, 1.25);
    notifyListeners();
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  String _friendlyError(Object error) {
    if (error is AuthException) return error.message;
    if (error is RuntimeConfigurationException) return error.message;
    if (error is InviteUnavailableException) return error.message;
    if (error is InviteRateLimitedException) return error.message;
    if (error is InviteJoinCommittedException) return error.message;
    if (error is InviteOperationStaleException) return error.message;
    if (error is InviteLinkFormatException) return error.message;
    if (error is InviteLinkConfigurationException) return error.message;
    if (error is ScheduleConflictException) return error.message;
    if (error is ScheduleValidationException) return error.message;
    if (error is FormatException) return error.message;
    if (error is StateError) {
      final message = error.message;
      final lower = message.toLowerCase();
      if (lower.contains('초대') &&
          (lower.contains('찾') ||
              lower.contains('만료') ||
              lower.contains('올바르') ||
              lower.contains('사용'))) {
        return const InviteUnavailableException.invalidOrExpired().message;
      }
    }
    if (error is PostgrestException && error.code == '40001') {
      return '다른 사용자가 변경했어요. 최신 내용을 다시 불러왔습니다.';
    }
    return '잠시 후 다시 시도해 주세요.';
  }

  /// Identifies an authoritative access loss without guessing from localized
  /// error text.  PostgREST's `42501` is the SQL insufficient-privilege code;
  /// the explicit HTTP/auth statuses cover session revocation responses.
  bool _isAuthoritativeRangeDenial(Object error) {
    if (error is ScheduleAuthorizationException) return true;
    if (error is PostgrestException) {
      final code = error.code;
      return code == '42501' || code == '401' || code == '403';
    }
    if (error is AuthException) {
      final status = error.statusCode;
      return status == '401' || status == '403';
    }
    return false;
  }

  /// Exposes the structural lifecycle/authorization classification to detail
  /// routes. Localized error strings are intentionally not inspected by the
  /// editor when deciding whether a missing event is terminal or retryable.
  bool isAuthoritativeAccessDenial(Object error) =>
      _isAuthoritativeRangeDenial(error);

  bool _isConflictError(Object error) {
    return error is ScheduleConflictException ||
        (error is PostgrestException && error.code == '40001');
  }

  @override
  void notifyListeners() {
    // 경로/공급자가 해제된 뒤에도 인증과 실시간 콜백이 완료될 수 있다.
    // 비동기 연속 작업에서 해제된 ChangeNotifier에 알리지 말고 늦게 도착한
    // 업데이트를 무시한다.
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final settlementCompleter = _signOutSettlementCompleter;
    _signOutSettlement = null;
    _signOutSettlementCompleter = null;
    if (settlementCompleter != null && !settlementCompleter.isCompleted) {
      settlementCompleter.complete();
    }
    ++_authEventGeneration;
    _invalidateAuthOperations();
    _signOutOperationToken = null;
    _finishSocialAuth();
    _operationToken++;
    _plannerRevision++;
    _groupOperationToken = 0;
    _resetRangeState();
    _cancelGroupMetadataRefresh();
    unawaited(_eventInvalidationSubscription?.cancel());
    _eventInvalidationSubscription = null;
    _oauthTimeoutTimer?.cancel();
    _oauthTimeoutTimer = null;
    _pendingInviteExpiryTimer?.cancel();
    _pendingInviteExpiryTimer = null;
    _clearPendingInvitePreviewFuture();
    unawaited(_authSubscription?.cancel());
    unawaited(_inviteLinkSubscription?.cancel());
    _inviteLinkSubscription = null;
    unawaited(_eventSubscription?.cancel());
    unawaited(_groupLifecycleSubscription?.cancel());
    _groupLifecycleSubscription = null;
    super.dispose();
  }
}
