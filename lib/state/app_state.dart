// 공개 생성자 매개변수 이름은 비공개 필드와 의도적으로 다르게 둔다.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/appearance_preferences.dart';
import '../core/invite_link.dart';
import '../core/invite_code_utils.dart';
import '../core/pending_invite_store.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
import '../repositories/auth_repository.dart';
import '../repositories/schedule_repository.dart';
import 'notification_state.dart';

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

final appearancePreferencesStoreProvider = Provider<AppearancePreferencesStore>(
  (ref) => SharedPreferencesAppearancePreferencesStore(),
);

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

/// 그룹 수명 주기 신호가 생성한 병합된 메타데이터 새로 고침 요청이다.
/// 요청에 작업 컨텍스트를 함께 보관하면 디바운스 타이머가 실행되기 전에 선택,
/// 신원 또는 플래너 리비전이 바뀌었을 때 지연된 구성원 목록 읽기를 안전하게
/// 차단할 수 있다.
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
    appearancePreferencesStore: ref.watch(appearancePreferencesStoreProvider),
    // 알림 컨트롤러는 무효화 결과를 받는 곳이지 플래너 입력이 아니다. 이를
    // 관찰하면 권한/조정 알림마다 PlannerController를 다시 만들고 인증/부트스트랩
    // 루프를 알림 공급자에 되돌려 보낸다. 대신 안정적인 인스턴스를 한 번만 읽는다.
    notifications: ref.read(notificationControllerProvider),
  );
  return controller;
}, dependencies: <ProviderOrFamily>[notificationControllerProvider]);

