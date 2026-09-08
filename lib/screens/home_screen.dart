import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
import 'widgets/recurrence_controls.dart';
import '../state/app_state.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  List<DateTime> _week(DateTime selected) {
    final monday = DateTime(
      selected.year,
      selected.month,
      selected.day,
    ).subtract(Duration(days: selected.weekday - 1));
    return List<DateTime>.generate(
      7,
      (index) => monday.add(Duration(days: index)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(plannerControllerProvider);
    final group = controller.selectedGroup;
    final scheme = Theme.of(context).colorScheme;
    final view = controller.calendarView;
    final week = _week(controller.selectedDay);
    // 레거시 어댑터는 제한된 범위 불러오기를 노출하지 않으므로 일정 스냅샷이
    // 비어 있는 동안에는 그룹 선택이 유일한 로딩 플래그를 소유한다. 재시도 가능한
    // 범위 오류를 관련 없는 전역 로딩 표시로 바꾸지 말고 계속 표시한다.
    final showEmptyLoading =
        controller.events.isEmpty &&
        controller.rangeError == null &&
        (controller.isLoading || controller.isLoadingEvents);
    final scrollView = RefreshIndicator(
      onRefresh: controller.refreshSelectedEventRange,
      child: CustomScrollView(
        key: const PageStorageKey<String>('calendar-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: _CalendarToolbar(controller: controller),
            ),
          ),
          if (view == CalendarViewMode.day)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: _WeekStrip(
                  days: week,
                  selected: controller.selectedDay,
                  timezone: group?.timezone ?? 'UTC',
                  onSelected: controller.setSelectedDay,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: _MemberFilter(controller: controller),
            ),
          ),
          if (controller.rangeError != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: _RangeErrorBanner(
                  message: controller.rangeError!,
                  enabled: !controller.isLoadingEvents,
                  onRetry: controller.refreshSelectedEventRange,
                ),
              ),
            ),
          if (controller.isLoadingEvents && controller.events.isNotEmpty)
            SliverToBoxAdapter(
              child: Semantics(
                liveRegion: true,
                label: '일정을 불러오는 중',
                child: const LinearProgressIndicator(minHeight: 3),
              ),
            ),
          if (showEmptyLoading)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Semantics(
                  liveRegion: true,
                  label: '일정을 불러오는 중',
                  child: const CircularProgressIndicator(),
                ),
              ),
            )
          else
            ..._contentSlivers(
              context,
              controller: controller,
              view: view,
              timezone: group?.timezone ?? 'UTC',
            ),
        ],
      ),
    );
    final calendarBody = view == CalendarViewMode.day
        ? _DaySwipeDetector(
            onPreviousDay: () => controller.moveSelectedDay(-1),
            onNextDay: () => controller.moveSelectedDay(1),
            child: scrollView,
          )
        : scrollView;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              group?.name ?? '캘린더',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (controller.isOffline)
              Text(
                '동기화 문제 · 새로고침이 필요해요',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '일정 검색',
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            onPressed: () => context.push('/search'),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: '그룹 바꾸기',
            onPressed: () => context.go('/groups'),
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      floatingActionButton: Semantics(
        button: true,
        label: '일정 추가',
        child: FloatingActionButton.extended(
          onPressed: () => context.push('/event/new'),
          icon: const Icon(Icons.add),
          label: const Text('일정 추가'),
        ),
      ),
      body: calendarBody,
    );
  }

  List<Widget> _contentSlivers(
    BuildContext context, {
    required PlannerController controller,
    required CalendarViewMode view,
    required String timezone,
  }) {
    final events = controller.events
        .where(
          (event) =>
              !event.isDeleted &&
              (controller.showAllMembers ||
                  controller.selectedMemberId == null ||
                  event.memberIds.contains(controller.selectedMemberId)),
        )
        .toList(growable: false);
    final bottomPadding = 100 + MediaQuery.viewInsetsOf(context).bottom;
    if (view == CalendarViewMode.month) {
      return <Widget>[
        _MonthGrid(
          selectedDay: controller.selectedDay,
          timezone: timezone,
          events: events,
          onSelected: controller.setSelectedDay,
        ),
        if (events.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: _EmptyCalendar(view: CalendarViewMode.month),
            ),
          ),
        _LoadMoreSliver(controller: controller),
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ];
    }
    if (view == CalendarViewMode.agenda) {
      if (events.isEmpty) {
        return <Widget>[
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyCalendar(view: CalendarViewMode.agenda),
          ),
        ];
      }
      return <Widget>[
        _AgendaSliver(
          selectedDay: controller.selectedDay,
          timezone: timezone,
          events: events,
          members: controller.members,
        ),
        _LoadMoreSliver(controller: controller),
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ];
    }

    final visibleEvents = controller.visibleEvents;
    if (visibleEvents.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyCalendar(view: CalendarViewMode.day),
        ),
        _LoadMoreSliver(controller: controller),
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ];
    }
    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        sliver: SliverList.builder(
          itemCount: visibleEvents.length,
          itemBuilder: (context, index) {
            final event = visibleEvents[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _EventCard(event: event, members: controller.members),
            );
          },
        ),
      ),
      _LoadMoreSliver(controller: controller),
      SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
    ];
  }
}

