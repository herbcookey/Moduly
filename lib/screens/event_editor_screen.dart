import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
import '../models/notification_models.dart';
import '../state/notification_state.dart';
import '../widgets/event_notification_controls.dart';
import 'widgets/recurrence_controls.dart';
import '../state/app_state.dart';

class EventEditorScreen extends ConsumerStatefulWidget {
  const EventEditorScreen({this.eventId, this.occurrenceKey, super.key});
  final String? eventId;

  /// 캘린더 카드 딥 링크에서 온 불투명하고 안정적인 발생 키다. null과 `single`은
  /// 기존 `/event/:id` 경로 의미를 유지한다.
  final String? occurrenceKey;

  @override
  ConsumerState<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends ConsumerState<EventEditorScreen> {
  GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _noteController;
  late DateTime _start;
  late DateTime _end;
  bool _allDay = false;
  int _colorValue = 0xff477b76;
  RecurrenceRule? _recurrenceRule;
  EventEditScope? _recurrenceScope;
  GlobalKey<RecurrenceEditorState> _recurrenceKey =
      GlobalKey<RecurrenceEditorState>();
  bool _didSeed = false;
  final Set<String> _selectedMemberIds = <String>{};
  int? _bodyDraftBaseVersion;
  int? _participantDraftBaseVersion;
  bool _bodyDraftDirty = false;
  bool _memberSelectionDirty = false;
  bool _eventUnavailable = false;
  PlannerEvent? _deepLinkedEvent;
  String? _deepLinkedUserId;
  String? _deepLinkedGroupId;
  bool _eventLookupStarted = false;
  bool _eventLookupInFlight = false;
  bool _eventLookupSettled = false;
  bool _eventLookupRetryable = false;
  String? _eventLookupError;
  bool _notificationEnabled = false;
  NotificationChannel _notificationChannel = NotificationChannel.local;
  int _timedLeadSeconds = 900;
  int _allDayDaysBefore = 0;
  bool _notificationApplyToWholeSeries = true;
  bool _notificationDraftDirty = false;
  String? _notificationDraftIdentity;
  int? _notificationDraftVersion;
  // 원격 계정 프로젝션은 의도적으로 모든 일정의 설정을 노출하지 않으므로 원격 일정
  // 알림 설정은 지연해서 불러온다. 인증 세션/논리 일정마다 한 번만 시도하며 빌드
  // 안에서 요청을 시작하지 않는다. 프레임 이후 콜백을 사용하면 Flutter가 위젯
  // 트리를 순회하는 동안 컨트롤러를 변경하지 않을 수 있다.
  String? _notificationPreferenceLoadKey;
  String? _notificationPreferenceLoadedKey;
  String? _notificationPreferenceFailedKey;
  bool _notificationPreferenceLoadInFlight = false;
  int _notificationPreferenceLoadGeneration = 0;
  // 경로 식별자가 바뀌거나 새 상세 요청을 시작할 때마다 증가한다. 완료된 조회는 이
  // 세대와 일정/발생 식별자가 모두 일치해야 편집기의 초기값으로 쓸 수 있다.
  int _eventLookupGeneration = 0;

  final _colors = const <int>[
    0xff477b76,
    0xffb66d58,
    0xff8266a5,
    0xff4d78a8,
    0xff9a7b32,
  ];

  PlannerEvent? _existing(PlannerController controller) {
    if (widget.eventId == null) return null;
    for (final event in controller.events) {
      if (_matchesRouteEvent(event) && !event.isDeleted) return event;
    }
    final cached = _deepLinkedEvent;
    if (cached != null &&
        _matchesRouteEvent(cached) &&
        !cached.isDeleted &&
        cached.groupId == controller.selectedGroup?.id &&
        _deepLinkedUserId == controller.user?.id &&
        _deepLinkedGroupId == controller.selectedGroup?.id) {
      return cached;
    }
    return null;
  }

  bool _matchesRouteEvent(PlannerEvent event) {
    final eventId = widget.eventId;
    if (eventId == null) return false;
    if (widget.occurrenceKey == null || widget.occurrenceKey == 'single') {
      return event.id == eventId;
    }
    return (event.seriesId == eventId || event.id == eventId) &&
        event.occurrenceKey == widget.occurrenceKey;
  }

  String get _routeOccurrenceKey => widget.occurrenceKey ?? 'single';

  bool _isCurrentLookupRoute(
    int generation,
    String eventId,
    String occurrenceKey,
  ) {
    return mounted &&
        _eventLookupGeneration == generation &&
        widget.eventId == eventId &&
        _routeOccurrenceKey == occurrenceKey;
  }

  void _maybeLoadDeepLinkedEvent(PlannerController controller) {
    final eventId = widget.eventId;
    final current = controller.user;
    final group = controller.selectedGroup;
    final occurrenceLookup =
        widget.occurrenceKey != null && widget.occurrenceKey != 'single';
    final canLookup = occurrenceLookup
        ? controller.supportsEventOccurrenceByKey
        : controller.supportsEventById;
    if (eventId == null ||
        _eventLookupStarted ||
        current == null ||
        group == null ||
        !canLookup ||
        controller.isLoading) {
      return;
    }
    final requestEventId = eventId;
    final requestOccurrenceKey = widget.occurrenceKey ?? 'single';
    final requestGeneration = ++_eventLookupGeneration;
    _eventLookupStarted = true;
    _eventLookupInFlight = true;
    _eventLookupSettled = false;
    _eventLookupRetryable = false;
    _eventLookupError = null;
    final userId = current.id;
    final groupId = group.id;
    unawaited(
      controller
          .loadEventById(requestEventId, occurrenceKey: requestOccurrenceKey)
          .then((event) {
            // 같은 편집기 상태를 경로 B에 재사용한 뒤 경로 A가 완료될 수 있다.
            // 이 경우에는 B의 상태를 전혀 건드리지 않는다.
            if (!_isCurrentLookupRoute(
              requestGeneration,
              requestEventId,
              requestOccurrenceKey,
            )) {
              return;
            }
            final latest = ref.read(plannerControllerProvider);
            if (latest.user?.id != userId ||
                latest.selectedGroup?.id != groupId) {
              // 결과가 오래된 식별자/그룹에 속한다. 로컬 상세 캐시를 지우고 다음
              // 빌드가 새 문맥에서 재시도하게 한다.
              setState(() {
                _deepLinkedEvent = null;
                _deepLinkedUserId = null;
                _deepLinkedGroupId = null;
                _eventLookupStarted = false;
                _eventLookupInFlight = false;
                _eventLookupSettled = false;
                _eventLookupRetryable = false;
                _eventLookupError = null;
              });
              return;
            }
            setState(() {
              _deepLinkedEvent = event;
              _deepLinkedUserId = userId;
              _deepLinkedGroupId = groupId;
              _eventLookupInFlight = false;
              _eventLookupSettled = true;
              _eventLookupRetryable = false;
              _eventLookupError = null;
            });
          })
          .catchError((Object error) {
            if (!_isCurrentLookupRoute(
              requestGeneration,
              requestEventId,
              requestOccurrenceKey,
            )) {
              return;
            }
            final latest = ref.read(plannerControllerProvider);
            if (latest.user?.id != userId ||
                latest.selectedGroup?.id != groupId) {
              setState(() {
                _deepLinkedEvent = null;
                _deepLinkedUserId = null;
                _deepLinkedGroupId = null;
                _eventLookupStarted = false;
                _eventLookupInFlight = false;
                _eventLookupSettled = false;
                _eventLookupRetryable = false;
                _eventLookupError = null;
              });
              return;
            }
            final authoritative = latest.isAuthoritativeAccessDenial(error);
            setState(() {
              _deepLinkedEvent = null;
              _deepLinkedUserId = null;
              _deepLinkedGroupId = null;
              _eventLookupInFlight = false;
              _eventLookupSettled = true;
              _eventLookupRetryable = !authoritative;
              _eventLookupError = authoritative
                  ? null
                  : '일정을 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';
            });
          }),
    );
  }

  void _retryDeepLinkedEvent() {
    if (!mounted) return;
    setState(() {
      _eventLookupGeneration++;
      _eventUnavailable = false;
      _eventLookupStarted = false;
      _eventLookupInFlight = false;
      _eventLookupSettled = false;
      _eventLookupRetryable = false;
      _eventLookupError = null;
    });
    _maybeLoadDeepLinkedEvent(ref.read(plannerControllerProvider));
  }

  void _applyEventToBody(PlannerEvent event) {
    _titleController.text = event.title;
    _noteController.text = event.note;
    final wallStart = utcToWallTime(event.startAt, event.timezone);
    final wallEnd = utcToWallTime(event.endAt, event.timezone);
    if (event.allDay) {
      // 종일 일정의 endAt은 포함되지 않는 현지 시각 경계다. 레거시 행에는 날짜
      // 메타데이터가 없을 수 있으므로 메타데이터가 있을 때와 마찬가지로 이 경계에서
      // 편집기에 표시할 포함 날짜를 계산한다.
      _start =
          event.allDayStartDate?.toLocal() ??
          DateTime(wallStart.year, wallStart.month, wallStart.day);
      _end =
          event.allDayEndDate?.toLocal().subtract(const Duration(days: 1)) ??
          DateTime(
            wallEnd.year,
            wallEnd.month,
            wallEnd.day,
          ).subtract(const Duration(days: 1));
    } else {
      _start = wallStart;
      _end = wallEnd;
    }
    _allDay = event.allDay;
    _colorValue = event.colorValue;
    _recurrenceRule = event.recurrenceRule;
    // 발생분 경로에서는 사용자가 전체 범위 변경을 명시적으로 선택할 때까지 참여자
    // 컨트롤을 잠근다. 같은 게이트를 시리즈 기준점에도 적용하여 실수로 이번/향후 범위를
    // 선택해 멤버 정보가 새어 나오지 않게 한다.
    _recurrenceScope = null;
  }

  void _syncIncomingEventDraft(PlannerEvent event) {
    if (_bodyDraftBaseVersion == null) {
      if (!_bodyDraftDirty) _applyEventToBody(event);
      _bodyDraftBaseVersion = event.version;
    } else if (event.version != _bodyDraftBaseVersion && !_bodyDraftDirty) {
      _applyEventToBody(event);
      _bodyDraftBaseVersion = event.version;
    }

    if (_participantDraftBaseVersion == null) {
      if (!_memberSelectionDirty) {
        _selectedMemberIds
          ..clear()
          ..addAll(event.memberIds);
      }
      _participantDraftBaseVersion = event.version;
    } else if (event.version != _participantDraftBaseVersion &&
        !_memberSelectionDirty) {
      _selectedMemberIds
        ..clear()
        ..addAll(event.memberIds);
      _participantDraftBaseVersion = event.version;
    }
  }

  EventNotificationPreference? _notificationPreferenceFor(
    NotificationController notifications,
    PlannerEvent event,
  ) {
    // 캐시된 행은 다른 행위자가 멤버십을 바꾼 뒤에도 남아 있을 수 있다. 활성 계정이
    // 신뢰할 수 있는 일정 프로젝션의 멤버가 아니라면 그 오래된 행을 표시하거나
    // 이를 기준으로 저장하지 않는다.
    final activeUserId = notifications.userId;
    if (activeUserId == null ||
        activeUserId.isEmpty ||
        activeUserId != activeUserId.trim() ||
        !event.memberIds.contains(activeUserId)) {
      return null;
    }
    final candidates = notifications.eventPreferences
        .where(
          (value) =>
              value.eventId == event.seriesId || value.eventId == event.id,
        )
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    final local = candidates.where(
      (value) => value.channel == NotificationChannel.local,
    );
    final push = candidates.where(
      (value) => value.channel == NotificationChannel.push,
    );
    EventNotificationPreference? newest(
      Iterable<EventNotificationPreference> values,
    ) {
      final sorted = values.toList()
        ..sort((left, right) {
          final version = right.version.compareTo(left.version);
          return version != 0 ? version : left.id.compareTo(right.id);
        });
      return sorted.firstOrNull;
    }

    return newest(local) ?? newest(push);
  }

  void _syncNotificationDraft(
    PlannerEvent event,
    NotificationController notifications,
  ) {
    if (_notificationDraftDirty) return;
    final identity = event.seriesId;
    final preference = _notificationPreferenceFor(notifications, event);
    final version = preference?.version ?? 0;
    if (_notificationDraftIdentity == identity &&
        _notificationDraftVersion == version) {
      return;
    }
    _notificationDraftIdentity = identity;
    _notificationDraftVersion = version;
    _notificationEnabled = preference?.enabled ?? false;
    _notificationChannel = preference?.channel ?? NotificationChannel.local;
    _timedLeadSeconds = preference?.timedLeadSeconds ?? 900;
    _allDayDaysBefore = preference?.allDayDaysBefore ?? 0;
    _notificationApplyToWholeSeries = true;
  }

  void _resetNotificationDraft() {
    _notificationEnabled = false;
    _notificationChannel = NotificationChannel.local;
    _timedLeadSeconds = 900;
    _allDayDaysBefore = 0;
    _notificationApplyToWholeSeries = true;
    _notificationDraftDirty = false;
    _notificationDraftIdentity = null;
    _notificationDraftVersion = null;
    _notificationPreferenceLoadGeneration++;
    _notificationPreferenceLoadKey = null;
    _notificationPreferenceLoadedKey = null;
    _notificationPreferenceFailedKey = null;
    _notificationPreferenceLoadInFlight = false;
  }

  /// 논리 일정의 시리즈 전체 알림 설정을 인증된 읽기로 한 번 불러온다. 읽기가 끝나면
  /// 컨트롤러가 일정 설정 스냅샷을 갱신하고 리스너에 알리며, 이후 일반 빌드
  /// 과정에서 변경되지 않은 초안을 동기화한다. 수정된 컨트롤은 의도적으로 그대로
  /// 두며, 불러온 행은 버전 확인을 위해 저장 경로에서 계속 사용할 수 있다.
  void _maybeLoadNotificationPreferences(
    PlannerEvent event,
    NotificationController notifications,
    PlannerController planner,
  ) {
    final eventId = event.seriesId.trim();
    final activeUserId = notifications.userId;
    final plannerUserId = planner.user?.id;
    if (eventId.isEmpty ||
        activeUserId == null ||
        activeUserId.isEmpty ||
        activeUserId != activeUserId.trim() ||
        activeUserId != plannerUserId ||
        !event.memberIds.contains(activeUserId)) {
      return;
    }
    final key = '$activeUserId:$eventId';
    if (_notificationPreferenceLoadedKey == key ||
        _notificationPreferenceFailedKey == key ||
        (_notificationPreferenceLoadInFlight &&
            _notificationPreferenceLoadKey == key)) {
      return;
    }
    _notificationPreferenceLoadKey = key;
    _notificationPreferenceLoadInFlight = true;
    final generation = ++_notificationPreferenceLoadGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _notificationPreferenceLoadGeneration ||
          _notificationPreferenceLoadKey != key) {
        return;
      }
      final latestPlanner = ref.read(plannerControllerProvider);
      final latestNotifications = ref.read(notificationControllerProvider);
      final latestEvent = _existing(latestPlanner);
      if (latestPlanner.user?.id != activeUserId ||
          latestNotifications.userId != activeUserId ||
          latestEvent == null ||
          latestEvent.seriesId != eventId ||
          !latestEvent.memberIds.contains(activeUserId)) {
        _notificationPreferenceLoadInFlight = false;
        return;
      }
      unawaited(
        latestNotifications
            .loadEventPreferences(eventId)
            .then((_) {
              if (!mounted ||
                  generation != _notificationPreferenceLoadGeneration ||
                  _notificationPreferenceLoadKey != key) {
                return;
              }
              _notificationPreferenceLoadInFlight = false;
              _notificationPreferenceLoadedKey = key;
              _notificationPreferenceFailedKey = null;
              // loadEventPreferences는 성공 시 알림을 보낸다. 이 setState는 변경되지
              // 않은 빈 스냅샷을 반환하는 어댑터도 처리한다.
              if (mounted) setState(() {});
            })
            .catchError((Object _) {
              if (!mounted ||
                  generation != _notificationPreferenceLoadGeneration ||
                  _notificationPreferenceLoadKey != key) {
                return;
              }
              _notificationPreferenceLoadInFlight = false;
              // 읽기 실패도 시도한 것으로 간주해 재빌드가 제한 없는 요청 반복을
              // 돌지 않게 한다. Core는 일반 오류 메시지를 유지하며 여기서는 로컬
              // 초안이나 캐시된 설정을 지우지 않는다.
              _notificationPreferenceFailedKey = key;
              if (mounted) setState(() {});
            }),
      );
    });
  }

  void _retryNotificationPreferences(
    PlannerEvent event,
    NotificationController notifications,
    PlannerController planner,
  ) {
    if (!mounted) return;
    final userId = notifications.userId;
    final eventId = event.seriesId.trim();
    if (userId == null || userId.isEmpty || eventId.isEmpty) return;
    final key = '$userId:$eventId';
    if (_notificationPreferenceFailedKey != key) return;
    setState(() {
      _notificationPreferenceFailedKey = null;
      _notificationPreferenceLoadedKey = null;
      _notificationPreferenceLoadKey = null;
      _notificationPreferenceLoadInFlight = false;
    });
    _maybeLoadNotificationPreferences(event, notifications, planner);
  }

  void _seedExistingEvent(PlannerEvent event) {
    _applyEventToBody(event);
    _selectedMemberIds
      ..clear()
      ..addAll(event.memberIds);
    _bodyDraftBaseVersion = event.version;
    _participantDraftBaseVersion = event.version;
    _bodyDraftDirty = false;
    _memberSelectionDirty = false;
  }

  void _seedCreateDraft(PlannerController controller) {
    _start = DateTime(
      controller.selectedDay.year,
      controller.selectedDay.month,
      controller.selectedDay.day,
      9,
    );
    _end = _start.add(const Duration(hours: 1));
    final currentUserId = controller.user?.id;
    if (currentUserId != null && currentUserId.isNotEmpty) {
      _selectedMemberIds.add(currentUserId);
    }
    _bodyDraftBaseVersion = null;
    _participantDraftBaseVersion = null;
    _recurrenceRule = null;
    _recurrenceScope = null;
    _bodyDraftDirty = false;
    _memberSelectionDirty = false;
  }

  /// GoRouter가 이 상태 객체를 다른 일정이나 발생분에 재사용할 때 경로에 의존하는
  /// 모든 필드를 완전히 다시 초기화한다. 특히 반복 하위 요소/양식 키를 교체하여 자체적으로
  /// 수정한 필드가 A→B 경로 갱신 뒤에도 남지 않게 한다.
  void _resetForRouteIdentity(PlannerController controller) {
    _eventLookupGeneration++;
    _titleController.clear();
    _noteController.clear();
    final now = DateTime.now();
    _start = DateTime(now.year, now.month, now.day, now.hour + 1);
    _end = _start.add(const Duration(hours: 1));
    _allDay = false;
    _colorValue = _colors.first;
    _selectedMemberIds.clear();
    _bodyDraftBaseVersion = null;
    _participantDraftBaseVersion = null;
    _bodyDraftDirty = false;
    _memberSelectionDirty = false;
    _recurrenceRule = null;
    _recurrenceScope = null;
    _formKey = GlobalKey<FormState>();
    _recurrenceKey = GlobalKey<RecurrenceEditorState>();
    _eventUnavailable = false;
    _deepLinkedEvent = null;
    _deepLinkedUserId = null;
    _deepLinkedGroupId = null;
    _eventLookupStarted = false;
    _eventLookupInFlight = false;
    _eventLookupSettled = false;
    _eventLookupRetryable = false;
    _eventLookupError = null;
    _resetNotificationDraft();

    final existing = _existing(controller);
    if (existing != null) {
      _seedExistingEvent(existing);
    } else if (widget.eventId == null) {
      _seedCreateDraft(controller);
    }
    // 상세 내용을 불러와야 할 때도 경로를 초기화된 것으로 표시한다. 나중에 도착한
    // 신뢰할 수 있는 응답은 _syncIncomingEventDraft가 병합한다. 그러면
    // didChangeDependencies가 새 경로를 다시 초기화하지 않는다.
    _didSeed = true;
  }

  int _combinedDraftBaseVersion(PlannerEvent event) {
    final bodyVersion = _bodyDraftBaseVersion ?? event.version;
    final participantVersion = _participantDraftBaseVersion ?? event.version;
    return bodyVersion < participantVersion ? bodyVersion : participantVersion;
  }

  void _markBodyDraftDirty() {
    if (_bodyDraftDirty) return;
    setState(() => _bodyDraftDirty = true);
  }

  Future<void> _closeUnavailable() async {
    final popped = await Navigator.of(context).maybePop();
    if (!popped && mounted) {
      GoRouter.maybeOf(context)?.go('/home');
    }
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _noteController = TextEditingController();
    final now = DateTime.now();
    _start = DateTime(now.year, now.month, now.day, now.hour + 1);
    _end = _start.add(const Duration(hours: 1));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didSeed) return;
    _resetForRouteIdentity(ref.read(plannerControllerProvider));
  }

  @override
  void didUpdateWidget(covariant EventEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId == widget.eventId &&
        oldWidget.occurrenceKey == widget.occurrenceKey) {
      return;
    }
    _resetForRouteIdentity(ref.read(plannerControllerProvider));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final current = start ? _start : _end;
    final minimumEndDate = CalendarDateBounds.clamp(_start);
    var initialDate = CalendarDateBounds.clamp(current);
    if (!start && _allDay && initialDate.isBefore(minimumEndDate)) {
      initialDate = minimumEndDate;
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: CalendarDateBounds.firstDate,
      lastDate: CalendarDateBounds.lastDate,
      selectableDayPredicate: !start && _allDay
          ? (date) => !date.isBefore(minimumEndDate)
          : null,
      helpText: start ? '시작 날짜' : '종료 날짜',
      cancelText: '취소',
      confirmText: '선택',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _bodyDraftDirty = true;
      if (start) {
        _start = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _start.hour,
          _start.minute,
        );
        if (_allDay) {
          if (_end.isBefore(_start)) _end = _start;
        } else if (!_end.isAfter(_start)) {
          _end = _start.add(const Duration(hours: 1));
        }
      } else {
        _end = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _end.hour,
          _end.minute,
        );
      }
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      helpText: start ? '시작 시간' : '종료 시간',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _bodyDraftDirty = true;
      final date = current;
      final updated = DateTime(
        date.year,
        date.month,
        date.day,
        picked.hour,
        picked.minute,
      );
      if (start) {
        _start = updated;
        if (!_end.isAfter(_start)) _end = _start.add(const Duration(hours: 1));
      } else {
        _end = updated;
      }
    });
  }

  Future<void> _save() async {
    final controller = ref.read(plannerControllerProvider);
    final notifications = ref.read(notificationControllerProvider);
    final currentUserId = controller.user?.id;
    final existing = _existing(controller);
    if (widget.eventId != null && existing == null) return;
    final canEditBody = existing == null || existing.ownerId == currentUserId;
    final canManageParticipants = existing == null
        ? currentUserId != null && controller.selectedGroup != null
        : controller.canEditEventParticipants(existing);
    final canEditReminder =
        currentUserId != null &&
        (existing == null || existing.memberIds.contains(currentUserId));
    final recurringEvent = existing?.recurrenceRule != null;
    final recurringOccurrence =
        recurringEvent && existing?.occurrenceKey != 'single';
    final canEditParticipants = existing == null
        ? canManageParticipants
        : canManageParticipants &&
              (!recurringEvent || _recurrenceScope == EventEditScope.all);
    // 반복 시리즈의 배정에는 항상 일정 작성자를 유지한다. 보호된 체크박스뿐 아니라
    // 저장 경계에서도 검사한다. 오래된 상세 페이로드에는 작성자가 빠질 수 있으며,
    // 여기서 조용히 추가하면 새로고침을 요구하지 않고 잘못된 외부 상태를 숨기게 된다.
    final protectedCreatorId =
        existing?.ownerId ??
        (existing == null && _recurrenceRule != null ? currentUserId : null);
    final protectsCreator = existing != null
        ? (recurringEvent || _recurrenceRule != null)
        : _recurrenceRule != null;
    if (protectsCreator &&
        protectedCreatorId != null &&
        !_selectedMemberIds.contains(protectedCreatorId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('작성자 참여 정보를 확인한 뒤 다시 저장해 주세요.')),
      );
      return;
    }
    if (!canEditBody && !canEditParticipants && !canEditReminder) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이 일정은 작성자만 수정할 수 있어요.')));
      return;
    }
    if (existing != null &&
        !canEditBody &&
        !canEditParticipants &&
        canEditReminder) {
      try {
        await _saveNotificationPreference(
          notifications,
          event: existing,
          eventVersion: existing.version,
          requireLoadedPreference: true,
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('알림 설정을 저장했어요.')));
          context.go('/home');
        }
      } catch (_) {
        if (mounted) setState(() {});
      }
      return;
    }
    if (canEditBody && !(_formKey.currentState?.validate() ?? false)) return;
    if (canEditBody) {
      final recurrenceEditor = _recurrenceKey.currentState;
      final recurrence = recurrenceEditor?.validateRule();
      if (recurrenceEditor?.hasRecurrenceSelection == true &&
          recurrence == null) {
        return;
      }
      _recurrenceRule = recurrence;
    }
    if (existing != null && !canEditBody && canEditParticipants) {
      var participantCommitted = false;
      try {
        final participantDraft = existing.copyWith(
          version: _participantDraftBaseVersion ?? existing.version,
        );
        await controller.replaceEventMembers(
          participantDraft,
          _selectedMemberIds.toList(growable: false),
        );
        participantCommitted = true;
        // 참여자를 교체하면 멱등인 무동작이 아닌 한 일정의 낙관적 잠금 버전이
        // 증가한다. `await` 후 컨트롤러의 신뢰할 수 있는 프로젝션을 확인한다. 쓰기 전
        // [existing.version]을 알림 RPC로 보내면 오래된 버전 충돌이 반드시 발생하거나,
        // 관대한 어댑터에서는 폐기된 일정 리비전에 알림이 연결될 수 있다.
        final refreshed = _findUpdatedEvent(controller, existing);
        if (refreshed != null &&
            currentUserId != null &&
            !refreshed.memberIds.contains(currentUserId)) {
          // 이 화면에 수정된 알림 초안이 남아 있는 동안 멤버십 커밋이 행위자를 제거할
          // 수 있다. 원격 취소는 데이터베이스 트리거가 담당한다. 이제 권한 확인에 실패할
          // 알림 RPC를 멤버십 쓰기 뒤에 호출하지 않는다.
          await _clearNotificationAfterMembershipRemoval(
            notifications,
            refreshed,
          );
          _showMembershipNotificationDisabled();
          return;
        }
        if (_notificationDraftDirty) {
          final expectedVersion =
              _sameMemberIdSet(existing.memberIds, _selectedMemberIds)
              ? existing.version
              : existing.version + 1;
          if (refreshed == null || refreshed.version != expectedVersion) {
            _showPartialNotificationWarning();
            return;
          }
          await _saveNotificationPreference(
            notifications,
            event: refreshed,
            eventVersion: refreshed.version,
            requireLoadedPreference: true,
          );
        }
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('참여자를 저장했어요.')));
          context.go('/home');
        }
      } catch (_) {
        if (mounted) {
          if (participantCommitted && _notificationDraftDirty) {
            _showPartialNotificationWarning();
          }
          setState(() {});
        }
      }
      return;
    }
    final existingDraft = existing?.copyWith(
      version: _combinedDraftBaseVersion(existing),
    );
    final invalidRange = _allDay
        ? _end.isBefore(_start)
        : !_end.isAfter(_start);
    if (canEditBody && invalidRange) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('종료 시간은 시작 시간보다 늦어야 해요.')));
      return;
    }
    final timezone =
        existing?.timezone ?? controller.selectedGroup?.timezone ?? 'UTC';
    final draft = EventDraft(
      title: _titleController.text.trim(),
      note: _noteController.text.trim(),
      startAt: _allDay
          ? wallTimeToUtc(
              DateTime(_start.year, _start.month, _start.day),
              timezone,
            )
          : wallTimeToUtc(_start, timezone),
      endAt: _allDay
          ? wallTimeToUtc(
              DateTime(
                _end.year,
                _end.month,
                _end.day,
              ).add(const Duration(days: 1)),
              timezone,
            )
          : wallTimeToUtc(_end, timezone),
      allDay: _allDay,
      memberIds: List<String>.unmodifiable(_selectedMemberIds),
      colorValue: _colorValue,
      timezone: timezone,
      allDayStartDate: _allDay
          ? DateTime(_start.year, _start.month, _start.day)
          : null,
      allDayEndDate: _allDay
          ? DateTime(
              _end.year,
              _end.month,
              _end.day,
            ).add(const Duration(days: 1))
          : null,
      recurrence: _recurrenceRule,
    );
    var scope = EventEditScope.all;
    if (existing != null &&
        (recurringEvent || existing.occurrenceKey != 'single')) {
      final selectedScope =
          _recurrenceScope ??
          await showRecurrenceScopeDialog(context, deleting: false);
      if (selectedScope == null || !mounted) return;
      scope = selectedScope;
    }
    if (recurringOccurrence &&
        scope != EventEditScope.all &&
        _memberSelectionDirty) {
      // 오래된 전체 범위 참여자 초안이 이번/향후 범위 변경으로 새어 들어가서는 안 된다.
      // 이를 되돌리고 참여자를 다시 편집하기 전에 전체 범위를 선택하도록 안내한다.
      final recurringTarget = existing;
      if (recurringTarget == null) return;
      setState(() {
        _selectedMemberIds
          ..clear()
          ..addAll(recurringTarget.memberIds);
        _memberSelectionDirty = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('참여자 변경은 전체 일정에서만 적용돼요.')));
      return;
    }
    if (recurringEvent &&
        existing?.occurrenceKey == 'single' &&
        scope != EventEditScope.all) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('시리즈 일정은 전체 일정 범위에서만 변경할 수 있어요.')),
      );
      return;
    }
    var reminderDisabledByMembership = false;
    try {
      final saveResult = await controller.saveEvent(
        existing: existingDraft,
        draft: draft,
        scope: scope,
      );
      // 인증이나 선택 그룹이 쓰기 도중 바뀌면 컨트롤러는 오래된 결과를 적용하지
      // 않는다. 이를 저장 성공처럼 표시하거나 알림 쓰기로 이어 가지 않는다.
      if (saveResult == null) return;
      final savedEvent = _eventForSaveResult(controller, saveResult);
      if (savedEvent != null) {
        if (currentUserId != null &&
            !savedEvent.memberIds.contains(currentUserId)) {
          await _clearNotificationAfterMembershipRemoval(
            notifications,
            savedEvent,
          );
          reminderDisabledByMembership = true;
        } else {
          try {
            await _saveNotificationPreference(
              notifications,
              event: savedEvent,
              eventVersion: savedEvent.version,
              requireLoadedPreference: existing != null,
            );
          } catch (_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('일정은 저장했지만 알림 설정을 저장하지 못했어요.')),
              );
            }
          }
        }
      } else if (_notificationDraftDirty) {
        // 일정 쓰기는 커밋되었지만 갱신된 프로젝션은 일정 버전에 묶인 알림 RPC를
        // 수행할 만큼 신뢰할 수 없다. 알림 초안은 저장하지 않은 채 유지하고 전송
        // 세부 정보를 노출하지 않으면서 부분 성공 결과를 설명한다.
        _showPartialNotificationWarning();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              reminderDisabledByMembership
                  ? '참여에서 제외되어 알림도 해제됐어요.'
                  : '일정을 저장했어요.',
            ),
          ),
        );
        context.go('/home');
      }
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _chooseRecurrenceScope(PlannerEvent event) async {
    final selected = await showRecurrenceScopeDialog(
      context,
      deleting: false,
      initial: _recurrenceScope ?? EventEditScope.thisOccurrence,
    );
    if (selected == null || !mounted) return;
    final participantDraftWasDirty = _memberSelectionDirty;
    setState(() {
      _recurrenceScope = selected;
      if (selected != EventEditScope.all && participantDraftWasDirty) {
        _selectedMemberIds
          ..clear()
          ..addAll(event.memberIds);
        _memberSelectionDirty = false;
      }
    });
    if (selected != EventEditScope.all && participantDraftWasDirty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('참여자 변경은 전체 일정에서만 적용돼요. 변경을 되돌렸어요.')),
      );
    }
  }

  Future<void> _saveNotificationPreference(
    NotificationController notifications, {
    required PlannerEvent event,
    required int eventVersion,
    bool requireLoadedPreference = false,
  }) async {
    if (!_notificationDraftDirty) return;
    if (event.recurrenceRule != null && !_notificationApplyToWholeSeries) {
      throw const FormatException('반복 일정 알림은 전체 일정에만 적용돼요.');
    }
    final userId =
        notifications.userId ?? ref.read(plannerControllerProvider).user?.id;
    if (userId == null || userId.isEmpty) {
      throw const FormatException('로그인 세션을 확인해 주세요.');
    }
    if (requireLoadedPreference &&
        _notificationPreferenceLoadedKey != '$userId:${event.seriesId}') {
      throw const FormatException('최신 알림 설정을 불러온 뒤 다시 시도해 주세요.');
    }
    final previous = _notificationPreferenceFor(notifications, event);
    final selected = EventNotificationPreference(
      id: previous?.channel == _notificationChannel
          ? previous!.id
          : '${event.seriesId}:${_notificationChannel.wireName}',
      userId: userId,
      eventId: event.seriesId,
      channel: _notificationChannel,
      enabled: _notificationEnabled,
      timedLeadSeconds: _timedLeadSeconds,
      allDayDaysBefore: _allDayDaysBefore,
      version: previous?.channel == _notificationChannel
          ? previous!.version
          : 0,
      eventVersion: eventVersion,
    );
    if (previous != null && previous.channel != _notificationChannel) {
      await notifications.saveEventPreference(
        previous.copyWith(enabled: false, eventVersion: eventVersion),
        expectedVersion: previous.version,
      );
    }
    await notifications.saveEventPreference(
      selected,
      expectedVersion: selected.version,
    );
    _notificationDraftDirty = false;
    _notificationDraftIdentity = event.seriesId;
    _notificationDraftVersion = selected.version;
  }

  PlannerEvent? _eventForSaveResult(
    PlannerController controller,
    EventSaveResult result,
  ) {
    return switch (result) {
      EventSaveSnapshot(:final event) => event,
      EventSaveReceipt(:final receipt) =>
        controller.events
            .where(
              (event) =>
                  event.groupId == receipt.groupId &&
                  event.seriesId == receipt.eventId &&
                  event.occurrenceKey == receipt.occurrenceKey &&
                  event.version == receipt.seriesVersion &&
                  (receipt.scope != EventEditScope.thisOccurrence ||
                      event.occurrenceVersion == receipt.occurrenceVersion) &&
                  !event.isDeleted,
            )
            .firstOrNull,
    };
  }

  PlannerEvent? _findUpdatedEvent(
    PlannerController controller,
    PlannerEvent existing,
  ) {
    for (final event in controller.events) {
      if ((event.id == existing.id &&
              event.occurrenceKey == existing.occurrenceKey) ||
          event.identityKey == existing.identityKey) {
        return event;
      }
    }
    return null;
  }

  void _showPartialNotificationWarning() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('일정은 저장했지만 알림 설정을 저장하지 못했어요. 최신 일정을 불러온 뒤 다시 시도해 주세요.'),
      ),
    );
  }

  Future<void> _clearNotificationAfterMembershipRemoval(
    NotificationController notifications,
    PlannerEvent event,
  ) async {
    final eventId = event.seriesId;
    // 멤버십 변경은 이미 NotificationController에 알리며 서버 측 트리거가 삭제/취소를
    // 담당한다. 나중에 재빌드가 오래된 저장을 제안하지 않도록 이 경로의 비공개
    // 초안/캐시만 지운다.
    _notificationEnabled = false;
    _notificationChannel = NotificationChannel.local;
    _timedLeadSeconds = 900;
    _allDayDaysBefore = 0;
    _notificationApplyToWholeSeries = true;
    _notificationDraftDirty = false;
    _notificationDraftIdentity = eventId;
    _notificationDraftVersion = 0;
    _notificationPreferenceLoadedKey = null;
    _notificationPreferenceFailedKey = null;
    try {
      // 멤버십 커밋 후 컨트롤러의 로컬 스냅샷에서 이 일정을 제거한다. 원격
      // 삭제/취소는 계속 멤버십 트리거와 일반 컨트롤러 조정이 담당한다.
      await notifications.forgetEventPreferences(eventId);
    } catch (_) {
      // 초안은 이미 지웠다. 메모리에서 제거하는 작업이 예기치 않게 실패해도 사용자에게
      // 표시하는 멤버십 결과는 일반적인 문구로 유지한다.
    }
  }

  void _showMembershipNotificationDisabled() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('참여에서 제외되어 알림도 해제됐어요.')));
  }

  Future<void> _delete(PlannerEvent event) async {
    final currentUserId = ref.read(plannerControllerProvider).user?.id;
    if (event.ownerId != currentUserId) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이 일정은 작성자만 삭제할 수 있어요.')));
      return;
    }
    EventEditScope? scope;
    if (event.recurrenceRule != null || event.occurrenceKey != 'single') {
      scope = await showRecurrenceScopeDialog(context, deleting: true);
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('일정을 삭제할까요?'),
          content: const Text('삭제한 일정은 캘린더에서 바로 사라집니다.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제'),
            ),
          ],
        ),
      );
      if (confirmed == true) scope = EventEditScope.all;
    }
    if (scope == null || !mounted) return;
    try {
      await ref
          .read(plannerControllerProvider)
          .deleteEvent(event, scope: scope);
      if (mounted) context.go('/home');
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(plannerControllerProvider);
    final notifications = ref.watch(notificationControllerProvider);
    final existing = _existing(controller);
    if (widget.eventId != null && existing == null) {
      _maybeLoadDeepLinkedEvent(controller);
    }
    final lookupReady =
        widget.eventId != null &&
        controller.user != null &&
        controller.selectedGroup != null &&
        ((widget.occurrenceKey != null && widget.occurrenceKey != 'single')
            ? controller.supportsEventOccurrenceByKey
            : controller.supportsEventById);
    final lookupPending =
        widget.eventId != null &&
        existing == null &&
        !_eventLookupSettled &&
        (controller.isLoading || _eventLookupInFlight || lookupReady);
    if (widget.eventId != null && existing == null && _eventLookupRetryable) {
      return Scaffold(
        appBar: AppBar(title: const Text('일정 보기')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  liveRegion: true,
                  label: _eventLookupError ?? '일정을 불러오지 못했어요.',
                  child: Text(
                    _eventLookupError ?? '일정을 불러오지 못했어요.',
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  button: true,
                  label: '다시 시도',
                  child: FilledButton(
                    onPressed: _retryDeepLinkedEvent,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('다시 시도'),
                  ),
                ),
                const SizedBox(height: 8),
                Semantics(
                  button: true,
                  label: '돌아가기',
                  child: OutlinedButton(
                    onPressed: _closeUnavailable,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('돌아가기'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (widget.eventId != null && existing == null && !lookupPending) {
      _eventUnavailable = true;
    }
    if (_eventUnavailable || (widget.eventId != null && existing == null)) {
      final loading = !_eventUnavailable && lookupPending;
      return Scaffold(
        appBar: AppBar(title: const Text('일정 보기')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: loading
                ? const CircularProgressIndicator(semanticsLabel: '일정을 불러오는 중')
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Semantics(
                        liveRegion: true,
                        label: '일정을 찾을 수 없어요.',
                        child: const Text('일정을 찾을 수 없어요.'),
                      ),
                      const SizedBox(height: 16),
                      Semantics(
                        button: true,
                        label: '돌아가기',
                        child: OutlinedButton(
                          onPressed: _closeUnavailable,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 48),
                          ),
                          child: const Text('돌아가기'),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      );
    }
    if (existing != null) {
      _syncIncomingEventDraft(existing);
      _syncNotificationDraft(existing, notifications);
      _maybeLoadNotificationPreferences(existing, notifications, controller);
    }
    final canEditBody =
        existing == null || existing.ownerId == controller.user?.id;
    final recurringEvent = existing?.recurrenceRule != null;
    final recurringOccurrence =
        recurringEvent && existing?.occurrenceKey != 'single';
    final canManageParticipants = existing == null
        ? controller.user != null && controller.selectedGroup != null
        : controller.canEditEventParticipants(existing);
    final canEditParticipants = existing == null
        ? canManageParticipants
        : canManageParticipants &&
              (!recurringEvent || _recurrenceScope == EventEditScope.all);
    final canEditReminder =
        controller.user != null &&
        (existing == null || existing.memberIds.contains(controller.user!.id));
    final protectsCreator = existing != null
        ? (recurringEvent || _recurrenceRule != null)
        : _recurrenceRule != null;
    final protectedCreatorId = protectsCreator
        ? (existing?.ownerId ?? controller.user?.id)
        : null;
    String? protectedCreatorName;
    if (protectedCreatorId != null) {
      for (final member in controller.members) {
        if (member.id == protectedCreatorId) {
          protectedCreatorName = member.name;
          break;
        }
      }
    }
    final scheme = Theme.of(context).colorScheme;
    // 알림 읽기는 편집기의 일반 오류 화면을 공유한다. 두 작업이 모두 실패하면 플래너
    // 변경 오류를 우선하고 알림 컨트롤러의 전송/공급자 세부 정보는 노출하지 않는다.
    final editorErrorMessage =
        controller.errorMessage ?? notifications.errorMessage;
    final notificationLoadKey = existing == null
        ? null
        : '${notifications.userId}:${existing.seriesId}';
    final canRetryNotificationLoad =
        existing != null &&
        controller.user?.id == notifications.userId &&
        existing.memberIds.contains(controller.user!.id) &&
        _notificationPreferenceFailedKey == notificationLoadKey;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          existing == null
              ? '새 일정'
              : (canEditBody || canEditParticipants)
              ? '일정 편집'
              : '일정 보기',
        ),
        actions: <Widget>[
          if (existing != null && canEditBody)
            IconButton(
              tooltip: '삭제',
              onPressed: controller.isSaving ? null : () => _delete(existing),
              icon: const Icon(Icons.delete_outline),
            ),
          if (canEditBody || canEditParticipants)
            TextButton(
              onPressed: controller.isSaving ? null : _save,
              child: const Text('저장'),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          // 편집기는 피드가 아니라 범위가 제한된 양식이다. 작은 표시 영역에서 반복
          // 섹션이 커져도 작은 색상/참여자 컨트롤을 시맨틱 트리에 유지한다.
          scrollCacheExtent: ScrollCacheExtent.pixels(1200),
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 40),
          children: <Widget>[
            if (!canEditBody) ...<Widget>[
              Semantics(
                label: '이 일정은 작성자만 수정할 수 있어요.',
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.info_outline,
                        color: scheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '이 일정은 작성자만 수정할 수 있어요.',
                              style: TextStyle(
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                            if (canEditParticipants)
                              Text(
                                '참여자만 변경할 수 있어요.',
                                style: TextStyle(
                                  color: scheme.onSecondaryContainer,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            TextFormField(
              controller: _titleController,
              readOnly: !canEditBody,
              maxLength: 240,
              autofocus: existing == null && canEditBody,
              onChanged: (_) => _markBodyDraftDirty(),
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '일정 제목',
                hintText: '예: 팀 회고',
              ),
              validator: (value) {
                final title = value?.trim() ?? '';
                if (title.isEmpty) return '제목을 입력해 주세요.';
                if (title.length > 240) {
                  return '제목은 240자 이하로 입력해 주세요.';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _noteController,
              readOnly: !canEditBody,
              maxLength: 10000,
              maxLines: 3,
              onChanged: (_) => _markBodyDraftDirty(),
              decoration: const InputDecoration(
                labelText: '메모 (선택)',
                hintText: '장소, 준비물, 링크 등을 적어보세요.',
              ),
              validator: (value) => (value?.length ?? 0) > 10000
                  ? '메모는 10,000자 이하로 입력해 주세요.'
                  : null,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _allDay,
              onChanged: canEditBody
                  ? (value) => setState(() {
                      _bodyDraftDirty = true;
                      _allDay = value;
                      if (value) {
                        _start = DateTime(
                          _start.year,
                          _start.month,
                          _start.day,
                        );
                        _end = DateTime(_start.year, _start.month, _start.day);
                      } else if (!_end.isAfter(_start)) {
                        _end = _start.add(const Duration(hours: 1));
                      }
                    })
                  : null,
              title: const Text('종일 일정'),
              subtitle: const Text('하루 전체를 차지하는 일정이에요.'),
            ),
            const Divider(height: 28),
            _DateTimeTile(
              label: '시작',
              value: _start,
              allDay: _allDay,
              onDate: canEditBody ? () => _pickDate(start: true) : null,
              onTime: canEditBody ? () => _pickTime(start: true) : null,
            ),
            const SizedBox(height: 10),
            _DateTimeTile(
              label: '종료',
              value: _end,
              allDay: _allDay,
              onDate: canEditBody ? () => _pickDate(start: false) : null,
              onTime: canEditBody ? () => _pickTime(start: false) : null,
            ),
            RecurrenceEditor(
              key: _recurrenceKey,
              start: _start,
              initialRule: _recurrenceRule,
              enabled: canEditBody,
              onChanged: (rule) {
                _recurrenceRule = rule;
                _markBodyDraftDirty();
              },
            ),
            if (recurringOccurrence) ...<Widget>[
              const SizedBox(height: 10),
              Semantics(
                container: true,
                label: '반복 일정 상속 안내',
                child: Text(
                  '제목·메모·색상·시간은 시리즈에서 상속돼요. 이번 일정만 수정하면 이 일정에만 적용됩니다.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 6),
              Semantics(
                container: true,
                label: '반복 일정 참여자 안내',
                child: Text(
                  '참여자는 전체 일정에 상속돼요. 전체 일정을 선택할 때만 변경할 수 있어요.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
            if (recurringEvent && existing != null && canManageParticipants)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: () => _chooseRecurrenceScope(existing),
                  icon: const Icon(Icons.tune),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _recurrenceScope == EventEditScope.all
                          ? '참여자 변경 범위: 전체 일정'
                          : '참여자 변경 범위 선택',
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ),
            Text(
              '색상',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              children: _colors.map((value) {
                final selected = value == _colorValue;
                return Semantics(
                  button: canEditBody,
                  enabled: canEditBody,
                  selected: selected,
                  label: '${_colorLabel(value)} 일정 색상',
                  child: InkWell(
                    onTap: canEditBody
                        ? () => setState(() {
                            _bodyDraftDirty = true;
                            _colorValue = value;
                          })
                        : null,
                    customBorder: const CircleBorder(),
                    child: SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: colorFromValue(value),
                          child: selected
                              ? Icon(
                                  Icons.check,
                                  color: contrastingForeground(
                                    colorFromValue(value),
                                  ),
                                  size: 20,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 6),
            _ParticipantPicker(
              members: controller.members,
              selectedMemberIds: _selectedMemberIds,
              enabled: canEditParticipants,
              protectedMemberId: protectedCreatorId,
              protectedMemberName: protectedCreatorName,
              onChanged: (memberId, selected) {
                setState(() {
                  _memberSelectionDirty = true;
                  if (selected) {
                    _selectedMemberIds.add(memberId);
                  } else {
                    _selectedMemberIds.remove(memberId);
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            EventNotificationControls(
              allDay: _allDay,
              recurring: recurringEvent || _recurrenceRule != null,
              enabled: _notificationEnabled,
              channel: _notificationChannel,
              timedLeadSeconds: _timedLeadSeconds,
              allDayDaysBefore: _allDayDaysBefore,
              localCapability: notifications.capability,
              pushCapability: notifications.pushCapability,
              applyToWholeSeries: _notificationApplyToWholeSeries,
              onEnabledChanged: canEditReminder
                  ? (value) {
                      setState(() {
                        _notificationEnabled = value;
                        _notificationDraftDirty = true;
                      });
                    }
                  : null,
              onChannelChanged: canEditReminder
                  ? (value) {
                      setState(() {
                        _notificationChannel = value;
                        _notificationDraftDirty = true;
                      });
                    }
                  : null,
              onTimedLeadChanged: canEditReminder
                  ? (value) {
                      setState(() {
                        _timedLeadSeconds = value;
                        _notificationDraftDirty = true;
                      });
                    }
                  : null,
              onAllDayDaysChanged: canEditReminder
                  ? (value) {
                      setState(() {
                        _allDayDaysBefore = value;
                        _notificationDraftDirty = true;
                      });
                    }
                  : null,
              onApplyToWholeSeriesChanged: canEditReminder
                  ? (value) {
                      setState(() {
                        _notificationApplyToWholeSeries = value;
                        _notificationDraftDirty = true;
                      });
                    }
                  : null,
            ),
            if (editorErrorMessage != null) ...<Widget>[
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                label: '오류: $editorErrorMessage',
                child: Text(
                  editorErrorMessage,
                  style: TextStyle(color: scheme.error),
                ),
              ),
              if (canRetryNotificationLoad) ...<Widget>[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: controller.isSaving
                        ? null
                        : () => _retryNotificationPreferences(
                            existing,
                            notifications,
                            controller,
                          ),
                    child: const Text('알림 설정 다시 불러오기'),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 28),
            if (canEditBody)
              FilledButton(
                onPressed: controller.isSaving ? null : _save,
                child: const Text('일정 저장하기'),
              )
            else if (canEditParticipants)
              FilledButton(
                onPressed: controller.isSaving ? null : _save,
                child: const Text('참여자 저장하기'),
              )
            else if (canEditReminder)
              FilledButton(
                onPressed: controller.isSaving ? null : _save,
                child: const Text('알림 저장하기'),
              )
            else
              OutlinedButton(
                onPressed: () => context.pop(),
                child: const Text('돌아가기'),
              ),
          ],
        ),
      ),
    );
  }
}

String _colorLabel(int value) => switch (value) {
  0xff477b76 => '청록색',
  0xffb66d58 => '산호색',
  0xff8266a5 => '보라색',
  0xff4d78a8 => '파란색',
  0xff9a7b32 => '황금색',
  _ => '사용자 지정 색상',
};

bool _sameMemberIdSet(Iterable<String> left, Iterable<String> right) {
  final leftSet = left.toSet();
  final rightSet = right.toSet();
  return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
}

class _ParticipantPicker extends StatelessWidget {
  const _ParticipantPicker({
    required this.members,
    required this.selectedMemberIds,
    required this.enabled,
    this.protectedMemberId,
    this.protectedMemberName,
    required this.onChanged,
  });

  final List<PlannerMember> members;
  final Set<String> selectedMemberIds;
  final bool enabled;
  final String? protectedMemberId;
  final String? protectedMemberName;
  final void Function(String memberId, bool selected) onChanged;

  @override
  Widget build(BuildContext context) {
    PlannerMember? protectedMember;
    final protectedId = protectedMemberId;
    if (protectedId != null) {
      for (final member in members) {
        if (member.id == protectedId) {
          protectedMember = member;
          break;
        }
      }
    }
    final activeMembers = members
        .where(
          (member) => _isSelectableMember(member) && member.id != protectedId,
        )
        .toList(growable: false);
    final activeIds = activeMembers.map((member) => member.id).toSet();
    final previousMemberIds = selectedMemberIds
        .where(
          (memberId) =>
              memberId != protectedId && !activeIds.contains(memberId),
        )
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '참여자',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '이 일정에 참여할 멤버를 선택해 주세요.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (protectedId == null &&
            activeMembers.isEmpty &&
            previousMemberIds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '선택할 수 있는 멤버가 없어요.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...<Widget>[
          if (protectedId != null && protectedMember != null)
            _ParticipantTile(
              member: protectedMember,
              selected: selectedMemberIds.contains(protectedId),
              enabled: enabled,
              protected: true,
              onChanged: (_) {},
            )
          else if (protectedId != null)
            _ProtectedMissingMemberTile(
              memberName: protectedMemberName,
              selected: selectedMemberIds.contains(protectedId),
            ),
          ...activeMembers.map(
            (member) => _ParticipantTile(
              member: member,
              selected: selectedMemberIds.contains(member.id),
              enabled: enabled,
              onChanged: (selected) => onChanged(member.id, selected),
            ),
          ),
          ...previousMemberIds.map(
            (memberId) => _PreviousMemberTile(
              selected: selectedMemberIds.contains(memberId),
              enabled: enabled,
              onChanged: (selected) => onChanged(memberId, selected),
            ),
          ),
        ],
      ],
    );
  }
}

bool _isSelectableMember(PlannerMember member) =>
    member.isActive && member.removedAt == null;

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.member,
    required this.selected,
    required this.enabled,
    this.protected = false,
    required this.onChanged,
  });

  final PlannerMember member;
  final bool selected;
  final bool enabled;
  final bool protected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final avatarColor = colorFromValue(member.avatarColor);
    final tileEnabled = enabled && !protected;
    final semanticsLabel = protected
        ? selected
              ? '참여자 ${member.name}, 작성자라서 항상 선택됨'
              : '참여자 ${member.name}, 작성자 참여 정보가 없어 저장할 수 없음'
        : '참여자 ${member.name}';
    return Semantics(
      container: true,
      // CheckboxListTile은 자체적으로 병합된 시맨틱 노드를 제공한다. 보호된 작성자에
      // 대해서는 보조 기술이 컨트롤이 잠긴 이유를 안내하도록 그 노드 위에 명시적인
      // 불변 조건과 문구를 노출한다.
      excludeSemantics: protected,
      label: semanticsLabel,
      selected: selected,
      enabled: tileEnabled,
      child: CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: selected,
        onChanged: tileEnabled ? (value) => onChanged(value ?? false) : null,
        secondary: CircleAvatar(
          backgroundColor: avatarColor,
          child: Text(
            initials(member.name),
            style: TextStyle(
              color: contrastingForeground(avatarColor),
              fontSize: 12,
            ),
          ),
        ),
        title: Text(member.name),
        subtitle: protected
            ? Text(
                selected ? '작성자는 항상 참여자로 유지돼요.' : '작성자 참여 정보를 확인해야 저장할 수 있어요.',
              )
            : null,
      ),
    );
  }
}

class _ProtectedMissingMemberTile extends StatelessWidget {
  const _ProtectedMissingMemberTile({
    required this.memberName,
    required this.selected,
  });

  final String? memberName;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final name = memberName ?? '일정 작성자';
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: selected
          ? '참여자 $name, 작성자라서 항상 선택됨'
          : '참여자 $name, 작성자 참여 정보가 없어 저장할 수 없음',
      selected: selected,
      enabled: false,
      child: CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: selected,
        onChanged: null,
        secondary: const Icon(Icons.person_outline),
        title: Text(name),
        subtitle: Text(
          selected ? '작성자는 항상 참여자로 유지돼요.' : '작성자 참여 정보를 확인해야 저장할 수 있어요.',
        ),
      ),
    );
  }
}

class _PreviousMemberTile extends StatelessWidget {
  const _PreviousMemberTile({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '참여자 이전 멤버',
      selected: selected,
      enabled: enabled,
      child: CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: selected,
        onChanged: enabled ? (value) => onChanged(value ?? false) : null,
        secondary: const Icon(Icons.person_off_outlined),
        title: const Text('이전 멤버'),
        subtitle: const Text('현재 멤버 목록에서 확인할 수 없어요.'),
      ),
    );
  }
}

class _DateTimeTile extends StatelessWidget {
  const _DateTimeTile({
    required this.label,
    required this.value,
    required this.allDay,
    required this.onDate,
    required this.onTime,
  });
  final String label;
  final DateTime value;
  final bool allDay;
  final VoidCallback? onDate;
  final VoidCallback? onTime;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14);
        final stacked = constraints.maxWidth < 380 || textScale >= 22;
        final dateButton = OutlinedButton.icon(
          onPressed: onDate,
          icon: const Icon(Icons.event_outlined, size: 19),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${value.year}년 ${value.month}월 ${value.day}일',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        final timeButton = OutlinedButton(
          onPressed: onTime,
          child: Text(
            formatTime(value),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
        if (stacked && !allDay) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 48,
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  Expanded(child: dateButton),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 8),
                child: SizedBox(width: double.infinity, child: timeButton),
              ),
            ],
          );
        }
        return Row(
          children: <Widget>[
            SizedBox(
              width: 48,
              child: Text(label, style: Theme.of(context).textTheme.labelLarge),
            ),
            Expanded(child: dateButton),
            if (!allDay) ...<Widget>[const SizedBox(width: 8), timeButton],
          ],
        );
      },
    );
  }
}