class PlannerController extends ChangeNotifier {
  PlannerController({
    required AuthRepository auth,
    required ScheduleRepository repository,
    NotificationInvalidationSink? notifications,
    Duration oauthTimeout = const Duration(minutes: 2),
    Duration? socialAuthTimeout,
    PendingInviteStore? pendingInviteStore,
    Duration pendingInviteTtl = const Duration(minutes: 30),
    Duration searchDebounce = const Duration(milliseconds: 300),
    AppearancePreferencesStore? appearancePreferencesStore,
  }) : _auth = auth,
       _repository = repository,
       _notifications = notifications,
       _oauthTimeout = socialAuthTimeout ?? oauthTimeout,
       _pendingInviteStore =
           pendingInviteStore ?? createDefaultPendingInviteStore(),
       _pendingInviteTtl = pendingInviteTtl,
       _searchDebounce = searchDebounce,
       _appearancePreferencesStore =
           appearancePreferencesStore ?? MemoryAppearancePreferencesStore() {
    if (pendingInviteTtl <= Duration.zero) {
      throw ArgumentError.value(
        pendingInviteTtl,
        'pendingInviteTtl',
        '0보다 커야 합니다',
      );
    }
    if (searchDebounce < Duration.zero) {
      throw ArgumentError.value(
        searchDebounce,
        'searchDebounce',
        '음수가 될 수 없습니다',
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
    _appearancePreferencesHydration = _hydrateAppearancePreferences();
    unawaited(bootstrap());
  }

  final AuthRepository _auth;
  final ScheduleRepository _repository;
  final NotificationInvalidationSink? _notifications;
  final Duration _oauthTimeout;
  final PendingInviteStore _pendingInviteStore;
  final Duration _pendingInviteTtl;
  final Duration _searchDebounce;
  final AppearancePreferencesStore _appearancePreferencesStore;
  late final Future<void> _pendingHydration;
  late final Future<void> _appearancePreferencesHydration;
  Future<void> _appearancePreferencesWriteQueue = Future<void>.value();
  int _appearancePreferencesRevision = 0;
  bool _darkModeChangedDuringHydration = false;
  bool _textScaleChangedDuringHydration = false;
  bool _appearancePreferencesHydrated = false;
  bool _appearancePreferencesLoadInFlight = false;
  bool _appearancePreferencesWritePending = false;

  Future<void> get appearancePreferencesReady =>
      _appearancePreferencesHydration;

  Future<void> settleAppearancePreferences() async {
    await _appearancePreferencesHydration;
    await _appearancePreferencesWriteQueue;
  }

  /// 알림 조정은 이미 커밋된 인증/그룹/일정 변경의 부수 효과다. 구현이 Future를
  /// 만들기 전에 동기적으로 던지거나 나중에 거부해도 원 작업의 성공을 뒤집거나
  /// 처리되지 않은 비동기 오류로 새지 않게 한다.
  void _runNotificationSideEffect(
    Future<void> Function(NotificationInvalidationSink notifications) operation,
  ) {
    final notifications = _notifications;
    if (notifications == null) return;
    Future<void>.sync(() => operation(notifications)).ignore();
  }

  PlannerUser? user;
  List<PlannerGroup> groups = const <PlannerGroup>[];
  List<PlannerMember> members = const <PlannerMember>[];
  List<InviteCode> _invites = const <InviteCode>[];

  /// 컨트롤러 경계에서 초대 행이 일회성 평문 토큰을 보관하지 못하게 한다.
  /// 저장소나 가짜 구현이 토큰을 포함한 행을 반환할 수 있으므로 목록에 할당할
  /// 때마다 방어적으로 `token: null`을 지정해 복사한다.
  List<InviteCode> get invites => _invites;

  set invites(Iterable<InviteCode> value) {
    _invites = List<InviteCode>.unmodifiable(value.map(_inviteWithoutToken));
  }

  List<PlannerEvent> _events = const <PlannerEvent>[];
  List<PlannerEvent> get events => _events;

  /// 이전 테스트 대역에서 사용하는 공개 할당 방식을 유지하면서 컨트롤러 경계의
  /// 모든 일정 스냅샷을 불변으로 둔다.
  set events(Iterable<PlannerEvent> value) {
    _events = List<PlannerEvent>.unmodifiable(value);
  }

  PlannerGroup? selectedGroup;
  DateTime _selectedDay = CalendarDateBounds.clamp(DateTime.now());
  DateTime get selectedDay => _selectedDay;

  set selectedDay(DateTime value) {
    _selectedDay = CalendarDateBounds.clamp(value);
  }

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
  String? appearancePreferencesError;
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
  // 명시적 로그아웃이 소유하는 플래너 작업이다. Supabase는 원격 폐기 Future가
  // 완료되기 전에 로컬 SIGNED_OUT 이벤트를 내보낸 뒤 폐기 실패를 보고할 수 있다.
  // 호출자가 실패를 계속 표시할 수 있도록 해당 이벤트가 이 작업 토큰을 유지해야 한다.
  int? _signOutOperationToken;
  String? _signOutFailureMessage;
  // 명시적 로그아웃이 이전 SDK 세션을 폐기하는 동안에는 새 인증 소유자를 시작하지
  // 않는다. Supabase가 폐기 Future 완료 전에 SIGNED_OUT을 내보낼 수 있으므로 이
  // 게이트가 다음 작업을 직렬화한다.
  Future<void>? _signOutSettlement;
  Completer<void>? _signOutSettlementCompleter;
  bool _ignoreExternalIdentityEvents = false;
  // Supabase 공개 이벤트 페이로드의 OAuth에는 콜백 요청 ID가 없다. 실행이 시간
  // 초과되거나 실패하면 다른 명시적 로그인이 커밋된 뒤 늦은 공급자 콜백이 계정을
  // 전환하지 못하도록 툼스톤을 유지한다.
  bool _staleSocialAuthFence = false;
  String? _staleSocialExpectedIdentity;
  // 대기열의 복구 이벤트 처리기가 실행되기 전에 userUpdated가 뒤따를 수 있다.
  // 병합된 업데이트가 소셜 툼스톤의 계정 검사를 통과할 만큼 해당 의도를 유지한다.
  String? _queuedPasswordRecoveryIdentity;
  // 차단된 신원이 명시적 인증 결과에서 왔는지 추적한다. 더 새로운 비밀번호 작업이
  // 대기 중이면 일치하지 않는 공급자 이벤트를 무시한다. 결과가 커밋된 뒤 같은
  // 불일치가 발생하면 안전하게 차단하고 SDK 세션을 폐기한다.
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
  // 이전 충돌 재조회 후속 작업이 새 작업의 오류를 덮어쓰지 못하게 하는 단조 증가
  // 플래너 작업 세대 값이다. 충돌이 소유한 새로 고침은 내부
  // loadGroups/selectGroup 과정에서 이 값을 유지하고, 모든 외부 작업은 값을 높인다.
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
  Completer<void>? _rangeQueuedRefreshCompleter;
  final Set<Completer<void>> _rangeRefreshAwaiters = <Completer<void>>{};
  Timer? _rangeInvalidationTimer;
  String? _rangeKey;
  // 검색은 선택한 캘린더 범위와 독립된 프로젝션이다. 자체 디바운스, 세대, 커서 및
  // 로딩 플래그를 사용하므로 늦게 도착한 검색 응답이 캘린더 페이지를 덮어쓰거나
  // 그 반대 상황이 발생하지 않는다.
  String searchQuery = '';
  List<PlannerEvent> _searchResults = const <PlannerEvent>[];
  List<PlannerEvent> get searchResults => _searchResults;

  set searchResults(Iterable<PlannerEvent> value) {
    _searchResults = List<PlannerEvent>.unmodifiable(value);
  }

  EventRange? searchRange;
  String? searchCreatorId;
  String? searchParticipantId;
  EventRangeCursor? searchCursor;
  bool hasMoreSearchResults = false;
  bool isSearching = false;
  bool isLoadingMoreSearch = false;
  String? searchError;
  Timer? _searchTimer;
  Timer? _searchInvalidationTimer;
  int _searchGeneration = 0;
  bool _searchRefreshInFlight = false;
  int? _searchRefreshOwnerGeneration;
  bool _searchLoadMoreInFlight = false;
  int? _searchLoadMoreOwnerGeneration;
  bool _searchRefreshQueued = false;
  String? _searchKey;
  bool _searchActive = false;
  final Set<String> _terminalGroupOperations = <String>{};
  // 나가기/보관 및 원격 수명 주기 툼스톤은 컨트롤러 관점에서 최종 상태다. 진행 중
  // 작업 집합과 이를 분리하면 변경 성공 후 오래된 그룹 새로 고침이 비공개 데이터를
  // 다시 가져오는 일을 막을 수 있다. 명시적 재참여에 성공하면 보관이 아닌 일반
  // 나가기에 대한 툼스톤을 지운다.
  final Set<String> _terminalGroupTombstones = <String>{};
  int _inviteOperation = 0;
  // 대기 중인 초대 의도는 플래너 지우기/인증 작업 세대와 의도적으로 독립되어 있다.
  // 로그아웃 상태에서 포착한 의도는 첫 로그인 성공까지 유지되어야 하지만, 명시적
  // 로그아웃이나 이후 신원 전환 시에는 동기적으로 무효화해야 한다.
  String? _pendingInviteToken;
  DateTime? _pendingInviteExpiresAt;
  String? _pendingInviteReturnRoute;
  String? _pendingInviteBoundUserId;
  PendingInviteState _pendingInviteState = PendingInviteState.none;
  InvitePreview? _pendingInvitePreview;
  String? _pendingInviteError;
  int _pendingInviteGeneration = 0;
  int _pendingInviteSessionGeneration = 0;
  // 플래너/그룹 작업은 초대 의도를 지우지 않고 `_plannerRevision`을 높인다. 미리 보기와
  // 수락을 시도할 때마다 리비전을 캡처하여 이전 선택 그룹 컨텍스트의 콜백이 새
  // 컨텍스트에 프로젝션을 커밋하지 못하게 한다.
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

  /// 이 어댑터가 상세 경로에 대해 서버 기준 단건 조회를 수행할 수 있는지 나타낸다.
  /// 기존 전체 스트림 테스트/대역 어댑터는 의도적으로 이 경로를 사용하지 않는다.
  bool get supportsEventById =>
      _usesBoundedEventRangeReads && _repository is EventByIdReadCapability;

  bool get supportsRecurrence => _repository is RecurrenceCapability;

  bool get supportsEventOccurrenceByKey =>
      _usesBoundedEventRangeReads &&
      _repository is EventOccurrenceReadCapability &&
      // 로컬 하위 클래스는 보통 EventById만 채우는 기존 테스트 대역으로 사용된다.
      // 구체적인 어댑터가 발생 항목 프로젝션 사용을 명시하지 않으면 기존 경로를 유지한다.
      !(_repository is LocalScheduleRepository &&
          _repository.runtimeType != LocalScheduleRepository);

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
    // 참여자 변경을 지원한다고 알리는 비로컬 어댑터는 프로덕션 기능이므로 저장된
    // 할당을 정확히 되돌려줘야 한다. 이 기능이 없는 이전 어댑터에는 생략된 필드에
    // 대한 아래의 기존 작성자 대체 처리만 허용하며, 명시적 멤버 목록은 변경 전에
    // 실패한다.
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

  /// 공개 초대 프로젝션이다. Bearer 토큰은 이 컨트롤러와 임시 저장소 안에서만
  /// 비공개로 유지하며, UI 코드는 정제된 미리 보기/상태 데이터만 받는다.
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

  /// 컨트롤러를 네이티브/웹 플러그인과 결합하지 않고 플랫폼 딥 링크 입력을 연결한다.
  /// 스트림을 교체하면 이전 구독을 종료하며, 모든 URI는 상태를 만들기 전에 검증된다.
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
        _runNotificationSideEffect(
          (notifications) => notifications.onAuthenticated(existing!.id),
        );
        await loadGroups();
      } else {
        authFlowState = AuthFlowState.signedOut;
      }
    } catch (error) {
      if (_plannerRevision == operation) {
        errorMessage = _friendlyError(error);
      }
    } finally {
      // loadGroups는 자체 작업을 시작한다. 이 이전 부트스트랩이 더 새로운 인증/조회
      // 요청이 소유한 진행 표시를 끄지 못하게 한다.
      if (_plannerRevision == operation) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _hydratePendingInvite() async {
    // 느린 저장소 읽기가 대기 중인 동안 명시적으로 지웠거나 더 새로운 인증/플래너
    // 세션이 무효화한 의도를 되살리지 못하게 한다.
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
    // 저장소가 저장된 만료 시각을 이미 적용했다. 기한이 없는 이전 저장소에는 제한된
    // 탭 내부 대체 처리를 적용한다.
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

  /// 원본 URI를 컨트롤러 상태에 넣지 않고 엄격하게 검증된 링크를 포착한다. 잘못되거나
  /// 설정되지 않은 링크를 무시하여 비정상 딥 링크가 사용자에게 노출되는 토큰
  /// 오라클이 되지 못하게 한다.
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

  /// 플랫폼 라우팅에서 제공한 정규 토큰을 포착한다. 수동 코드 입력은 계속
  /// [joinGroup]을 사용하며, 이 메서드는 로컬 `family` 데모 매직 코드와 표시용
  /// 구분자를 의도적으로 거부한다.
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
      // 같은 의도에 대한 두 번째 경로/위젯 콜백은 별도의 오라클 호출을 만들지 않고
      // 기존 요청에 합류한다.
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

  /// 명시적 수락을 정확히 한 번 수행한다. 서버 참여가 커밋된 직후 그룹을 선택하기
  /// 전에 대기 중인 토큰을 지워, 이후 그룹 조회 실패가 두 번째 참여를 일으키지
  /// 못하게 한다.
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
    // 토큰이 그사이 만료·폐기·소진되었더라도 미리 보기는 의도적으로
    // `alreadyMember: true`를 보고할 수 있다. 미리 보기와 수락 사이에 멤버십이
    // 바뀔 수 있으므로 이 힌트를 신뢰해 서버 기준의 멱등 참여 RPC를 우회하지 않는다.
    // 로컬에서 미리 보기가 만료된 비멤버만 요청 전에 최종 상태로 처리한다.
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
        // 참여 RPC는 이미 커밋되었다. 선택된 플래너 컨텍스트만 오래된 경우 반환 전에
        // 이 세대만 지워 호출자가 같은 Bearer 토큰을 다시 시도하지 못하게 한다.
        // 새 토큰이나 신원에는 자체 세대가 있으므로 그대로 둔다.
        _clearPendingInviteIfCurrent(
          generation: generation,
          token: token,
          userId: userId,
          sessionGeneration: sessionGeneration,
        );
        return null;
      }
      _clearPendingInvite();
      // 새로 커밋된 멤버십을 수락하는 시점은 나가기/보관으로 툼스톤 처리된 그룹을
      // 명시적으로 되살리는 경계다. 위의 정확한 대기 초대/세션 가드 뒤에서만 처리하여
      // 오래된 수락 완료가 다른 계정의 그룹 프로젝션을 되살리지 못하게 한다.
      _terminalGroupTombstones.remove(joined.id);
      if (!groups.any((candidate) => candidate.id == joined.id)) {
        groups = <PlannerGroup>[...groups, joined];
      }
      _runNotificationSideEffect(
        (notifications) =>
            notifications.onMembershipChanged(groupId: joined.id),
      );
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
        // 저장소가 멤버십은 이미 커밋했지만 결과 그룹 프로젝션을 불러오지 못했다.
        // 다시 시도하면 토큰을 두 번 제출하게 되므로 플래너 리비전이 바뀌었더라도
        // 이 Bearer 의도만 지운다. 새 토큰이나 신원은 그대로 둔다.
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

  /// 계정 삭제 흐름은 초대 구현 세부 사항에 의존하지 않고 명시적 취소와 같은
  /// 개인정보 보호 차단선을 사용할 수 있다.
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
      // 만료 시 세대가 종료되므로 미리 보기의 `finally` 블록은 일반 상태 변경 알림을
      // 보내지 않는다. 호출자가 일시적인 `catch` 알림을 억제했더라도 여기서는 항상
      // 알린다.
      _expirePendingInvite(error: error, notify: true);
      return;
    }
    _pendingInviteError = _friendlyError(error);
    _pendingInviteState = PendingInviteState.error;
    if (notify) notifyListeners();
  }

  /// Bearer 토큰과 저장된 의도를 종료하되, 랜딩 페이지에서 미리 보기를 사용할 수
  /// 없는 이유를 설명할 만큼 토큰 없는 최종 오류를 유지한다. 경로를 닫아도 이후
  /// 재시도에서 만료된 토큰을 실수로 조회하지 않는다.
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
      // 복원이 완료되기 전이라도 명시적 취소/로그아웃은 개인정보 보호 차단선이다.
      // 세대를 높여 느린 영구 저장소 읽기가 방금 지운 의도를 다시 채우지 못하게 하고,
      // 무동작 알림을 보내지 않은 채 오래된 레코드를 가능한 범위에서 지운다.
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
        // 저장은 가능한 범위에서 시도하며, 현재 컨트롤러 상태는 계속 유효하다.
      }
    });
  }

  void _queuePendingStoreClear() {
    _pendingStoreQueue = _pendingStoreQueue.then((_) async {
      try {
        await _pendingInviteStore.clear();
      } catch (_) {
        // 가능한 범위에서 처리하며 의도적으로 알리지 않는다.
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
    // 의도적으로 시작한 새 OAuth 요청이므로, 이전에 시간 초과된 실행의 툼스톤을
    // 상속하지 않고 새로운 콜백 스트림을 소유한다.
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
        // 실행 실패/시간 초과 후 공급자 콜백이 도착할 수 있다. 이후 명시적 인증
        // 작업이 신원을 커밋할 때까지 해당 콜백을 차단한다.
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
        // 이전 OAuth 실행이 오래된 소셜 차단선을 남겼더라도 새 명시적 이메일 확인
        // 흐름이 대기 중인 주소를 소유한다. 아래의 주소 일치 검사는 관계없는 콜백을
        // 계속 거부한다.
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
    // 연속된 명시적 로그아웃과 새 인증 요청을 직렬화한다. 첫 호출이 SDK 폐기를
    // 소유하며, 두 번째 호출은 해당 소유권이 정리될 때까지 기다린 뒤 새 작업 토큰을
    // 가져간다.
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
    // 기존의 오래된 소셜 툼스톤은 활성 상태로 유지하되 이전에 커밋한 신원은 잊는다.
    // 로그아웃 후 해당 계정의 콜백을 새 세션으로 받아들여서는 안 된다.
    _staleSocialExpectedIdentity = null;
    _queuedPasswordRecoveryIdentity = null;
    _staleSocialIdentityCommitted = false;
    _staleSocialPendingMismatchObserved = false;
    // 명시적 로그아웃은 초대 의도에 대한 최종 개인정보 보호 경계다.
    _clearPendingInvite();
    try {
      // 느릴 수 있는 원격 폐기를 기다리기 전에 로컬 상태를 지운다. 지우기 도우미는
      // 첫 `await` 전에 동기적으로 상태를 변경한다.
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
      // 저장소를 테스트 대역으로 교체해도 로그아웃 실패에는 공급자/서버 세부 정보가
      // 포함될 수 있다. UI와 다시 던지는 예외에 동일하고 안정적인 사용자 안전 세션
      // 메시지를 사용한다.
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
    // 인증 요청은 플래너 리비전과 별도의 세대를 사용한다. 인증 요청이 인증 진행
    // 표시를 계속 소유하는 동안 그룹 새로 고침이 [_operationToken]을 높일 수 있다.
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
      // 새 명시적 비밀번호/복구 작업이 최종 결과를 소유해야 한다. 이 요청이 대기
      // 중일 때 이전에 시간 초과된 콜백이 기존 계정과 일치하지 못하게 한다.
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
    // 명시적 비밀번호/복구 결과가 새 소유자다. 이전에 시간 초과된 소셜 실행에서
    // 기록한 신원을 교체할 수 있다.
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
    // 공급자 이벤트가 아니라 직접 비밀번호 작업이 결과를 소유한다. 해당 작업이
    // 사용자를 반환할 때까지 콜백을 억제한다. 대기 중인 주소가 확인되어 일치하면
    // 이메일 확인을 허용한다. 예상 신원보다 이 예외를 먼저 검사하여 이전 로그인
    // 후 새 가입이 의도적으로 다른 계정을 설정할 수 있게 한다.
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
    // 동기 알림을 보내기 전에 게이트를 게시하여 즉시 인증을 다시 시도하는 리스너와
    // 원격 폐기 사이에 경쟁 상태가 생기지 않게 한다.
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
    // SDK 세션을 폐기하기 전에 비공개 플래너 상태를 동기적으로 지운다. 폐기 자체는
    // 가능한 범위에서 시도하며, 결과와 관계없이 로그아웃된 개인정보 보호 컨트롤러
    // 상태를 유지한다.
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
        // 위에서 설정한 안전한 로그아웃 상태를 유지하면서 공급자/서버 세부 정보를
        // 절대 노출하지 않는다.
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
    // 오래된 비밀번호 요청이 로그아웃 후에도 Supabase 세션을 만들 수 있다. 늦게
    // 완료된 요청을 예기치 않은 신원 이벤트처럼 취급하고 공급자 오류를 노출하지
    // 않은 채 폐기한다.
    _failClosedForFencedIdentity(showError: false);
  }

  Future<void> _awaitFencedIdentityRevocation() async {
    final pending = _fencedIdentityRevocation;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      // 폐기 실패는 위의 안전한 세션 오류로 이미 표현된다. 인증 작업은 폐기 시도가
      // 끝난 뒤에만 다시 시도할 수 있다.
    }
  }

  Future<void> _awaitSignOutSettlement() async {
    final pending = _signOutSettlement;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      // 명시적 로그아웃 호출자는 자체 안전 오류를 표시한다. 대기 중인 인증 작업은
      // 폐기 시도가 끝난 뒤에만 진행할 수 있다.
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
    _runNotificationSideEffect(
      (notifications) => notifications.onAuthenticated(authenticated.id),
    );
    await loadGroups();
  }

  void _assertAuthResultSessionConsistency(PlannerUser authenticated) {
    if (!_staleSocialPendingMismatchObserved) return;
    final sdkUser = _auth.currentUser;
    if (sdkUser != null && sdkUser.id != authenticated.id) {
      // 이 명시적 인증 작업이 대기 중일 때 공급자 콜백이 SDK 세션을 변경했다. 콜백
      // 요청 ID가 없으므로 어느 계정을 받아들여도 컨트롤러와 Supabase가 서로 다른
      // JWT를 사용하게 된다. 대신 둘 다 폐기하고 안전하게 차단한다.
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

  bool _isOperationGenerationCurrent(
    int generation, {
    required String? userId,
    String? groupId,
  }) {
    if (_disposed || _operationGeneration != generation) return false;
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
      // 사용자가 로그아웃된 탭에서 초대를 여는 동안 Supabase가 초기 주변
      // SIGNED_OUT 이벤트를 내보낼 수 있다. 대기 중인 의도를 유지한다. 명시적
      // 로그아웃이나 커밋된 것으로 확인된 신원만 개인정보 보호 차단선이다.
      if (user != null || _signOutOperationToken != null) {
        _clearPendingInvite();
      }
      // 현재 표시되는 신원이 없어도 로그아웃 상태는 동기 차단선이다. 지연된 콜백을
      // 검사하기 전에 소셜 툼스톤 뒤에서 이전에 커밋한 모든 신원을 잊는다.
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
      // 콜백 요청 ID가 없으므로 새 명시적 비밀번호 작업이 대기 중일 때는 이미
      // 커밋된 신원을 유지하는 편이 더 안전하다. 어떤 작업도 세션을 소유하지 않게
      // 되면 SDK와 컨트롤러가 서로 다른 계정에 남지 않도록 안전하게 차단한다.
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
      // 공급자 콜백이 이미 대기열에 들어갔다면 명시적 로그아웃 후에도 인증 이벤트가
      // 전달될 수 있다. 플래너 상태를 지우면서 SDK 세션도 폐기한다. 로그아웃 UI만
      // 유지하면 SDK가 다른 계정에 남게 된다.
      _failClosedForFencedIdentity();
      return;
    }
    final expectedId = _queuedAuthIdentity ?? user?.id;
    // 컨트롤러에 이미 사용자가 없어도 SIGNED_OUT은 차단선이다. 진행 중인 비밀번호
    // 요청이 나중에 사용자를 반환하며 완료될 수 있다.
    final identityChanged = event.type == AuthEventType.signedOut
        ? true
        : incomingId != null && incomingId != expectedId;
    if (identityChanged) {
      final preserveSignOutOperation =
          event.type == AuthEventType.signedOut &&
          _signOutOperationToken == _operationToken;
      // 확인된 신원 사이의 전환은 동기 개인정보 보호 경계다. 대기 중인 플래너 지우기
      // 전에 Bearer 의도를 지워, 인증 이벤트가 이전 작업 뒤에서 기다리는 동안
      // 호출자가 기존 토큰을 보지 못하게 한다. 로그아웃 상태에서 포착한 뒤 첫 로그인
      // 이벤트는 의도적으로 의도를 유지하고 아래 대기열 처리기에서 연결한다. 주변
      // SIGNED_OUT 이벤트도 마찬가지로 의도를 유지한다.
      if (event.type != AuthEventType.signedOut &&
          (user != null || _queuedAuthIdentity != null)) {
        _clearPendingInvite();
      }
      _queuedAuthIdentity = incomingId;
      ++_authEventGeneration;
      if (event.type == AuthEventType.signedOut) {
        _ignoreExternalIdentityEvents = true;
      }
      // 로그아웃/새 신원 이벤트는 대기 중인 인증 요청을 대체한다. 명시적 로그인
      // 작업이 자체적으로 완료될 때까지 해당 진행 표시를 유지한다. 작업 세대는
      // 개인정보 지우기로 바뀐 플래너 리비전과 계속 독립되어 있다.
      if (event.type == AuthEventType.signedOut ||
          !_authStateChangingOperationInFlight) {
        _invalidateAuthOperations();
      }
      final preserveSaving =
          _authOperationToken != 0 || _socialAuthProviderInFlight != null;
      // 대기열 처리기가 이전 인증 이벤트나 그룹 요청을 기다리기 전에 무효화하고
      // 지운다.
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
    // 테스트 대역이 우연히 같은 사용자 ID로 다시 로그인하더라도 신원/개인정보를
    // 완전히 지우면 새 플래너 세션을 시작한다. 최종 그룹 변경은 이 세대를 캡처하며,
    // 기존 네트워크 Future가 뒤늦게 완료되더라도 새 세션을 변경해서는 안 된다.
    _plannerSessionGeneration++;
    _plannerRevision++;
    // 알림 상태에는 자체 직렬화된 개인정보 보호 경계가 있다. 플래너 신원을 지우기
    // 전에 로그아웃 취소를 대기열에 넣어 계정 전환 중 오래된 계정이 로컬 알림을
    // 유지하지 못하게 한다.
    _runNotificationSideEffect((notifications) => notifications.onSignedOut());
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
    _resetSearchState();
    selectedEventRange = null;
    events = const <PlannerEvent>[];
    members = const <PlannerMember>[];
    invites = const <InviteCode>[];
    isOffline = false;
    selectedMemberId = null;
    showAllMembers = true;
    isLoading = false;
    if (clearSaving) isSaving = false;
    // 신원 변경은 개인정보에 민감하다. 스트림 취소를 기다리기 전에 알림을 보내
    // 기존 플래너 위젯이 동기적으로 사라지게 한다.
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
      // 스트림 취소 실패보다 비공개 상태를 지우는 것이 더 중요하다. 스트림 콜백은
      // 여전히 리비전으로 보호된다.
    }
    try {
      await invalidationSubscription?.cancel();
    } catch (_) {
      // 개인정보를 지울 때 무효화 취소는 가능한 범위에서 시도한다.
    }
    try {
      await lifecycleSubscription?.cancel();
    } catch (_) {
      // 개인정보를 지울 때 수명 주기 취소는 가능한 범위에서 시도한다.
    }
  }

  bool get _hasGroupScopedData {
    return selectedGroup != null ||
        members.isNotEmpty ||
        invites.isNotEmpty ||
        events.isNotEmpty ||
        searchResults.isNotEmpty ||
        searchRange != null ||
        searchQuery.isNotEmpty ||
        _eventSubscription != null ||
        _eventInvalidationSubscription != null ||
        _groupLifecycleSubscription != null;
  }

  Future<void> _clearGroupScopedData() async {
    _inviteOperation++;
    _inviteCodeInFlight = false;
    _cancelGroupMetadataRefresh();
    _resetRangeState();
    _resetSearchState();
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
      // 오래된 구독이 비공개 데이터를 계속 유지할 수 없다. 해당 콜백은 작업
      // 리비전으로 보호된다.
    }
    try {
      await invalidationSubscription?.cancel();
    } catch (_) {
      // 그룹을 지울 때 무효화 취소는 가능한 범위에서 시도한다.
    }
    try {
      await lifecycleSubscription?.cancel();
    } catch (_) {
      // 수명 주기 스트림이 선택 그룹 무효화를 막을 수 없다.
    }
  }

  /// 스트림 취소를 기다리기 전에 표시 목록에서 [groupId]를 원자적으로 제거하고 모든
  /// 선택 그룹 콜백을 무효화한다. 반환된 Future는 가능한 범위에서 수행하는 구독
  /// 정리만 나타낸다. 이후 다시 불러오기에 실패해도 호출자가 제거한 그룹을 복원하면
  /// 안 된다.
  Future<void> _invalidateGroupScopedData({String? removeGroupId}) {
    // 사용자가 이미 다른 그룹으로 전환한 뒤 오래된 나가기/보관 완료가 도착할 수
    // 있다. 이때 목록에서 최종 상태의 행은 제거하되 새 그룹의 선택/캐시는 지우지
    // 않는다. 선택된 그룹이나 ID 없는 개인정보 지우기는 계속 전체 무효화 경로를
    // 사용한다.
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
    _resetSearchState();
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
    // 이전 가짜 구현은 요청자 범위 스트림보다 먼저 만들어졌다. 범위 없는 읽기 경로는
    // 릴리스가 아닌 테스트/개발 빌드에서만 유지한다. 프로덕션 어댑터는
    // UserScopedEventReadCapability를 구현하므로 이 대체 경로에 도달하지 않는다.
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
    // 저장소 수명 주기 읽기는 요청자/그룹 범위지만 잘못된 어댑터 응답에도 컨트롤러가
    // 안전하게 차단되도록 한다. 다른 그룹의 행이 현재 선택 그룹을 대체해서는 안 된다.
    if (incoming != null && incoming.id != groupId) return;
    if (incoming == null || incoming.isArchived) {
      // 상태를 지우기 전에 기다리지 않는다. 원격 보관/null 이벤트는 그룹의 비공개
      // 데이터를 즉시 숨기고 콜백을 무효화해야 한다.
      _runNotificationSideEffect(
        (notifications) => notifications.cancelForGroup(groupId),
      );
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
    // 수명 주기 업데이트에는 원격 이전 후처럼 소유자/버전 변경도 포함될 수 있다.
    // 바로 위에서 갱신한 그룹 객체는 유지하면서 멤버와 초대 프로젝션을 새로 고쳐,
    // 수정/이전 동작에 오래된 역할이 남지 않게 한다.
    _scheduleGroupScopedMetadataRefresh(
      operation: operation,
      userId: userId,
      groupId: groupId,
    );
  }

  /// 짧은 시간에 몰린 멤버십/그룹 수명 주기 알림을 디바운스하여 한 번의 완전한
  /// 멤버/초대 프로젝션 읽기로 합친다. 읽기가 진행 중일 때 두 번째 신호가 오면
  /// 유지했다가 읽기 후 다시 시도하므로 이전 응답이 최종 구성원 스냅샷이 될 수 없다.
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
        // 진행 중인 읽기의 `finally` 블록이 가장 최근 대기 요청을 위해 타이머를 다시
        // 설정한다. 그때까지 해당 요청을 그대로 유지한다.
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
        // membersForGroup/inviteCodesForGroup가 대기 중일 때 신호가 도착했을 수 있다.
        // 가장 새로운 작업 컨텍스트를 잃지 않고 다시 예약한다.
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
      // 보조 프로필 프로젝션을 일시적으로 사용할 수 없어도 Realtime 그룹 메타데이터는
      // 계속 사용할 수 있다.
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
      // 초대 행은 소유자 범위이므로 멤버가 정상적으로 접근하지 못할 수 있다. 이때는
      // 마지막으로 표시된 값을 유지한다.
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
    // 충돌이 소유한 새로 고침은 네트워크 읽기가 대기 중일 때 새 작업의 진단 정보를
    // 지우면 안 된다. 새로 고침이 끝난 뒤에도 이 세대가 컨텍스트를 소유할 때만
    // 호출자가 원래 충돌 메시지를 복원한다.
    if (!preserveOperationGeneration) errorMessage = null;
    notifyListeners();
    try {
      // 이 요청을 시작한 사용자와 선택이 여전히 현재 상태인지 확인할 때까지 응답을
      // 보류한다. 로그아웃이나 더 새로운 새로 고침이 우선해야 한다.
      final fetchedGroups = (await _repository.groupsForUser(current.id))
          .where((group) => !_terminalGroupTombstones.contains(group.id))
          .toList(growable: false);
      if (!_isCurrentPlannerContext(
            operation,
            userId: current.id,
            selectedGroupId: selectedGroupId,
          ) ||
          (preserveOperationGeneration &&
              _operationGeneration != operationGeneration)) {
        return;
      }
      groups = List<PlannerGroup>.unmodifiable(fetchedGroups);
      isOffline = false;

      if (selectedGroupId != null) {
        final refreshedSelection = fetchedGroups
            .where((group) => group.id == selectedGroupId)
            .firstOrNull;
        if (refreshedSelection == null) {
          // 멤버십이 제거되었거나 그룹이 삭제되었다. 이전 선택이나 해당 일정/멤버에
          // 접근할 수 있는 상태로 두지 않는다.
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
        // selectedGroup을 직접 지운 호출자를 위한 방어 처리다. 선택 없이 새로 고칠
        // 때 고립된 캐시를 유지해서는 안 된다.
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
      // 나가기/보관 완료로 이미 이 그룹을 무효화했다. 최종 작업이 끝날 때까지 오래된
      // 탭 동작과 늦은 목록 콜백을 무시한다.
      return;
    }
    final group = groups
        .where((candidate) => candidate.id == groupId)
        .firstOrNull;
    // 목록을 탭한 시점과 이 콜백 사이에 최종 변경 또는 원격 보관이 행을 제거할 수
    // 있다. 이 오래된 선택은 `firstWhere`에서 예외를 던져 캐시 데이터를 되살리는
    // 대신 무동작으로 처리한다.
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
    _resetSearchState();
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
        // 취소된 스트림이 새 선택을 막게 두지 않는다.
      }
      try {
        await previousInvalidationSubscription?.cancel();
      } catch (_) {
        // 오래된 무효화 스트림이 새 선택을 막게 두지 않는다.
      }
      try {
        await previousLifecycleSubscription?.cancel();
      } catch (_) {
        // 오래된 수명 주기 스트림이 새 선택을 막게 두지 않는다.
      }
      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: group.id,
      )) {
        return;
      }

      // 일정 및 수명 주기 스트림은 개인정보 보호/가용성에 중요하다. 아래의 보조
      // 멤버/초대 읽기보다 둘을 먼저 시작한다. 이러한 읽기가 느리거나 대기 중이어도
      // 원격 보관/비활성화가 선택 그룹을 즉시 지워야 할 수 있다.
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
            // 오래된 스트림이 새 선택이나 개인정보 지우기를 막을 수 없다. 해당 콜백은
            // 작업 컨텍스트로 계속 보호된다.
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
              isOffline = true;
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
          // 어느 REST 읽기가 대기 중이더라도 수명 주기 툼스톤이 취소할 수 있도록
          // 메타데이터를 기다리기 전에 구독을 게시한다.
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
              streamFailed = true;
              isOffline = true;
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
          // 일정과 마찬가지로 메타데이터 읽기 전에 이를 게시한다. 리스너가 툼스톤을
          // 동기적으로 보고하면 아래 컨텍스트 검사가 오래된 구독이 유지되는 일을 막는다.
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
    // 기존 기본 시간대에 대한 세 개의 위치 인자 계약을 유지한다. 이를 통해 이전
    // 테스트 대역이 제어하는 Future를 실수로 우회하지 않고 createGroup을 재정의할
    // 수도 있다.
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

  /// 낙관적 잠금을 사용해 선택 그룹의 변경 가능한 메타데이터를 수정한다. 양식이
  /// 초안 값을 소유하므로 충돌 시 화면의 값을 그대로 둔 채 최신 그룹을 새로 고친다.
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

  /// 더 짧은 수정 용어를 사용하는 화면을 위한 위치 인자 별칭이다.
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

  /// 사전 검사/수정 흐름에 유용한 명시적 버전 별칭이다. 행위자는 항상 인증된
  /// 컨트롤러 사용자다. 호출자가 제공한 행위자는 호환성 검사 용도로만 허용하며
  /// 인증에는 절대 신뢰하지 않는다.
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
      // 메타데이터를 수정하면 멤버, 초대 및 실시간 일정도 새로 고친다. 변경된
      // 시간대가 캘린더 경계를 즉시 갱신하도록 보장한다.
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

  /// 인증된 멤버로서 선택 그룹에서 나간다. 저장소는 소유자의 나가기를 거부하며,
  /// 소유권 이전은 의도적으로 별도 작업으로 둔다.
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
      // 최종 변경을 커밋한 세션만 해당 계정의 네이티브 알림을 제거할 수 있다. 이 RPC가
      // 진행 중일 때 A -> B 전환이 완료되었다면 B의 네임스페이스를 취소해서는 안 된다.
      // 필요한 기존 계정 정리는 B 자체의 인증 차단선이 수행한다.
      _runNotificationSideEffect(
        (notifications) => notifications.cancelForGroup(groupId),
      );
      // 다시 불러오기/취소를 기다리기 전에 동기적으로 무효화한다. 네트워크 재조회에
      // 실패해도 나간 그룹이 되살아나면 안 된다. 다른 선택/인증 작업 때문에 원래
      // 나가기 콜백이 오래된 경우에도 의도적으로 수행한다. 최종 변경은 표시 목록에서
      // 해당 그룹 행을 계속 제거해야 한다.
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

  /// 활성 멤버에게 소유권을 이전하고 그룹 범위 데이터를 모두 다시 불러와 멤버 역할과
  /// 초대 표시 여부를 즉시 일관되게 만든다.
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

  /// 선택 그룹을 보관한다. 이 작업은 저장소에서 최종 상태이며, 그룹 목록을 새로
  /// 고치기 전에 로컬 구독과 캐시를 지운다.
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
      // leaveGroup의 세션 차단선과 맞춘다. A -> B 전환 후에도 이전 계정의 최종 RPC가
      // 완료될 수 있지만 B의 네이티브 집합을 제거해서는 안 된다.
      _runNotificationSideEffect(
        (notifications) => notifications.cancelForGroup(groupId),
      );
      // 스트림 취소나 네트워크 재조회를 기다리기 전에 보관된 그룹을 제거한다. 이 최종
      // 무효화는 재조회 실패 후에도 유지되며, 동시 그룹 전환으로 이 콜백이 오래되어도
      // 적용된다.
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
    // 충돌이 소유한 새로 고침에 세대 표시를 유지한다. 새로 고침 자체가 플래너
    // 리비전/토큰을 높이지만 이 후속 작업에서 이후 작업이 오래된 것처럼 보이게 하면
    // 안 된다. 모든 외부/새 작업은 표시 값을 높이고 오류 상태의 우선권을 갖는다.
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
      // 참여는 이전에 나간 그룹을 다시 표시할 수 있는 유일한 명시적 경로다. 오래된
      // 참여 완료가 다른 세션의 데이터를 되살리지 못하도록 작업/컨텍스트 가드 뒤에서만
      // 수행한다.
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
        // 생성 RPC가 대기 중일 때 인증/그룹 컨텍스트가 바뀐 호출자에게 평문 토큰을
        // 반환하지 않는다.
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

  /// 일정 본문 쓰기/삭제는 계속 작성자만 할 수 있다. 그룹 소유자에게는 별도의 참여자
  /// 목록 기능을 제공하며, 그룹을 관리할 수 있다는 이유만으로 본문 수정 권한이
  /// 생겨서는 안 된다.
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

  /// 현재 제한된 캘린더 페이지 밖에 있을 수 있는 상세 경로 일정을 불러온다. 페이지
  /// 커서나 선택 범위 프로젝션에 영향을 주지 않도록 결과를 의도적으로 [events]에
  /// 넣지 않으며, 반환된 상세 스냅샷은 편집기가 소유한다. 로그아웃, 신원 변경 또는
  /// 그룹 전환 후 늦게 도착한 응답은 노출하지 않고 버린다.
  Future<PlannerEvent?> loadEventById(
    String eventId, {
    String occurrenceKey = 'single',
  }) async {
    final current = user;
    final group = selectedGroup;
    if (current == null || group == null) return null;
    if (eventId.trim().isEmpty || eventId != eventId.trim()) {
      throw const ScheduleValidationException('일정 식별자를 확인해 주세요.');
    }
    if (!isValidOccurrenceKey(occurrenceKey)) {
      throw const ScheduleValidationException('반복 일정 식별자를 확인해 주세요.');
    }
    final inProjection = events
        .where(
          (event) =>
              event.id == eventId &&
              event.occurrenceKey == occurrenceKey &&
              // 이전 스트림이 실수로 `single` 키를 붙여 노출하더라도 반복 기준 일정은
              // 상세 발생 항목이 아니다.
              (occurrenceKey != 'single' || event.recurrenceRule == null) &&
              !event.isDeleted,
        )
        .firstOrNull;
    if (inProjection != null) return inProjection;
    final repository = _repository;
    if (occurrenceKey != 'single') {
      if (!supportsEventOccurrenceByKey) return null;
      final occurrenceCapability = _repository;
      if (occurrenceCapability is! EventOccurrenceReadCapability) return null;
      final capability = occurrenceCapability as EventOccurrenceReadCapability;
      final revision = _plannerRevision;
      final sessionGeneration = _plannerSessionGeneration;
      final userId = current.id;
      final groupId = group.id;
      final event = await capability.eventOccurrenceByKey(
        userId: userId,
        groupId: groupId,
        eventId: eventId,
        occurrenceKey: occurrenceKey,
      );
      if (_disposed ||
          _plannerRevision != revision ||
          _plannerSessionGeneration != sessionGeneration ||
          user?.id != userId ||
          selectedGroup?.id != groupId) {
        return null;
      }
      if (event == null || event.isDeleted) return null;
      if (event.id != eventId ||
          event.groupId != groupId ||
          event.occurrenceKey != occurrenceKey) {
        throw const ScheduleConflictException('일정 응답을 확인할 수 없습니다.');
      }
      return event;
    }
    // 기본 상세 키는 이전 딥 링크에서도 사용된다. 반복 기준점은 구체화된 발생 항목
    // 기능을 통해 해석해야 한다. 원격 단건 RPC는 `single`을 순번 0의 별칭으로
    // 처리한다. 이전 상위 행 읽기로 대체하면 수정할 수 없는 시리즈 기준을 노출하고
    // 편집기가 잘못된 식별자를 변경할 수 있다. 이 기능을 사용하지 않는 이전 테스트
    // 대역은 아래 EventById 경로를 유지한다.
    if (supportsEventOccurrenceByKey) {
      final occurrenceCapability = repository as EventOccurrenceReadCapability;
      final revision = _plannerRevision;
      final sessionGeneration = _plannerSessionGeneration;
      final userId = current.id;
      final groupId = group.id;
      final event = await occurrenceCapability.eventOccurrenceByKey(
        userId: userId,
        groupId: groupId,
        eventId: eventId,
        occurrenceKey: occurrenceKey,
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
      if (event.occurrenceKey != 'single' &&
          event.occurrenceKey != occurrenceKeyForIndex(0)) {
        throw const ScheduleConflictException('일정 응답을 확인할 수 없습니다.');
      }
      return event;
    }
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
      _runNotificationSideEffect(
        (notifications) => notifications.onMembershipChanged(groupId: groupId),
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
    _releaseQueuedRangeRefreshWaiters();
    _rangeRefreshInFlight = false;
    _rangeRefreshOwnerGeneration = null;
    _rangeLoadMoreInFlight = false;
    _rangeLoadMoreOwnerGeneration = null;
    if (clearRange) selectedEventRange = null;
  }

  void _releaseQueuedRangeRefreshWaiters() {
    _rangeRefreshQueued = false;
    _rangeQueuedRefreshCompleter = null;
    final waiters = _rangeRefreshAwaiters.toList(growable: false);
    _rangeRefreshAwaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _resetSearchState({bool clearQuery = true}) {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchInvalidationTimer?.cancel();
    _searchInvalidationTimer = null;
    _searchGeneration++;
    _searchActive = false;
    _searchKey = null;
    hasMoreSearchResults = false;
    isSearching = false;
    isLoadingMoreSearch = false;
    searchError = null;
    _searchRefreshQueued = false;
    _searchRefreshInFlight = false;
    _searchRefreshOwnerGeneration = null;
    _searchLoadMoreInFlight = false;
    _searchLoadMoreOwnerGeneration = null;
    searchCursor = null;
    searchResults = const <PlannerEvent>[];
    if (clearQuery) {
      searchQuery = '';
      searchRange = null;
      searchCreatorId = null;
      searchParticipantId = null;
    }
  }

  String _searchIdentity(
    EventRange range,
    String query,
    String? creatorId,
    String? participantId,
  ) {
    return '${range.viewTimezone}|${range.startUtc.toIso8601String()}|'
        '${range.endUtc.toIso8601String()}|$query|'
        '${creatorId ?? ''}|${participantId ?? ''}';
  }

  bool _isCurrentSearchContext({
    required int plannerRevision,
    required int sessionGeneration,
    required int searchGeneration,
    required String userId,
    required String groupId,
    required EventRange range,
    required String searchKey,
  }) {
    String? currentKey;
    try {
      currentKey = _searchIdentity(
        range,
        normalizeEventSearchQuery(searchQuery),
        searchCreatorId,
        searchParticipantId,
      );
    } on FormatException {
      currentKey = null;
    }
    return !_disposed &&
        _plannerRevision == plannerRevision &&
        _plannerSessionGeneration == sessionGeneration &&
        _searchGeneration == searchGeneration &&
        user?.id == userId &&
        selectedGroup?.id == groupId &&
        searchRange == range &&
        _searchKey == searchKey &&
        currentKey == searchKey;
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
      // 월간 및 일정 목록 셀은 가져온 범위를 유지하면서 선택한 날짜를 바꿀 수 있다.
      // 같은 페이지를 비운 뒤 다시 불러오지 말고 현재 스냅샷을 유지한다. 명시적
      // 재검증이 필요하면 호출자가 공개 새로 고침 메서드를 사용할 수 있다.
      notifyListeners();
      return;
    }
    _rangeInvalidationTimer?.cancel();
    _rangeInvalidationTimer = null;
    _rangeGeneration++;
    // 새 범위는 진행 중인 첫 페이지/추가 조회 요청을 모두 대체한다. 이전 Future는
    // 캡처한 세대를 유지하므로 이 새 요청이 소유한 플래그를 지우거나 덮어쓸 수 없다.
    _releaseQueuedRangeRefreshWaiters();
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
    _scheduleSearchInvalidation(
      operation: operation,
      userId: userId,
      groupId: groupId,
    );
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

  void _scheduleSearchInvalidation({
    required int operation,
    required String userId,
    required String groupId,
  }) {
    if (!_isCurrentPlannerContext(
          operation,
          userId: userId,
          groupId: groupId,
        ) ||
        searchRange == null ||
        (_repository is! EventSearchCapability)) {
      return;
    }
    _searchInvalidationTimer?.cancel();
    _searchInvalidationTimer = Timer(const Duration(milliseconds: 80), () {
      _searchInvalidationTimer = null;
      if (!_isCurrentPlannerContext(
        operation,
        userId: userId,
        groupId: groupId,
      )) {
        return;
      }
      unawaited(refreshSearch(force: true));
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
    selectedDay = CalendarDateBounds.clamp(day);
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
      // 이전 어댑터는 제한된 페이지를 노출하지 않지만 홈 화면의 RefreshIndicator는
      // 해당 선택 그룹 스트림을 계속 새로 고쳐야 한다. 확립된 groups/selectGroup
      // 수명 주기를 거쳐 이전 감시자를 취소하고 같은 인증 가드로 다시 시작한다.
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
      final completion = _rangeQueuedRefreshCompleter ??= Completer<void>();
      _rangeRefreshAwaiters.add(completion);
      await completion.future;
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
        // 성공적으로 확인된 권한 거부는 서버 기준 결과다. 멤버십/그룹을 사용할 수
        // 없어진 뒤 이전 그룹 범위 스냅샷을 유지하면 비공개 행이 노출된다. 전송/파싱
        // 실패는 이와 다르므로 강제 재검증 중에도 의도적으로 마지막 정상 스냅샷을
        // 유지한다.
        if (!preserveCurrentEvents || _isAuthoritativeRangeDenial(error)) {
          events = const <PlannerEvent>[];
          _rangeCursor = null;
          hasMoreEvents = false;
        }
        notifyListeners();
      }
    } finally {
      final ownsRangeRefresh = _rangeRefreshOwnerGeneration == rangeGeneration;
      if (ownsRangeRefresh) {
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
      if (ownsRangeRefresh && _rangeRefreshQueued) {
        _rangeRefreshQueued = false;
        final completion = _rangeQueuedRefreshCompleter;
        _rangeQueuedRefreshCompleter = null;
        try {
          if (!_disposed &&
              _isCurrentRangeContext(
                plannerRevision: _plannerRevision,
                sessionGeneration: _plannerSessionGeneration,
                rangeGeneration: _rangeGeneration,
                userId: current.id,
                groupId: group.id,
                range: range,
                rangeKey: _rangeKey ?? rangeKey,
              )) {
            await _fetchRangeFirstPage(
              force: true,
              preserveCurrentEvents: true,
              advanceGeneration: true,
            );
          }
        } finally {
          if (completion != null) {
            _rangeRefreshAwaiters.remove(completion);
            if (!completion.isCompleted) completion.complete();
          }
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
      // 상위 무효화는 이미 가져오는 중인 페이지에도 있는 일정을 삽입할 수 있다.
      // 동일한 불변 페이로드는 안전한 멱등 중복이다. 같은 ID의 페이로드에서 필드가
      // 하나라도 바뀌었다면 충돌 응답이므로 안전하게 차단해야 한다.
      for (final event in page.events) {
        final previous = events
            .where((item) => item.identityKey == event.identityKey)
            .firstOrNull;
        if (previous != null && previous != event) {
          throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
        }
      }
      final merged = <String, PlannerEvent>{
        for (final event in events) event.identityKey: event,
      };
      for (final event in page.events) {
        final previous = merged[event.identityKey];
        if (previous == null || previous.version <= event.version) {
          merged[event.identityKey] = event;
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

  /// 현재 선택 그룹이 검색 프로젝션을 소유하는지 나타낸다. 호출자가 기간 및/또는
  /// 멤버 필터만으로 의도적으로 검색할 때는 검색어가 비어 있을 수 있다.
  bool get hasActiveSearch => _searchActive;

  /// 검색어를 갱신하고 디바운스된 검색을 예약한다. 잘못된 비어 있지 않은 검색어는
  /// 로컬에서 거부하며 저장소/RPC에 전달하지 않는다.
  void setSearchQuery(String query) {
    unawaited(searchEvents(query: query));
  }

  /// 선택적 기간/작성자/참여자 필터를 갱신하고 디바운스된 검색을 예약한다. `clear*`
  /// 플래그는 널 허용 필터 하나를 지우는 동작을 명시하면서 UI 호출자에게 편리한
  /// 부분 갱신을 유지한다.
  void setSearchFilters({
    EventRange? range,
    String? creatorId,
    String? participantId,
    bool clearRange = false,
    bool clearCreator = false,
    bool clearParticipant = false,
  }) {
    if (range != null || clearRange) searchRange = range;
    if (creatorId != null || clearCreator) {
      searchCreatorId = creatorId?.trim();
    }
    if (participantId != null || clearParticipant) {
      searchParticipantId = participantId?.trim();
    }
    unawaited(searchEvents());
  }

  /// 제공된 검색 입력을 적용하고 즉시 시작하거나 설정된 디바운스 간격만큼 기다린다.
  /// 반환된 Future는 즉시 요청이 완료되면 끝난다. 디바운스된 호출은 요청을 예약한
  /// 뒤 반환하여 텍스트 필드 갱신을 비차단 상태로 유지한다.
  Future<void> searchEvents({
    String? query,
    EventRange? range,
    String? creatorId,
    String? participantId,
    bool immediate = false,
  }) async {
    if (query != null) searchQuery = query.trim();
    if (range != null) searchRange = range;
    if (creatorId != null) searchCreatorId = creatorId.trim();
    if (participantId != null) searchParticipantId = participantId.trim();
    _searchActive = true;
    try {
      searchQuery = normalizeEventSearchQuery(searchQuery);
      if (searchCreatorId != null && searchCreatorId!.isEmpty ||
          searchParticipantId != null && searchParticipantId!.isEmpty) {
        throw const FormatException('검색 멤버를 확인해 주세요.');
      }
    } catch (error) {
      _resetSearchState(clearQuery: false);
      // 초안/검색어와 검증 메시지는 필드에 계속 표시하되 프로젝션을 비활성으로
      // 표시하여 실시간 무효화가 이 검증 경계 밖에서 잘못된 검색어를 다시 시도하지
      // 못하게 한다.
      _searchActive = false;
      searchError = _friendlyError(error);
      notifyListeners();
      return;
    }
    _queueSearchRequest();
    if (!immediate) return;
    _searchTimer?.cancel();
    _searchTimer = null;
    await _fetchSearchFirstPage(
      force: true,
      preserveCurrentResults: false,
      advanceGeneration: false,
    );
  }

  /// 선택한 캘린더 범위나 페이지 구분 상태를 바꾸지 않고 현재 검색을 강제로
  /// 재검증한다.
  Future<void> refreshSearch({bool force = true}) async {
    if (!_searchActive) return;
    if (!force && searchResults.isNotEmpty) return;
    final range =
        searchRange ?? selectedEventRange ?? _rangeForCalendarSelection();
    if (range == null) return;
    searchRange ??= range;
    await _fetchSearchFirstPage(
      force: force,
      preserveCurrentResults: force,
      advanceGeneration: force,
    );
  }

  /// 대기 중인 디바운스/진행 중 소유권을 취소하고 모든 비공개 검색 상태를 지운다.
  /// Future를 강제로 중단할 수는 없지만 캡처된 세대 덕분에 늦은 성공/오류는 모두
  /// 무동작이 된다.
  void cancelSearch() {
    _resetSearchState();
    notifyListeners();
  }

  void clearSearch() => cancelSearch();

  Future<void> loadMoreSearchResults() async {
    final capability = _repository;
    final current = user;
    final group = selectedGroup;
    final range = searchRange;
    final cursor = searchCursor;
    if (capability is! EventSearchCapability ||
        current == null ||
        group == null ||
        range == null ||
        cursor == null ||
        cursor.occurrenceKey.isEmpty ||
        !hasMoreSearchResults ||
        _searchLoadMoreInFlight ||
        _searchRefreshInFlight) {
      return;
    }
    final searchCapability = capability as EventSearchCapability;
    final normalizedQuery = normalizeEventSearchQuery(searchQuery);
    final creatorId = searchCreatorId;
    final participantId = searchParticipantId;
    final plannerRevision = _plannerRevision;
    final sessionGeneration = _plannerSessionGeneration;
    final searchGeneration = _searchGeneration;
    final searchKey = _searchIdentity(
      range,
      normalizedQuery,
      creatorId,
      participantId,
    );
    _searchKey = searchKey;
    _searchLoadMoreInFlight = true;
    _searchLoadMoreOwnerGeneration = searchGeneration;
    isLoadingMoreSearch = true;
    notifyListeners();
    try {
      final page = await searchCapability.searchEvents(
        userId: current.id,
        groupId: group.id,
        range: range,
        query: normalizedQuery,
        cursor: cursor,
        limit: eventSearchDefaultPageSize,
        creatorId: creatorId,
        participantId: participantId,
      );
      if (!_isCurrentSearchContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        searchGeneration: searchGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        searchKey: searchKey,
      )) {
        return;
      }
      _validateSearchPage(
        page,
        groupId: group.id,
        range: range,
        cursor: cursor,
        query: normalizedQuery,
        creatorId: creatorId,
        participantId: participantId,
        limit: eventSearchDefaultPageSize,
      );
      for (final event in page.events) {
        final previous = searchResults
            .where((item) => item.identityKey == event.identityKey)
            .firstOrNull;
        if (previous != null && previous != event) {
          throw const ScheduleConflictException('검색 결과 응답을 확인할 수 없습니다.');
        }
      }
      final merged = <String, PlannerEvent>{
        for (final event in searchResults) event.identityKey: event,
      };
      for (final event in page.events) {
        final previous = merged[event.identityKey];
        if (previous == null || previous.version <= event.version) {
          merged[event.identityKey] = event;
        }
      }
      final ordered = merged.values.toList(growable: false)
        ..sort(_comparePlannerEvents);
      searchResults = ordered;
      searchCursor = page.nextCursor;
      hasMoreSearchResults = page.hasMore;
      searchError = null;
      notifyListeners();
    } catch (error) {
      if (_isCurrentSearchContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        searchGeneration: searchGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        searchKey: searchKey,
      )) {
        searchError = _friendlyError(error);
        if (_isAuthoritativeRangeDenial(error)) {
          searchResults = const <PlannerEvent>[];
          searchCursor = null;
          hasMoreSearchResults = false;
        }
        notifyListeners();
      }
    } finally {
      if (_searchLoadMoreOwnerGeneration == searchGeneration) {
        _searchLoadMoreInFlight = false;
        _searchLoadMoreOwnerGeneration = null;
        isLoadingMoreSearch = false;
        if (_isCurrentSearchContext(
          plannerRevision: _plannerRevision,
          sessionGeneration: _plannerSessionGeneration,
          searchGeneration: _searchGeneration,
          userId: current.id,
          groupId: group.id,
          range: range,
          searchKey: searchKey,
        )) {
          notifyListeners();
        }
        if (_searchRefreshQueued && !_disposed) {
          _searchRefreshQueued = false;
          if (_isCurrentSearchContext(
            plannerRevision: _plannerRevision,
            sessionGeneration: _plannerSessionGeneration,
            searchGeneration: _searchGeneration,
            userId: current.id,
            groupId: group.id,
            range: range,
            searchKey: _searchKey ?? searchKey,
          )) {
            unawaited(
              _fetchSearchFirstPage(
                force: true,
                preserveCurrentResults: true,
                advanceGeneration: true,
              ),
            );
          }
        }
      }
    }
  }

  Future<void> loadMoreSearch() => loadMoreSearchResults();

  void _queueSearchRequest() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _searchGeneration++;
    _searchRefreshQueued = false;
    _searchRefreshInFlight = false;
    _searchRefreshOwnerGeneration = null;
    _searchLoadMoreInFlight = false;
    _searchLoadMoreOwnerGeneration = null;
    isSearching = false;
    isLoadingMoreSearch = false;
    searchCursor = null;
    hasMoreSearchResults = false;
    searchError = null;
    searchResults = const <PlannerEvent>[];
    final range =
        searchRange ?? selectedEventRange ?? _rangeForCalendarSelection();
    if (searchRange == null && range != null) searchRange = range;
    notifyListeners();
    if (range == null || user == null || selectedGroup == null) return;
    if (_repository is! EventSearchCapability) {
      // 지원하지 않는 어댑터가 요청을 보낼 수 없으면서 활성처럼 보이는 검색
      // 프로젝션/재시도 동작을 노출하지 못하게 한다. 향후 저장소 교체를 위해 초안
      // 입력은 유지하지만, 명시적으로 다시 진입할 때까지 이 컨트롤러 인스턴스는
      // 비활성 상태다.
      _searchActive = false;
      searchError = const ScheduleCapabilityException(
        '검색을 지원하지 않는 저장소입니다.',
      ).message;
      notifyListeners();
      return;
    }
    _searchTimer = Timer(_searchDebounce, () {
      _searchTimer = null;
      if (_disposed || !_searchActive) return;
      unawaited(
        _fetchSearchFirstPage(
          force: true,
          preserveCurrentResults: false,
          advanceGeneration: false,
        ),
      );
    });
  }

  Future<void> _fetchSearchFirstPage({
    required bool force,
    required bool preserveCurrentResults,
    required bool advanceGeneration,
  }) async {
    final capability = _repository;
    final current = user;
    final group = selectedGroup;
    final range =
        searchRange ?? selectedEventRange ?? _rangeForCalendarSelection();
    if (!_searchActive ||
        capability is! EventSearchCapability ||
        current == null ||
        group == null ||
        range == null) {
      return;
    }
    final searchCapability = capability as EventSearchCapability;
    final normalizedQuery = normalizeEventSearchQuery(searchQuery);
    if (_searchRefreshInFlight || _searchLoadMoreInFlight) {
      _searchRefreshQueued = true;
      return;
    }
    if (advanceGeneration) {
      _searchGeneration++;
      _searchLoadMoreInFlight = false;
      _searchLoadMoreOwnerGeneration = null;
      isLoadingMoreSearch = false;
    }
    final plannerRevision = _plannerRevision;
    final sessionGeneration = _plannerSessionGeneration;
    final searchGeneration = _searchGeneration;
    final creatorId = searchCreatorId;
    final participantId = searchParticipantId;
    final searchKey = _searchIdentity(
      range,
      normalizedQuery,
      creatorId,
      participantId,
    );
    final previousSearchCursor = preserveCurrentResults ? searchCursor : null;
    final previousHasMoreSearchResults =
        preserveCurrentResults && hasMoreSearchResults;
    _searchKey = searchKey;
    searchRange = range;
    _searchRefreshInFlight = true;
    _searchRefreshOwnerGeneration = searchGeneration;
    searchCursor = null;
    hasMoreSearchResults = false;
    isSearching = true;
    searchError = null;
    if (!preserveCurrentResults) searchResults = const <PlannerEvent>[];
    notifyListeners();
    try {
      final page = await searchCapability.searchEvents(
        userId: current.id,
        groupId: group.id,
        range: range,
        query: normalizedQuery,
        limit: eventSearchDefaultPageSize,
        creatorId: creatorId,
        participantId: participantId,
      );
      if (!_isCurrentSearchContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        searchGeneration: searchGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        searchKey: searchKey,
      )) {
        return;
      }
      _validateSearchPage(
        page,
        groupId: group.id,
        range: range,
        cursor: null,
        query: normalizedQuery,
        creatorId: creatorId,
        participantId: participantId,
        limit: eventSearchDefaultPageSize,
      );
      searchResults = page.events;
      searchCursor = page.nextCursor;
      hasMoreSearchResults = page.hasMore;
      searchError = null;
      notifyListeners();
    } catch (error) {
      if (_isCurrentSearchContext(
        plannerRevision: plannerRevision,
        sessionGeneration: sessionGeneration,
        searchGeneration: searchGeneration,
        userId: current.id,
        groupId: group.id,
        range: range,
        searchKey: searchKey,
      )) {
        searchError = _friendlyError(error);
        final authoritative = _isAuthoritativeRangeDenial(error);
        if (!preserveCurrentResults || authoritative) {
          searchResults = const <PlannerEvent>[];
          searchCursor = null;
          hasMoreSearchResults = false;
        } else {
          // 강제 새로 고침은 첫 페이지를 가져오는 동안 연속 상태를 일시적으로 지운다.
          // 일시적 오류/검증 충돌 시 이전 페이지의 키셋을 유지하여 사용자가 새로 고침을
          // 다시 시도한 뒤에도 마지막 정상 결과를 추가로 불러올 수 있게 한다.
          searchCursor = previousSearchCursor;
          hasMoreSearchResults = previousHasMoreSearchResults;
        }
        notifyListeners();
      }
    } finally {
      if (_searchRefreshOwnerGeneration == searchGeneration) {
        _searchRefreshInFlight = false;
        _searchRefreshOwnerGeneration = null;
        isSearching = false;
        if (_isCurrentSearchContext(
          plannerRevision: _plannerRevision,
          sessionGeneration: _plannerSessionGeneration,
          searchGeneration: _searchGeneration,
          userId: current.id,
          groupId: group.id,
          range: range,
          searchKey: searchKey,
        )) {
          notifyListeners();
        }
      }
      if (_searchRefreshQueued && !_disposed) {
        _searchRefreshQueued = false;
        if (_isCurrentSearchContext(
          plannerRevision: _plannerRevision,
          sessionGeneration: _plannerSessionGeneration,
          searchGeneration: _searchGeneration,
          userId: current.id,
          groupId: group.id,
          range: range,
          searchKey: _searchKey ?? searchKey,
        )) {
          unawaited(
            _fetchSearchFirstPage(
              force: true,
              preserveCurrentResults: true,
              advanceGeneration: true,
            ),
          );
        }
      }
    }
  }

  void _validateSearchPage(
    EventRangePage page, {
    required String groupId,
    required EventRange range,
    required EventRangeCursor? cursor,
    required String query,
    required String? creatorId,
    required String? participantId,
    required int limit,
  }) {
    if (cursor != null && cursor.occurrenceKey.isEmpty) {
      throw const ScheduleConflictException('검색 결과 커서를 확인할 수 없습니다.');
    }
    _validateRangePage(
      page,
      groupId: groupId,
      range: range,
      cursor: cursor,
      participantId: participantId,
      limit: limit,
    );
    if (page.hasMore && page.events.length != limit) {
      throw const ScheduleConflictException('검색 결과 응답을 확인할 수 없습니다.');
    }
    final foldedQuery = query.toLowerCase();
    for (final event in page.events) {
      if ((creatorId != null && event.ownerId != creatorId) ||
          (foldedQuery.isNotEmpty &&
              !event.title.toLowerCase().contains(foldedQuery) &&
              !event.note.toLowerCase().contains(foldedQuery))) {
        throw const ScheduleConflictException('검색 결과 응답을 확인할 수 없습니다.');
      }
    }
    final next = page.nextCursor;
    if (next != null) {
      if (page.events.isEmpty || next.occurrenceKey.isEmpty) {
        throw const ScheduleConflictException('검색 결과 커서를 확인할 수 없습니다.');
      }
      final last = page.events.last;
      if (next.startsAtUtc != last.startAt.toUtc() ||
          next.eventId != last.id ||
          next.occurrenceKey != last.occurrenceKey) {
        throw const ScheduleConflictException('검색 결과 커서를 확인할 수 없습니다.');
      }
    }
  }

  static int _comparePlannerEvents(PlannerEvent left, PlannerEvent right) {
    final byStart = left.startAt.toUtc().compareTo(right.startAt.toUtc());
    if (byStart != 0) return byStart;
    final byId = left.id.compareTo(right.id);
    if (byId != 0) return byId;
    return left.occurrenceKey.compareTo(right.occurrenceKey);
  }

  static bool _isAfterCursor(PlannerEvent event, EventRangeCursor cursor) {
    final byStart = event.startAt.toUtc().compareTo(cursor.startsAtUtc);
    if (byStart > 0) return true;
    if (byStart < 0) return false;
    final byId = event.id.compareTo(cursor.eventId);
    if (byId > 0) return true;
    if (byId < 0 || cursor.occurrenceKey.isEmpty) return false;
    return event.occurrenceKey.compareTo(cursor.occurrenceKey) > 0;
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
          !seen.add(event.identityKey) ||
          (participantId != null && !event.memberIds.contains(participantId))) {
        throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
      }
      if (previous != null && _comparePlannerEvents(previous, event) >= 0) {
        throw const ScheduleConflictException('일정 페이지 응답을 확인할 수 없습니다.');
      }
      if (cursor != null && !_isAfterCursor(event, cursor)) {
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
          page.nextCursor!.eventId != last.id ||
          (last.occurrenceKey == 'single'
              ? !(page.nextCursor!.occurrenceKey.isEmpty ||
                    page.nextCursor!.occurrenceKey == 'single')
              : page.nextCursor!.occurrenceKey != last.occurrenceKey)) {
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

  /// 다른 클라이언트가 비활성화했더라도 멤버십 새로 고침이 현재 선택 멤버를 제거할
  /// 수 있다. 오래된 필터를 지워 비활성 신원 때문에 캘린더가 오해를 부르는 상태로
  /// 남지 않게 한다.
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
    var searchFilterCleared = false;
    final searchCreator = searchCreatorId;
    if (searchCreator != null &&
        !members.any(
          (member) => member.id == searchCreator && member.isActive,
        )) {
      searchCreatorId = null;
      searchFilterCleared = true;
    }
    final searchParticipant = searchParticipantId;
    if (searchParticipant != null &&
        !members.any(
          (member) => member.id == searchParticipant && member.isActive,
        )) {
      searchParticipantId = null;
      searchFilterCleared = true;
    }
    if (searchFilterCleared && _searchActive) {
      _queueSearchRequest();
    }
  }

  Future<EventSaveResult?> saveEvent({
    PlannerEvent? existing,
    required EventDraft draft,
    EventEditScope scope = EventEditScope.all,
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
    final operationGeneration = _operationGeneration;
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = group.id;
    String? notificationEventId = existing?.id;
    var notificationMutationCommitted = false;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      final requestedMemberIds = canonicalEventMemberIds(draft.memberIds);
      final normalizedDraft = draft.copyWith(
        memberIds: draft.hasExplicitMemberIds ? requestedMemberIds : null,
      );
      if (existing == null) {
        if (normalizedDraft.recurrence != null) {
          final recurrenceRepository = _repository;
          if (recurrenceRepository is! RecurrenceCapability) {
            throw const ScheduleCapabilityException('반복 일정을 지원하지 않는 저장소입니다.');
          }
          final capability = recurrenceRepository as RecurrenceCapability;
          final created = await capability.createRecurringEvent(
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
            return null;
          }
          final normalizedCreated = _validatedEventMutationResult(
            created,
            expectedGroupId: groupId,
            expectedOwnerId: userId,
            expectedVersion: 1,
            requestedMemberIds: normalizedDraft.hasExplicitMemberIds
                ? requestedMemberIds
                : <String>[userId],
            allowLegacyCreatorDefault: !_requiresExactEventMutationResults,
          );
          _upsertEvent(normalizedCreated);
          notificationEventId = created.id;
          notificationMutationCommitted = true;
          await refreshSelectedEventRange(force: true);
          if (!_isOperationGenerationCurrent(
            operationGeneration,
            userId: userId,
            groupId: groupId,
          )) {
            return null;
          }
          return EventSaveSnapshot(normalizedCreated);
        }
        // 기능을 지원하는 어댑터는 일정과 참여자를 원자적으로 생성한다고 보장한다.
        // 이전 어댑터는 초안에서 참여자 필드를 실제로 생략했을 때만 작성자 전용 기본
        // 일정을 만들 수 있다. 명시적인 빈 목록은 실제 미할당 값이므로 해당 기능이
        // 없는 어댑터가 조용히 작성자로 바꿀 수 없다.
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
          return null;
        }
        final normalizedCreated = _validatedEventMutationResult(
          created,
          expectedGroupId: groupId,
          expectedOwnerId: userId,
          expectedVersion: 1,
          requestedMemberIds: normalizedDraft.hasExplicitMemberIds
              ? requestedMemberIds
              : <String>[userId],
          // 기능 추가 전 어댑터가 응답에서 작성자 할당을 생략했을 때만 기존 클라이언트
          // 기본값이 필요할 수 있다. 기능을 지원하는 어댑터는 저장된 멤버 집합을
          // 정확히 반환한다고 보장하므로 응답에서 작성자가 빠졌다면 컨트롤러가
          // 로컬에서 만들어도 되는 값이 아니라 잘못된 응답이다.
          allowLegacyCreatorDefault: !_requiresExactEventMutationResults,
        );
        _upsertEvent(normalizedCreated);
        notificationEventId = created.id;
        notificationMutationCommitted = true;
        return EventSaveSnapshot(normalizedCreated);
      } else {
        if (existing.groupId != groupId || existing.isDeleted) {
          throw const ScheduleConflictException('일정을 찾을 수 없습니다.');
        }
        // 참여자 전용 쓰기는 작성자 전용 반복/본문 RPC가 아니라 할당 기능을 사용한다.
        // 그룹 소유자는 기존 본문 수정 권한 경계를 유지하면서 다른 멤버 시리즈의
        // 참여자 집합을 관리할 수 있다.
        final existingRequestedMemberIds = normalizedDraft.hasExplicitMemberIds
            ? requestedMemberIds
            : canonicalEventMemberIds(existing.memberIds);
        final membersChanged = !_sameMemberIdSet(
          existing.memberIds,
          existingRequestedMemberIds,
        );
        final memberOnlyChange =
            scope == EventEditScope.all &&
            normalizedDraft.hasExplicitMemberIds &&
            membersChanged &&
            existing.ownerId != userId &&
            (existing.recurrenceRule != null ||
                existing.occurrenceKey != 'single') &&
            _draftBodyAndRuleMatchesEvent(normalizedDraft, existing);
        if (memberOnlyChange) {
          if (!canEditEventParticipants(existing)) {
            throw const ScheduleConflictException('이 일정의 멤버를 변경할 권한이 없습니다.');
          }
          final recurringMemberChange =
              existing.recurrenceRule != null ||
              existing.occurrenceKey != 'single';
          if (recurringMemberChange) {
            _validateRecurringMemberAssignment(
              existing,
              existingRequestedMemberIds,
            );
            final recurringMemberRepository = _repository;
            if (recurringMemberRepository
                is! RecurringEventMemberAssignmentCapability) {
              throw const ScheduleCapabilityException(
                '반복 일정 멤버 지정을 지원하지 않는 저장소입니다.',
              );
            }
            final recurringAssignmentCapability =
                recurringMemberRepository
                    as RecurringEventMemberAssignmentCapability;
            final receipt = await recurringAssignmentCapability
                .replaceRecurringEventMembers(
                  event: existing,
                  memberIds: existingRequestedMemberIds,
                  expectedVersion: existing.version,
                  actorId: userId,
                );
            if (!_isOperationCurrent(
              operation,
              userId: userId,
              groupId: groupId,
              plannerRevision: revision,
            )) {
              return null;
            }
            _validateRecurringMemberReceipt(
              receipt,
              event: existing,
              expectedVersion: existing.version,
            );
            if (receipt.changed) {
              notificationMutationCommitted = true;
              await refreshSelectedEventRange(force: true);
              if (!_isOperationGenerationCurrent(
                operationGeneration,
                userId: userId,
                groupId: groupId,
              )) {
                return null;
              }
            }
            return EventSaveReceipt(receipt);
          }
          final memberRepository = _repository;
          if (memberRepository is! EventMemberAssignmentCapability) {
            throw const ScheduleCapabilityException(
              '일정 멤버 지정을 지원하지 않는 저장소입니다.',
            );
          }
          final assignmentCapability =
              memberRepository as EventMemberAssignmentCapability;
          final updated = await assignmentCapability.replaceEventMembers(
            existing.id,
            memberIds: existingRequestedMemberIds,
            expectedVersion: existing.version,
            actorId: userId,
          );
          if (!_isOperationCurrent(
            operation,
            userId: userId,
            groupId: groupId,
            plannerRevision: revision,
          )) {
            return null;
          }
          final normalizedUpdated = _validatedEventMutationResult(
            updated,
            expectedEventId: existing.id,
            expectedGroupId: groupId,
            expectedOwnerId: existing.ownerId,
            expectedVersion: existing.version + 1,
            requestedMemberIds: existingRequestedMemberIds,
          );
          // 할당 RPC는 논리적 시리즈 기준점을 반환한다. 반복 행의 제한된 프로젝션을
          // 새로 고쳐 발생 항목이 컨트롤러 상태에서 인위적인 `single` 중복을 얻지
          // 않게 한다.
          if (_usesBoundedEventRangeReads &&
              (existing.recurrenceRule != null ||
                  existing.occurrenceKey != 'single')) {
            await refreshSelectedEventRange(force: true);
            if (!_isOperationGenerationCurrent(
              operationGeneration,
              userId: userId,
              groupId: groupId,
            )) {
              return null;
            }
          } else {
            _upsertEvent(normalizedUpdated);
          }
          notificationMutationCommitted = true;
          return EventSaveSnapshot(normalizedUpdated);
        }
        if (existing.ownerId != userId) {
          throw const ScheduleConflictException('이 일정은 작성자만 변경할 수 있습니다.');
        }
        if (existing.recurrenceRule != null ||
            existing.occurrenceKey != 'single' ||
            normalizedDraft.recurrence != null) {
          final recurrenceRepository = _repository;
          if (recurrenceRepository is! RecurrenceCapability) {
            throw const ScheduleCapabilityException('반복 일정을 지원하지 않는 저장소입니다.');
          }
          final capability = recurrenceRepository as RecurrenceCapability;
          final receipt = await capability.updateEventOccurrence(
            event: existing,
            draft: normalizedDraft,
            scope: scope,
            expectedSeriesVersion: existing.version,
            expectedOccurrenceVersion: existing.occurrenceVersion,
            actorId: userId,
          );
          if (!_isOperationCurrent(
            operation,
            userId: userId,
            groupId: groupId,
            plannerRevision: revision,
          )) {
            return null;
          }
          if (receipt.groupId != groupId ||
              receipt.eventId != existing.id ||
              receipt.occurrenceKey != existing.occurrenceKey ||
              receipt.scope != scope ||
              !receipt.committed ||
              receipt.seriesVersion !=
                  (receipt.changed ? existing.version + 1 : existing.version) ||
              receipt.occurrenceVersion !=
                  (scope == EventEditScope.thisOccurrence
                      ? (receipt.changed
                            ? existing.occurrenceVersion + 1
                            : existing.occurrenceVersion)
                      : 0)) {
            throw const ScheduleConflictException('일정 변경 응답을 확인할 수 없습니다.');
          }
          // 범위 RPC는 프로젝션 대신 커밋된 결과 확인을 반환한다. 서버 기준으로 다시
          // 조회하며 오래된 발생 항목을 로컬에서 여러 항목으로 확산하지 않는다.
          if (receipt.changed) {
            notificationMutationCommitted = true;
            await refreshSelectedEventRange(force: true);
            if (!_isOperationGenerationCurrent(
              operationGeneration,
              userId: userId,
              groupId: groupId,
            )) {
              return null;
            }
          }
          return EventSaveReceipt(receipt);
        }
        final existingMemberIds = canonicalEventMemberIds(existing.memberIds);
        final legacyMembersChanged = !_sameMemberIdSet(
          existingMemberIds,
          existingRequestedMemberIds,
        );
        if (legacyMembersChanged &&
            _repository is! EventMemberAssignmentCapability) {
          throw const ScheduleCapabilityException('일정 멤버 지정을 지원하지 않는 저장소입니다.');
        }
        final updated = await _repository.updateEvent(
          existing.copyWith(
            title: normalizedDraft.title,
            note: normalizedDraft.note,
            startAt: normalizedDraft.startAt.toUtc(),
            endAt: normalizedDraft.endAt.toUtc(),
            allDay: normalizedDraft.allDay,
            memberIds: existingRequestedMemberIds,
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
          return null;
        }
        final normalizedUpdated = _validatedEventMutationResult(
          updated,
          expectedEventId: existing.id,
          expectedGroupId: groupId,
          expectedOwnerId: existing.ownerId,
          expectedVersion: existing.version + 1,
          requestedMemberIds: existingRequestedMemberIds,
        );
        _upsertEvent(normalizedUpdated);
        notificationMutationCommitted = true;
        return EventSaveSnapshot(normalizedUpdated);
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
      if (notificationMutationCommitted) {
        _runNotificationSideEffect(
          (notifications) => notifications.onEventChanged(
            eventId: notificationEventId,
            groupId: groupId,
          ),
        );
      }
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
    final recurring =
        event.recurrenceRule != null || event.occurrenceKey != 'single';
    if (recurring && !normalizedMemberIds.contains(event.ownerId)) {
      const error = ScheduleValidationException('반복 일정 작성자는 멤버에서 제외할 수 없습니다.');
      errorMessage = error.message;
      notifyListeners();
      throw error;
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
      if (recurring) {
        final recurringCapability = _repository;
        if (recurringCapability is! RecurringEventMemberAssignmentCapability) {
          throw const ScheduleCapabilityException(
            '반복 일정 멤버 지정을 지원하지 않는 저장소입니다.',
          );
        }
        final recurringAssignmentCapability =
            recurringCapability as RecurringEventMemberAssignmentCapability;
        final receipt = await recurringAssignmentCapability
            .replaceRecurringEventMembers(
              event: event,
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
        _validateRecurringMemberReceipt(
          receipt,
          event: event,
          expectedVersion: event.version,
        );
        if (receipt.changed) {
          await refreshSelectedEventRange(force: true);
          _runNotificationSideEffect(
            (notifications) => notifications.onMembershipChanged(
              eventId: event.id,
              groupId: groupId,
            ),
          );
        }
        return;
      }
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
      final normalizedUpdated = _validatedEventMutationResult(
        updated,
        expectedEventId: event.id,
        expectedGroupId: groupId,
        expectedOwnerId: event.ownerId,
        expectedVersion: expectedResultVersion,
        requestedMemberIds: normalizedMemberIds,
      );
      if (_usesBoundedEventRangeReads &&
          (event.recurrenceRule != null || event.occurrenceKey != 'single')) {
        await refreshSelectedEventRange(force: true);
      } else {
        _upsertEvent(normalizedUpdated);
      }
      _runNotificationSideEffect(
        (notifications) => notifications.onMembershipChanged(
          eventId: event.id,
          groupId: groupId,
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

  static void _validateRecurringMemberAssignment(
    PlannerEvent event,
    Iterable<String> memberIds,
  ) {
    final normalized = canonicalEventMemberIds(memberIds);
    if (event.ownerId.trim().isEmpty || !normalized.contains(event.ownerId)) {
      throw const ScheduleValidationException('반복 일정 작성자는 멤버에서 제외할 수 없습니다.');
    }
  }

  static void _validateRecurringMemberReceipt(
    RecurrenceMutationReceipt receipt, {
    required PlannerEvent event,
    required int expectedVersion,
  }) {
    final expectedKey = event.occurrenceKey == 'single'
        ? occurrenceKeyForIndex(0)
        : event.occurrenceKey;
    final expectedSeriesVersion = receipt.changed
        ? expectedVersion + 1
        : expectedVersion;
    if (!receipt.committed ||
        receipt.groupId != event.groupId ||
        receipt.eventId != event.id ||
        receipt.occurrenceKey != expectedKey ||
        receipt.scope != EventEditScope.all ||
        receipt.seriesVersion != expectedSeriesVersion ||
        receipt.occurrenceVersion != 0) {
      throw const ScheduleConflictException('반복 일정 멤버 변경 응답을 확인할 수 없습니다.');
    }
  }

  static bool _draftBodyAndRuleMatchesEvent(
    EventDraft draft,
    PlannerEvent event,
  ) {
    bool sameDate(DateTime? left, DateTime? right) {
      if (left == null || right == null) return left == right;
      return left.year == right.year &&
          left.month == right.month &&
          left.day == right.day;
    }

    final sameAllDayDates = draft.allDay
        ? event.allDay &&
              sameDate(draft.allDayStartDate, event.allDayStartDate) &&
              sameDate(draft.allDayEndDate, event.allDayEndDate)
        : !event.allDay &&
              event.allDayStartDate == null &&
              event.allDayEndDate == null;
    return draft.title.trim() == event.title &&
        draft.note == event.note &&
        draft.startAt.toUtc() == event.startAt.toUtc() &&
        draft.endAt.toUtc() == event.endAt.toUtc() &&
        draft.allDay == event.allDay &&
        sameAllDayDates &&
        draft.colorValue == event.colorValue &&
        draft.timezone == event.timezone &&
        draft.recurrence == event.recurrenceRule;
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
      (event) => event.identityKey == normalizedIncoming.identityKey,
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

  /// 변경 작업이 반환한 초대를 진행 중인 수명 주기 메타데이터 새로 고침과 병합한다.
  /// 두 응답에 같은 행 ID가 있을 수 있다. ID로 교체하면 변경 Future가 마지막에
  /// 완료되어도 중복을 앞에 추가하지 않고 표시 프로젝션을 정규 상태로 유지한다.
  /// 생성 RPC는 일회성 평문 경계이며 캐시되거나 목록에 표시된 행은 이를 보관해서는
  /// 안 된다.
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

  Future<void> deleteEvent(
    PlannerEvent event, {
    EventEditScope scope = EventEditScope.all,
  }) async {
    final current = user;
    if (current == null) return;
    final operation = _beginOperation();
    final revision = _plannerRevision;
    final userId = current.id;
    final groupId = selectedGroup?.id;
    var notificationDeletionCommitted = false;
    _startSaving(operation);
    errorMessage = null;
    notifyListeners();
    try {
      if (event.recurrenceRule != null || event.occurrenceKey != 'single') {
        final recurrenceRepository = _repository;
        if (recurrenceRepository is! RecurrenceCapability) {
          throw const ScheduleCapabilityException('반복 일정을 지원하지 않는 저장소입니다.');
        }
        final capability = recurrenceRepository as RecurrenceCapability;
        final receipt = await capability.deleteEventOccurrence(
          event: event,
          scope: scope,
          expectedSeriesVersion: event.version,
          expectedOccurrenceVersion: event.occurrenceVersion,
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
        if (receipt.groupId != event.groupId ||
            receipt.eventId != event.id ||
            receipt.occurrenceKey != event.occurrenceKey ||
            receipt.scope != scope ||
            !receipt.committed ||
            receipt.seriesVersion !=
                (receipt.changed ? event.version + 1 : event.version) ||
            receipt.occurrenceVersion !=
                (scope == EventEditScope.thisOccurrence
                    ? (receipt.changed
                          ? event.occurrenceVersion + 1
                          : event.occurrenceVersion)
                    : 0)) {
          throw const ScheduleConflictException('일정 변경 응답을 확인할 수 없습니다.');
        }
        if (receipt.changed) {
          notificationDeletionCommitted = true;
          await refreshSelectedEventRange(force: true);
        }
        return;
      }
      await _repository.softDeleteEvent(
        event.id,
        expectedVersion: event.version,
        actorId: userId,
      );
      notificationDeletionCommitted = true;
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
          ...events.where(
            (candidate) => candidate.identityKey != event.identityKey,
          ),
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
      if (notificationDeletionCommitted) {
        _runNotificationSideEffect(
          (notifications) => notifications.onEventChanged(
            eventId: event.id,
            groupId: event.groupId,
          ),
        );
      }
      _finishSaving(operation);
    }
  }

  Future<void> _hydrateAppearancePreferences() async {
    if (_appearancePreferencesLoadInFlight || _disposed) return;
    _appearancePreferencesLoadInFlight = true;
    try {
      final loaded = await _appearancePreferencesStore.load();
      if (_disposed) return;
      final darkModeWasChanged = _darkModeChangedDuringHydration;
      final textScaleWasChanged = _textScaleChangedDuringHydration;
      if (loaded != null) {
        final scale = loaded.textScale;
        if (!scale.isFinite ||
            scale < AppearancePreferences.minTextScale ||
            scale > AppearancePreferences.maxTextScale) {
          throw const FormatException('화면 설정을 확인해 주세요.');
        }
        if (!darkModeWasChanged) {
          darkMode = loaded.darkMode;
        }
        if (!textScaleWasChanged) {
          textScale = scale;
        }
      }
      _appearancePreferencesHydrated = true;
      appearancePreferencesError = null;
      notifyListeners();
      // hydration 중 변경은 기본값 snapshot으로 미리 쓰지 않고, 읽은 값과 병합된
      // 현재 상태 하나만 영구화한다. 앱 종료나 후속 쓰기 실패 사이에도 손대지 않은
      // 필드가 잠시 기본값으로 덮이지 않는다.
      if (_appearancePreferencesWritePending) {
        _appearancePreferencesWritePending = false;
        _persistAppearancePreferences();
      }
    } catch (_) {
      if (_disposed) return;
      _appearancePreferencesHydrated = false;
      appearancePreferencesError = '화면 설정을 불러오지 못했어요.';
      notifyListeners();
    } finally {
      _appearancePreferencesLoadInFlight = false;
    }
  }

  void _persistAppearancePreferences() {
    if (!_appearancePreferencesHydrated) {
      _appearancePreferencesWritePending = true;
      return;
    }
    final revision = _appearancePreferencesRevision;
    final snapshot = AppearancePreferences(
      darkMode: darkMode,
      textScale: textScale,
    );
    final write = _appearancePreferencesWriteQueue.then(
      (_) => _appearancePreferencesStore.save(snapshot),
    );
    // 실패한 쓰기도 대기열에서 소비해 뒤따르는 슬라이더 변경이 저장소에 도달하게
    // 한다. 최신 UI 리비전의 결과만 상태 문구를 갱신한다.
    _appearancePreferencesWriteQueue = write.then<void>(
      (_) {
        if (_disposed || revision != _appearancePreferencesRevision) return;
        if (appearancePreferencesError != null) {
          appearancePreferencesError = null;
          notifyListeners();
        }
      },
      onError: (Object _, StackTrace stack) {
        if (_disposed || revision != _appearancePreferencesRevision) return;
        appearancePreferencesError = '화면 설정을 저장하지 못했어요.';
        notifyListeners();
      },
    );
  }

  void toggleDarkMode(bool value) {
    _appearancePreferencesRevision += 1;
    _darkModeChangedDuringHydration = true;
    darkMode = value;
    if (_appearancePreferencesHydrated) {
      appearancePreferencesError = null;
    }
    notifyListeners();
    _persistAppearancePreferences();
  }

  void setTextScale(double value) {
    if (!value.isFinite) return;
    _appearancePreferencesRevision += 1;
    _textScaleChangedDuringHydration = true;
    textScale = value
        .clamp(
          AppearancePreferences.minTextScale,
          AppearancePreferences.maxTextScale,
        )
        .toDouble();
    if (_appearancePreferencesHydrated) {
      appearancePreferencesError = null;
    }
    notifyListeners();
    _persistAppearancePreferences();
  }

  void retryAppearancePreferencesSave() {
    if (!_appearancePreferencesHydrated) {
      unawaited(retryAppearancePreferencesLoad());
      return;
    }
    _appearancePreferencesRevision += 1;
    appearancePreferencesError = null;
    notifyListeners();
    _persistAppearancePreferences();
  }

  Future<void> retryAppearancePreferencesLoad() async {
    if (_disposed || _appearancePreferencesLoadInFlight) return;
    appearancePreferencesError = null;
    notifyListeners();
    await _hydrateAppearancePreferences();
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

  /// 현지화된 오류 문구를 추측하지 않고 서버에서 확인된 접근 권한 상실을 식별한다.
  /// PostgREST의 `42501`은 SQL 권한 부족 코드이며, 명시적 HTTP/인증 상태는 세션
  /// 폐기 응답을 포함한다.
  bool _isAuthoritativeRangeDenial(Object error) {
    if (error is ScheduleAuthorizationException) return true;
    if (error is PostgrestException) {
      final code = error.code;
      return code == '42501' ||
          code == '28000' ||
          code == '401' ||
          code == '403';
    }
    if (error is AuthException) {
      final status = error.statusCode;
      return status == '401' || status == '403';
    }
    return false;
  }

  /// 상세 경로에 구조화된 수명 주기/권한 분류를 노출한다. 편집기는 없는 일정이 최종
  /// 상태인지 다시 시도할 수 있는지 결정할 때 현지화된 오류 문자열을 의도적으로
  /// 검사하지 않는다.
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
    _resetSearchState();
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