class _CalendarToolbar extends StatelessWidget {
  const _CalendarToolbar({required this.controller});

  final PlannerController controller;

  String _heading() {
    final day = controller.selectedDay;
    return switch (controller.calendarView) {
      CalendarViewMode.day => '${day.year}년 ${day.month}월 ${day.day}일',
      CalendarViewMode.month ||
      CalendarViewMode.agenda => '${day.year}년 ${day.month}월',
    };
  }

  void _movePeriod(int direction) {
    if (controller.calendarView == CalendarViewMode.day) {
      controller.moveSelectedDay(direction);
      return;
    }
    final day = controller.selectedDay;
    controller.setSelectedDay(DateTime(day.year, day.month + direction, 1));
  }

  Future<void> _pickDate(BuildContext context) async {
    final initialDate = CalendarDateBounds.clamp(controller.selectedDay);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: CalendarDateBounds.firstDate,
      lastDate: CalendarDateBounds.lastDate,
      helpText: '날짜 선택',
      cancelText: '취소',
      confirmText: '선택',
    );
    if (picked != null && context.mounted) {
      controller.setSelectedDay(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          container: true,
          label: '달력 보기 선택',
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SegmentedButton<CalendarViewMode>(
              segments: const <ButtonSegment<CalendarViewMode>>[
                ButtonSegment<CalendarViewMode>(
                  value: CalendarViewMode.day,
                  label: Text('일간'),
                ),
                ButtonSegment<CalendarViewMode>(
                  value: CalendarViewMode.month,
                  label: Text('월간'),
                ),
                ButtonSegment<CalendarViewMode>(
                  value: CalendarViewMode.agenda,
                  label: Text('일정 목록'),
                ),
              ],
              selected: <CalendarViewMode>{controller.calendarView},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  controller.setCalendarView(selection.first);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: Text(
            _heading(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 2),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: '이전 기간',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: () => _movePeriod(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: '다음 기간',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: () => _movePeriod(1),
                icon: const Icon(Icons.chevron_right),
              ),
              const SizedBox(width: 2),
              FilledButton.tonal(
                onPressed: controller.jumpToToday,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('오늘'),
              ),
              IconButton(
                tooltip: '날짜 선택',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: () => _pickDate(context),
                icon: const Icon(Icons.calendar_today_outlined),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RangeErrorBanner extends StatelessWidget {
  const _RangeErrorBanner({
    required this.message,
    required this.enabled,
    required this.onRetry,
  });

  final String message;
  final bool enabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: '오류: $message',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            const SizedBox(height: 6),
            OutlinedButton(
              onPressed: enabled ? onRetry : null,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              child: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader({required this.cellWidth, required this.gap});

  static const _labels = <String>['월', '화', '수', '목', '금', '토', '일'];

  final double cellWidth;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      for (var index = 0; index < _labels.length; index++) ...<Widget>[
        SizedBox(
          key: ValueKey<String>('calendar-weekday-$index'),
          width: cellWidth,
          child: Semantics(
            label: '${_labels[index]}요일',
            child: Text(
              _labels[index],
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        if (index < _labels.length - 1) SizedBox(width: gap),
      ],
    ],
  );
}

class _MonthGrid extends StatefulWidget {
  const _MonthGrid({
    required this.selectedDay,
    required this.timezone,
    required this.events,
    required this.onSelected,
  });

  final DateTime selectedDay;
  final String timezone;
  final List<PlannerEvent> events;
  final ValueChanged<DateTime> onSelected;

  @override
  State<_MonthGrid> createState() => _MonthGridState();
}

class _MonthGridState extends State<_MonthGrid> {
  DateTime? _keyboardDate;

  void _select(DateTime date) {
    _keyboardDate = date;
    widget.onSelected(date);
  }

  void _navigate(DateTime origin, int offset) {
    final current = _keyboardDate;
    final sameMonth =
        current != null &&
        current.year == widget.selectedDay.year &&
        current.month == widget.selectedDay.month;
    final base = sameMonth ? current : origin;
    final target = calendarDateAdd(base, offset);
    _keyboardDate = target;
    widget.onSelected(target);
  }

  @override
  Widget build(BuildContext context) {
    final bounds = calendarMonthBounds(
      widget.selectedDay.year,
      widget.selectedDay.month,
      widget.timezone,
    );
    final totalDays =
        DateTime.utc(
              bounds.endDate.year,
              bounds.endDate.month,
              bounds.endDate.day,
            )
            .difference(
              DateTime.utc(
                bounds.startDate.year,
                bounds.startDate.month,
                bounds.startDate.day,
              ),
            )
            .inDays;
    final today = dateOnly(
      utcToWallTime(DateTime.now().toUtc(), widget.timezone),
    );
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const gap = 4.0;
            const minCellWidth = 48.0;
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : minCellWidth * 7 + gap * 6;
            final cellWidth = ((availableWidth - gap * 6) / 7).clamp(
              minCellWidth,
              double.infinity,
            );
            final gridWidth = cellWidth * 7 + gap * 6;
            final textScale = MediaQuery.textScalerOf(context).scale(1);
            final mainAxisExtent = availableWidth < 420
                ? (textScale > 1.5 ? 112.0 : 76.0)
                : (textScale > 1.5 ? 120.0 : 96.0);
            final cells = List<Widget>.generate(totalDays, (index) {
              final date = calendarDateAdd(bounds.startDate, index);
              final inMonth = date.month == widget.selectedDay.month;
              final selected = _sameDate(date, widget.selectedDay);
              final isToday = _sameDate(date, today);
              final dayEvents = widget.events
                  .where(
                    (event) =>
                        eventOverlapsCalendarDate(event, date, widget.timezone),
                  )
                  .toList(growable: false);
              return SizedBox(
                width: cellWidth,
                height: mainAxisExtent,
                child: _MonthCell(
                  date: date,
                  selected: selected,
                  today: isToday,
                  inMonth: inMonth,
                  events: dayEvents,
                  onTap: () => _select(date),
                  onNavigate: (offset) => _navigate(date, offset),
                ),
              );
            });
            return Semantics(
              container: true,
              label: '월간 일정 그리드',
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: gridWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _WeekdayHeader(cellWidth: cellWidth, gap: gap),
                      const SizedBox(height: 8),
                      Wrap(spacing: gap, runSpacing: gap, children: cells),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.date,
    required this.selected,
    required this.today,
    required this.inMonth,
    required this.events,
    required this.onTap,
    required this.onNavigate,
  });

  final DateTime date;
  final bool selected;
  final bool today;
  final bool inMonth;
  final List<PlannerEvent> events;
  final VoidCallback onTap;
  final ValueChanged<int> onNavigate;

  String get _dateLabel => '${date.year}년 ${date.month}월 ${date.day}일';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final eventNames = events.take(3).map((event) => event.title).join(', ');
    final state = <String>[
      if (today) '오늘',
      if (selected) '선택됨',
      if (!inMonth) '해당 월 외',
      if (events.any(_isRecurringEvent))
        '반복 일정 ${events.where(_isRecurringEvent).length}개',
    ];
    final label =
        '$_dateLabel${state.isEmpty ? '' : ', ${state.join(', ')}'}'
        ', 일정 ${events.length}개${eventNames.isEmpty ? '' : ', $eventNames'}';
    return Semantics(
      key: ValueKey<String>(
        'calendar-cell-${date.year}-${date.month}-${date.day}',
      ),
      container: true,
      button: true,
      selected: selected,
      label: label,
      child: Focus(
        autofocus: selected,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final offset = switch (event.logicalKey) {
            LogicalKeyboardKey.arrowLeft => -1,
            LogicalKeyboardKey.arrowRight => 1,
            LogicalKeyboardKey.arrowUp => -7,
            LogicalKeyboardKey.arrowDown => 7,
            _ => null,
          };
          if (offset == null) return KeyEventResult.ignored;
          onNavigate(offset);
          return KeyEventResult.handled;
        },
        child: Material(
          color: selected
              ? scheme.primaryContainer
              : (today ? scheme.secondaryContainer : scheme.surface),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < 68 ||
                    MediaQuery.textScalerOf(context).scale(12) > 17;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(6, 5, 6, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${date.day}',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: inMonth
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 3),
                      if (events.isEmpty)
                        const Spacer()
                      else if (compact)
                        ExcludeSemantics(
                          child: Row(
                            children: <Widget>[
                              ...events
                                  .take(3)
                                  .map(
                                    (event) => Padding(
                                      padding: const EdgeInsets.only(right: 3),
                                      child: Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: colorFromValue(
                                            event.colorValue,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              if (events.length > 3)
                                Flexible(
                                  child: Text(
                                    '+${events.length - 3}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                ),
                              if (events.length <= 2 &&
                                  events.any(_isRecurringEvent))
                                Padding(
                                  padding: const EdgeInsets.only(left: 2),
                                  child: Icon(
                                    Icons.repeat,
                                    size: 14,
                                    color: scheme.primary,
                                  ),
                                ),
                            ],
                          ),
                        )
                      else
                        ...events
                            .take(2)
                            .map(
                              (event) => Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: ExcludeSemantics(
                                  child: Row(
                                    children: <Widget>[
                                      if (_isRecurringEvent(event))
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 3,
                                          ),
                                          child: Icon(
                                            Icons.repeat,
                                            size: 12,
                                            color: scheme.primary,
                                          ),
                                        ),
                                      Expanded(
                                        child: Text(
                                          event.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                      if (!compact && events.length > 2)
                        ExcludeSemantics(
                          child: Text(
                            '+${events.length - 2}개',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AgendaSliver extends StatelessWidget {
  const _AgendaSliver({
    required this.selectedDay,
    required this.timezone,
    required this.events,
    required this.members,
  });

  final DateTime selectedDay;
  final String timezone;
  final List<PlannerEvent> events;
  final List<PlannerMember> members;

  @override
  Widget build(BuildContext context) {
    final groups = <DateTime, List<PlannerEvent>>{};
    final monthStart = DateTime(selectedDay.year, selectedDay.month);
    final monthEnd = DateTime(selectedDay.year, selectedDay.month + 1);
    for (final event in events) {
      var date = _eventStartDate(event, timezone);
      if (date.isBefore(monthStart)) date = monthStart;
      if (!date.isBefore(monthEnd)) date = calendarDateAdd(monthEnd, -1);
      groups.putIfAbsent(date, () => <PlannerEvent>[]).add(event);
    }
    final dates = groups.keys.toList()..sort();
    final entries = <_AgendaEntry>[];
    for (final date in dates) {
      final dayEvents = groups[date]!
        ..sort((a, b) {
          if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
          final byStart = a.startAt.compareTo(b.startAt);
          if (byStart != 0) return byStart;
          final byId = a.id.compareTo(b.id);
          return byId != 0 ? byId : a.occurrenceKey.compareTo(b.occurrenceKey);
        });
      entries.add(_AgendaEntry.header(date));
      entries.addAll(dayEvents.map((event) => _AgendaEntry.event(date, event)));
    }
    return SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.event == null) {
          return Padding(
            padding: EdgeInsets.fromLTRB(index == 0 ? 20 : 20, 14, 20, 8),
            child: Semantics(
              header: true,
              child: Text(
                _formatDate(entry.date),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          );
        }
        final event = entry.event!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: _EventCard(
            event: event,
            members: members,
            contextLabel: _agendaContextLabel(event, entry.date, timezone),
          ),
        );
      },
    );
  }
}

class _AgendaEntry {
  const _AgendaEntry.header(this.date) : event = null;
  const _AgendaEntry.event(this.date, this.event);

  final DateTime date;
  final PlannerEvent? event;
}

class _LoadMoreSliver extends StatelessWidget {
  const _LoadMoreSliver({required this.controller});

  final PlannerController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.hasMoreEvents) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: FilledButton.tonal(
          key: const ValueKey<String>('calendar-load-more'),
          onPressed: controller.isLoadingMoreEvents
              ? null
              : controller.loadMoreEvents,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          child: controller.isLoadingMoreEvents
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('더 불러오기'),
        ),
      ),
    );
  }
}

class _EmptyCalendar extends StatelessWidget {
  const _EmptyCalendar({required this.view});

  final CalendarViewMode view;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = switch (view) {
      CalendarViewMode.day => '비어 있는 하루예요',
      CalendarViewMode.month => '비어 있는 달이에요',
      CalendarViewMode.agenda => '이번 달에는 일정이 없어요',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.wb_sunny_outlined, size: 52, color: scheme.primary),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '오른쪽 아래 버튼으로 첫 일정을 추가해 보세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _DaySwipeDetector extends StatefulWidget {
  const _DaySwipeDetector({
    required this.child,
    required this.onPreviousDay,
    required this.onNextDay,
  });

  final Widget child;
  final VoidCallback onPreviousDay;
  final VoidCallback onNextDay;

  @override
  State<_DaySwipeDetector> createState() => _DaySwipeDetectorState();
}

class _DaySwipeDetectorState extends State<_DaySwipeDetector> {
  static const double _distanceThreshold = 48;
  static const double _velocityThreshold = 300;
  double _dragDistance = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragStart: (_) => _dragDistance = 0,
    onHorizontalDragUpdate: (details) {
      _dragDistance += details.primaryDelta ?? 0;
    },
    onHorizontalDragCancel: () => _dragDistance = 0,
    onHorizontalDragEnd: (details) {
      final velocity = details.primaryVelocity ?? 0;
      final movedEnough = _dragDistance.abs() >= _distanceThreshold;
      final fastEnough = velocity.abs() >= _velocityThreshold;
      if (!movedEnough && !fastEnough) {
        _dragDistance = 0;
        return;
      }

      final direction = _dragDistance.abs() >= 1 ? _dragDistance : velocity;
      _dragDistance = 0;
      if (direction < 0) {
        widget.onNextDay();
      } else {
        widget.onPreviousDay();
      }
    },
    child: widget.child,
  );
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.days,
    required this.selected,
    required this.timezone,
    required this.onSelected,
  });
  final List<DateTime> days;
  final DateTime selected;
  final String timezone;
  final ValueChanged<DateTime> onSelected;

  static const _labels = <String>['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = utcToWallTime(DateTime.now().toUtc(), timezone);
    return LayoutBuilder(
      builder: (context, constraints) {
        const minimumWidth = 48.0 * 7;
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : minimumWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width < minimumWidth ? minimumWidth : width,
            child: Row(
              children: days.map((day) {
                final isSelected =
                    day.year == selected.year &&
                    day.month == selected.month &&
                    day.day == selected.day;
                final isToday =
                    day.year == today.year &&
                    day.month == today.month &&
                    day.day == today.day;
                return Expanded(
                  child: Semantics(
                    button: true,
                    selected: isSelected,
                    label:
                        '${day.month}월 ${day.day}일 ${_labels[day.weekday - 1]}요일',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => onSelected(day),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? scheme.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: isToday && !isSelected
                              ? Border.all(color: scheme.primary, width: 1.5)
                              : null,
                        ),
                        child: Column(
                          children: <Widget>[
                            Text(
                              _labels[day.weekday - 1],
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: isSelected
                                        ? scheme.onPrimary
                                        : scheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${day.day}',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: isSelected
                                        ? scheme.onPrimary
                                        : scheme.onSurface,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }
}

class _MemberFilter extends StatelessWidget {
  const _MemberFilter({required this.controller});
  final PlannerController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedName = controller.members
        .where((member) => member.id == controller.selectedMemberId)
        .firstOrNull
        ?.name;
    final filterLabel = controller.showAllMembers
        ? '모든 참여자'
        : (selectedName ?? '참여자');
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '일정',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Flexible(
          child: Semantics(
            button: true,
            label: '참여자 필터: $filterLabel',
            child: PopupMenuButton<String>(
              initialValue: controller.showAllMembers
                  ? _allMembers
                  : controller.selectedMemberId,
              onSelected: (value) => controller.setMemberFilter(
                value == _allMembers ? null : value,
              ),
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: _allMembers,
                  child: Text('모든 참여자'),
                ),
                ...controller.members
                    .where(_isCurrentMember)
                    .map(
                      (member) => PopupMenuItem<String>(
                        value: member.id,
                        child: Text(member.name),
                      ),
                    ),
              ],
              child: Chip(
                avatar: Icon(
                  controller.showAllMembers
                      ? Icons.people_outline
                      : Icons.person_outline,
                  size: 18,
                  color: scheme.primary,
                ),
                label: Text(
                  filterLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                side: BorderSide(color: scheme.outlineVariant),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static const _allMembers = '__all_members__';
}

bool _sameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

DateTime _eventStartDate(PlannerEvent event, String timezone) {
  if (event.allDay) {
    return dateOnly(
      event.allDayStartDate ?? utcToWallTime(event.startAt, event.timezone),
    );
  }
  return dateOnly(utcToWallTime(event.startAt, timezone));
}

String _formatDate(DateTime date) =>
    '${date.year}년 ${date.month}월 ${date.day}일';

String _agendaContextLabel(
  PlannerEvent event,
  DateTime sectionDate,
  String timezone,
) {
  final start = event.allDay
      ? dateOnly(
          event.allDayStartDate ?? utcToWallTime(event.startAt, event.timezone),
        )
      : utcToWallTime(event.startAt, timezone);
  final end = event.allDay
      ? dateOnly(
          event.allDayEndDate ?? utcToWallTime(event.endAt, event.timezone),
        )
      : utcToWallTime(event.endAt, timezone);
  if (event.allDay) {
    final inclusiveEnd = calendarDateAdd(end, -1);
    final range = _sameDate(start, inclusiveEnd)
        ? formatMonthDay(start)
        : '${formatMonthDay(start)}–${formatMonthDay(inclusiveEnd)}';
    return '종일 · $range';
  }
  final crossDate = !_sameDate(start, end);
  return '${formatMonthDay(sectionDate)} · ${formatTime(start)}–${formatTime(end)}'
      '${crossDate ? ' · 다음 날까지' : ''}';
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.members,
    this.contextLabel,
  });
  final PlannerEvent event;
  final List<PlannerMember> members;
  final String? contextLabel;

  @override
  Widget build(BuildContext context) {
    final color = colorFromValue(event.colorValue);
    final localStart = utcToWallTime(event.startAt, event.timezone);
    final localEnd = utcToWallTime(event.endAt, event.timezone);
    final assigned = event.memberIds
        .map(
          (id) => members
              .where((member) => _isCurrentMember(member) && member.id == id)
              .firstOrNull,
        )
        .whereType<PlannerMember>()
        .toList();
    final assignedIds = assigned.map((member) => member.id).toSet();
    final previousMemberCount = event.memberIds
        .where((id) => !assignedIds.contains(id))
        .toSet()
        .length;
    final participantLabel = _participantLabel(assigned, previousMemberCount);
    final repeated = _isRecurringEvent(event);
    final repeatLabel = repeated
        ? (event.recurrenceRule == null
              ? '반복 일정'
              : recurrenceSummary(event.recurrenceRule!, start: localStart))
        : null;
    final timeLabel = event.allDay
        ? '종일'
        : '${formatTime(localStart)}부터 ${formatTime(localEnd)}';
    return Semantics(
      button: true,
      label:
          '${event.title}, $timeLabel${contextLabel == null ? '' : ', $contextLabel'}, '
          '${repeatLabel == null ? '' : '반복 일정, $repeatLabel, '}$participantLabel',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(_eventRoute(event)),
          child: IntrinsicHeight(
            child: Row(
              children: <Widget>[
                Container(width: 5, color: color),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Row(
                                children: <Widget>[
                                  Flexible(
                                    child: Text(
                                      event.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                  if (repeated) ...<Widget>[
                                    const SizedBox(width: 6),
                                    Semantics(
                                      label: '반복 일정',
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.secondaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Icon(
                                              Icons.repeat,
                                              size: 16,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                            ),
                                            const SizedBox(width: 2),
                                            const Text('반복'),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Text(
                              event.allDay ? '종일' : formatTime(localStart),
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: readableForegroundOn(
                                      color,
                                      Theme.of(context).colorScheme.surface,
                                    ),
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                        if (event.note.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            event.note,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                        if (contextLabel != null) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            contextLabel!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        if (!event.allDay)
                          Row(
                            children: <Widget>[
                              Icon(
                                Icons.schedule,
                                size: 15,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${formatTime(localStart)} – ${formatTime(localEnd)}',
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                            ],
                          ),
                        const SizedBox(height: 8),
                        _ParticipantSummary(
                          assigned: assigned,
                          previousMemberCount: previousMemberCount,
                          label: participantLabel,
                        ),
                      ],
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _isRecurringEvent(PlannerEvent event) =>
    event.recurrenceRule != null ||
    event.isOccurrence ||
    event.occurrenceKey != 'single';

String _eventRoute(PlannerEvent event) {
  final seriesId = event.seriesId.trim().isEmpty ? event.id : event.seriesId;
  if (event.occurrenceKey == 'single') return '/event/${event.id}';
  return Uri(
    path: '/event/$seriesId',
    queryParameters: <String, String>{'occurrence': event.occurrenceKey},
  ).toString();
}

bool _isCurrentMember(PlannerMember member) =>
    member.isActive && member.removedAt == null;

String _participantLabel(
  List<PlannerMember> assigned,
  int previousMemberCount,
) {
  if (assigned.isEmpty && previousMemberCount == 0) return '참여자 없음';
  final names = assigned.take(2).map((member) => member.name).toList();
  var label = names.join(', ');
  if (assigned.length > names.length) {
    final remaining = assigned.length - names.length;
    label = label.isEmpty ? '$remaining명' : '$label 외 $remaining명';
  }
  if (previousMemberCount > 0) {
    final previousLabel = previousMemberCount == 1
        ? '이전 멤버'
        : '이전 멤버 $previousMemberCount명';
    label = label.isEmpty ? previousLabel : '$label, $previousLabel';
  }
  return '참여자 $label';
}

class _ParticipantSummary extends StatelessWidget {
  const _ParticipantSummary({
    required this.assigned,
    required this.previousMemberCount,
    required this.label,
  });

  final List<PlannerMember> assigned;
  final int previousMemberCount;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: label,
      child: Row(
        children: <Widget>[
          ...assigned.take(3).map((member) {
            final avatarColor = colorFromValue(member.avatarColor);
            return Padding(
              padding: const EdgeInsets.only(right: 3),
              child: CircleAvatar(
                radius: 11,
                backgroundColor: avatarColor,
                child: Text(
                  initials(member.name),
                  style: TextStyle(
                    fontSize: 9,
                    color: contrastingForeground(avatarColor),
                  ),
                ),
              ),
            );
          }),
          if (previousMemberCount > 0) ...<Widget>[
            Icon(
              Icons.person_off_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
          ],
          const SizedBox(width: 3),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
