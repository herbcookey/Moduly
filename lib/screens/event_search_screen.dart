import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
import '../state/app_state.dart';

/// 서버 기반 일정 검색이다. 검색은 의도적으로 달력과 별도의 경로 및 프로젝션으로
/// 구성한다. 컨트롤러가 디바운스와 취소를 담당하고, 이 화면은 제한된 필터를
/// 제공하며 서버가 반환한 완전한 일정 행만 렌더링한다.
class EventSearchScreen extends ConsumerStatefulWidget {
  const EventSearchScreen({super.key});

  @override
  ConsumerState<EventSearchScreen> createState() => _EventSearchScreenState();
}

class _EventSearchScreenState extends ConsumerState<EventSearchScreen> {
  late final TextEditingController _queryController;
  DateTime? _rangeStart;
  DateTime? _rangeEndInclusive;
  bool _didInitialize = false;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeSearch());
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _initializeSearch() {
    if (!mounted) return;
    final controller = ref.read(plannerControllerProvider);
    final group = controller.selectedGroup;
    if (group == null) return;
    final range = controller.searchRange ?? _defaultMonthRange(controller);
    _setRangeDatesFromRange(range, group.timezone);
    if (!_didInitialize) {
      _didInitialize = true;
      // 빈 쿼리는 지원되는 기간/필터 전용 검색이다. 진입 시 요청을 즉시 한 번
      // 실행하고 setSearchFilters를 통해 같은 작업을 다시 예약하지 않는다.
      unawaited(
        controller.searchEvents(
          range: range,
          query: controller.searchQuery,
          creatorId: controller.searchCreatorId,
          participantId: controller.searchParticipantId,
          immediate: true,
        ),
      );
    }
    _syncScheduled = false;
    setState(() {});
  }

  EventRange _defaultMonthRange(PlannerController controller) {
    final group = controller.selectedGroup!;
    final selected = controller.selectedDay;
    return calendarAgendaBounds(
      selected.year,
      selected.month,
      group.timezone,
    ).toEventRange();
  }

  void _setRangeDatesFromRange(EventRange range, String timezone) {
    final start = utcToWallTime(range.startUtc, timezone);
    // 종료점은 포함하지 않는다. 1마이크로초를 빼면 DST로 짧거나 긴 날의 끝에서도
    // 현지 시각으로 되돌리기 전에 날짜를 보존할 수 있다.
    final end = utcToWallTime(
      range.endUtc.subtract(const Duration(microseconds: 1)),
      timezone,
    );
    _rangeStart = dateOnly(start);
    _rangeEndInclusive = dateOnly(end);
  }

  EventRange _currentRange(PlannerController controller) {
    return controller.searchRange ?? _defaultMonthRange(controller);
  }

  void _scheduleControllerSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      final controller = ref.read(plannerControllerProvider);
      final group = controller.selectedGroup;
      if (group == null) return;
      if (_queryController.text != controller.searchQuery) {
        _queryController.value = TextEditingValue(
          text: controller.searchQuery,
          selection: TextSelection.collapsed(
            offset: controller.searchQuery.length,
          ),
        );
      }
      final range = controller.searchRange;
      if (range != null) {
        final expectedStart = dateOnly(
          utcToWallTime(range.startUtc, group.timezone),
        );
        final expectedEnd = dateOnly(
          utcToWallTime(
            range.endUtc.subtract(const Duration(microseconds: 1)),
            group.timezone,
          ),
        );
        if (_rangeStart != expectedStart || _rangeEndInclusive != expectedEnd) {
          _setRangeDatesFromRange(range, group.timezone);
          setState(() {});
        }
      }
    });
  }

  void _setCreatorFilter(String? memberId) {
    final controller = ref.read(plannerControllerProvider);
    if (memberId == null || memberId.isEmpty) {
      controller.setSearchFilters(clearCreator: true);
    } else {
      controller.setSearchFilters(creatorId: memberId);
    }
  }

  void _setParticipantFilter(String? memberId) {
    final controller = ref.read(plannerControllerProvider);
    if (memberId == null || memberId.isEmpty) {
      controller.setSearchFilters(clearParticipant: true);
    } else {
      controller.setSearchFilters(participantId: memberId);
    }
  }

  Future<void> _pickDateRange(BuildContext context) async {
    final controller = ref.read(plannerControllerProvider);
    final group = controller.selectedGroup;
    if (group == null) return;
    final currentRange = _currentRange(controller);
    final currentStart =
        _rangeStart ??
        dateOnly(utcToWallTime(currentRange.startUtc, group.timezone));
    final currentEnd =
        _rangeEndInclusive ??
        dateOnly(
          utcToWallTime(
            currentRange.endUtc.subtract(const Duration(microseconds: 1)),
            group.timezone,
          ),
        );
    final pickerStart = CalendarDateBounds.clamp(currentStart);
    final pickerEnd = CalendarDateBounds.clamp(currentEnd);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: CalendarDateBounds.firstDate,
      lastDate: CalendarDateBounds.lastDate,
      initialDateRange: DateTimeRange(start: pickerStart, end: pickerEnd),
      helpText: '검색 날짜 범위',
      cancelText: '취소',
      confirmText: '선택',
    );
    if (!context.mounted || picked == null) return;
    final startDate = dateOnly(picked.start);
    final endInclusive = dateOnly(picked.end);
    final endExclusive = calendarDateAdd(endInclusive, 1);
    final startUtc = wallTimeToUtc(startDate, group.timezone);
    final endUtc = wallTimeToUtc(endExclusive, group.timezone);
    if (calendarDateSpan(startUtc, endUtc, group.timezone) > 366) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('검색 범위는 366일 이내로 선택해 주세요.')));
      return;
    }
    final range = EventRange(
      startUtc: startUtc,
      endUtc: endUtc,
      viewTimezone: group.timezone,
    );
    setState(() {
      _rangeStart = startDate;
      _rangeEndInclusive = endInclusive;
    });
    controller.setSearchFilters(range: range);
  }

  void _resetDateRange() {
    final controller = ref.read(plannerControllerProvider);
    final group = controller.selectedGroup;
    if (group == null) return;
    final range = _defaultMonthRange(controller);
    _setRangeDatesFromRange(range, group.timezone);
    setState(() {});
    controller.setSearchFilters(range: range);
  }

  void _submitImmediately() {
    final controller = ref.read(plannerControllerProvider);
    final group = controller.selectedGroup;
    if (group == null) return;
    unawaited(
      controller.searchEvents(
        range: _currentRange(controller),
        query: _queryController.text,
        creatorId: controller.searchCreatorId,
        participantId: controller.searchParticipantId,
        immediate: true,
      ),
    );
  }

  void _cancelSearch() {
    final controller = ref.read(plannerControllerProvider);
    controller.cancelSearch();
    _queryController.clear();
    _didInitialize = true;
    final group = controller.selectedGroup;
    if (group != null) {
      _setRangeDatesFromRange(_defaultMonthRange(controller), group.timezone);
    }
    if (mounted) setState(() {});
  }

  DateTime _eventWallStart(PlannerEvent event, String timezone) {
    if (event.allDay && event.allDayStartDate != null) {
      return dateOnly(event.allDayStartDate!);
    }
    return utcToWallTime(event.startAt, timezone);
  }

  String _eventDateLabel(PlannerEvent event, String timezone) {
    final wall = _eventWallStart(event, timezone);
    final date = '${wall.year}년 ${wall.month}월 ${wall.day}일';
    if (event.allDay) return '$date · 종일';
    final hour = wall.hour == 0
        ? 12
        : (wall.hour > 12 ? wall.hour - 12 : wall.hour);
    final period = wall.hour < 12 ? '오전' : '오후';
    return '$date · $period $hour:${wall.minute.toString().padLeft(2, '0')}';
  }

  String _memberLabel(PlannerController controller, String memberId) {
    final member = controller.members
        .where((candidate) => candidate.id == memberId)
        .firstOrNull;
    if (member == null || !member.isActive) return '이전 멤버';
    final name = member.name.trim();
    return name.isEmpty ? member.email : name;
  }

  String _creatorLabel(PlannerController controller, PlannerEvent event) {
    return _memberLabel(controller, event.ownerId);
  }

  String _participantLabel(PlannerController controller, PlannerEvent event) {
    if (event.memberIds.isEmpty) return '참여자 없음';
    return event.memberIds
        .map((memberId) => _memberLabel(controller, memberId))
        .join(', ');
  }

  void _openEvent(
    BuildContext context,
    PlannerController controller,
    PlannerEvent event,
  ) {
    final group = controller.selectedGroup;
    if (group == null) return;
    controller.setSelectedDay(_eventWallStart(event, group.timezone));
    final isOccurrence = event.occurrenceKey != 'single';
    final routeId = isOccurrence && event.seriesId.trim().isNotEmpty
        ? event.seriesId
        : event.id;
    final encodedId = Uri.encodeComponent(routeId);
    final occurrence = isOccurrence
        ? '?occurrence=${Uri.encodeQueryComponent(event.occurrenceKey)}'
        : '';
    context.push('/event/$encodedId$occurrence');
  }

  Widget _rangeButton(
    BuildContext context,
    PlannerController controller,
    EventRange range,
  ) {
    final group = controller.selectedGroup!;
    final start =
        _rangeStart ?? dateOnly(utcToWallTime(range.startUtc, group.timezone));
    final end =
        _rangeEndInclusive ??
        dateOnly(
          utcToWallTime(
            range.endUtc.subtract(const Duration(microseconds: 1)),
            group.timezone,
          ),
        );
    final label =
        '${start.year}.${start.month}.${start.day} – '
        '${end.year}.${end.month}.${end.day}';
    return Semantics(
      button: true,
      label: '검색 날짜 범위 $label',
      child: OutlinedButton.icon(
        onPressed: () => _pickDateRange(context),
        icon: const Icon(Icons.date_range_outlined),
        label: Text(label, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }

  List<DropdownMenuItem<String>> _memberItems(
    PlannerController controller,
    String allLabel,
  ) {
    final activeMembers = controller.members
        .where((member) => member.isActive)
        .toList(growable: false);
    return <DropdownMenuItem<String>>[
      DropdownMenuItem<String>(value: '', child: Text(allLabel)),
      ...activeMembers.map(
        (member) => DropdownMenuItem<String>(
          value: member.id,
          child: Text(
            member.name.trim().isEmpty ? member.email : member.name,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ];
  }

  Widget _filterDropdown({
    required String label,
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    required VoidCallback? onClear,
  }) {
    return DropdownButtonFormField<String>(
      key: ValueKey<String>('$label-${value ?? ''}'),
      initialValue: value ?? '',
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: value == null
            ? null
            : IconButton(
                tooltip: '$label 지우기',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: onClear,
                icon: const Icon(Icons.clear),
              ),
      ),
      items: items,
      onChanged: onChanged,
    );
  }

  Widget _searchField(PlannerController controller) {
    final hasQuery = _queryController.text.isNotEmpty;
    final normalizedQuery = _queryController.text.trim();
    final invalidShortQuery =
        normalizedQuery.isNotEmpty &&
        normalizedQuery.runes.length < eventSearchMinScalars;
    return Semantics(
      textField: true,
      label: '일정 검색어',
      hint: '비워 두면 날짜와 필터로 검색합니다. 두 글자 이상 입력하세요.',
      child: TextField(
        controller: _queryController,
        // Flutter 내장 카운터는 UTF-16 코드 단위를 세지만 서버 계약은 Unicode
        // 스칼라와 UTF-8 바이트를 센다. 이모지나 다른 보조 평면 문자를 미리 잘라내지
        // 말고 컨트롤러가 표준 검증을 수행하게 한다.
        maxLengthEnforcement: MaxLengthEnforcement.none,
        buildCounter:
            (
              BuildContext context, {
              required int currentLength,
              required bool isFocused,
              required int? maxLength,
            }) => null,
        textInputAction: TextInputAction.search,
        onChanged: controller.setSearchQuery,
        onSubmitted: (_) => _submitImmediately(),
        decoration: InputDecoration(
          labelText: '일정 검색',
          hintText: '제목 또는 설명',
          helperText: invalidShortQuery
              ? '검색어는 두 글자 이상 입력하거나 비워 두세요.'
              : '제목과 설명에서 검색합니다. 최대 100자(UTF-8 400바이트)입니다.',
          errorText: invalidShortQuery ? '검색어는 두 글자 이상 입력하거나 비워 두세요.' : null,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: hasQuery
              ? IconButton(
                  tooltip: '검색어 지우기',
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  onPressed: () {
                    _queryController.clear();
                    controller.setSearchQuery('');
                  },
                  icon: const Icon(Icons.clear),
                )
              : null,
        ),
      ),
    );
  }

  Widget _errorBanner(PlannerController controller) {
    final showRetry = controller.hasActiveSearch && !controller.isSearching;
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  controller.searchError ?? '검색에 실패했어요.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
            if (showRetry)
              TextButton(
                onPressed: () =>
                    unawaited(controller.refreshSearch(force: true)),
                child: const Text('다시 시도'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _resultTile(
    BuildContext context,
    PlannerController controller,
    PlannerEvent event,
  ) {
    final group = controller.selectedGroup!;
    final dateLabel = _eventDateLabel(event, group.timezone);
    final creator = _creatorLabel(controller, event);
    final participants = _participantLabel(controller, event);
    final occurrence = event.occurrenceKey == 'single' ? '' : ', 반복 일정';
    return Semantics(
      button: true,
      label:
          '${event.title}, $dateLabel, 작성자 $creator, 참여자 $participants$occurrence',
      child: Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          onTap: () => _openEvent(context, controller, event),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 4,
                    height: 56,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      color: colorFromValue(event.colorValue),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          event.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          dateLabel,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '작성자 $creator · 참여자 $participants',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(plannerControllerProvider);
    _scheduleControllerSync();
    final group = controller.selectedGroup;
    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('일정 검색')),
        body: const Center(child: Text('먼저 그룹을 선택해 주세요.')),
      );
    }
    final range = _currentRange(controller);
    final creatorItems = _memberItems(controller, '모든 작성자');
    final participantItems = _memberItems(controller, '모든 참여자');
    final activeMemberIds = controller.members
        .where((member) => member.isActive)
        .map((member) => member.id)
        .toSet();
    final creatorValue = activeMemberIds.contains(controller.searchCreatorId)
        ? controller.searchCreatorId
        : null;
    final participantValue =
        activeMemberIds.contains(controller.searchParticipantId)
        ? controller.searchParticipantId
        : null;
    final showLoading =
        controller.isSearching && controller.searchResults.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('일정 검색'),
        actions: <Widget>[
          if (controller.isSearching ||
              controller.searchQuery.isNotEmpty ||
              controller.searchResults.isNotEmpty)
            IconButton(
              tooltip: '검색 취소',
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
              onPressed: _cancelSearch,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => controller.refreshSearch(force: true),
        child: CustomScrollView(
          key: const PageStorageKey<String>('event-search-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              sliver: SliverToBoxAdapter(child: _searchField(controller)),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    _rangeButton(context, controller, range),
                    Semantics(
                      button: true,
                      label: '검색 날짜 범위 초기화',
                      child: IconButton(
                        tooltip: '이번 달로 초기화',
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        onPressed: _resetDateRange,
                        icon: const Icon(Icons.restart_alt),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: <Widget>[
                    _filterDropdown(
                      label: '작성자 필터',
                      value: creatorValue,
                      items: creatorItems,
                      onChanged: (value) => _setCreatorFilter(
                        value == null || value.isEmpty ? null : value,
                      ),
                      onClear: () => _setCreatorFilter(null),
                    ),
                    const SizedBox(height: 10),
                    _filterDropdown(
                      label: '참여자 필터',
                      value: participantValue,
                      items: participantItems,
                      onChanged: (value) => _setParticipantFilter(
                        value == null || value.isEmpty ? null : value,
                      ),
                      onClear: () => _setParticipantFilter(null),
                    ),
                  ],
                ),
              ),
            ),
            if (controller.searchError != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                sliver: SliverToBoxAdapter(child: _errorBanner(controller)),
              ),
            if (showLoading)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Semantics(
                    liveRegion: true,
                    label: '검색 결과를 불러오는 중',
                    child: CircularProgressIndicator(),
                  ),
                ),
              )
            else if (controller.searchResults.isEmpty &&
                controller.searchError == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '검색 결과가 없어요.\n검색어를 비우면 날짜와 필터로 찾을 수 있어요.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                sliver: SliverList.builder(
                  itemCount: controller.searchResults.length,
                  itemBuilder: (context, index) => _resultTile(
                    context,
                    controller,
                    controller.searchResults[index],
                  ),
                ),
              ),
            if (controller.hasMoreSearchResults)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                sliver: SliverToBoxAdapter(
                  child: OutlinedButton.icon(
                    onPressed: controller.isLoadingMoreSearch
                        ? null
                        : () => unawaited(controller.loadMoreSearchResults()),
                    icon: controller.isLoadingMoreSearch
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.expand_more),
                    label: Text(
                      controller.isLoadingMoreSearch ? '불러오는 중…' : '더 불러오기',
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }
}
