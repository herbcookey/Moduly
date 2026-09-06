import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
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
    final week = _week(controller.selectedDay);
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
                '오프라인 · 마지막으로 저장된 일정',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: <Widget>[
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
      body: _DaySwipeDetector(
        onPreviousDay: () => controller.moveSelectedDay(-1),
        onNextDay: () => controller.moveSelectedDay(1),
        child: RefreshIndicator(
          onRefresh: () async {
            if (group != null) await controller.selectGroup(group.id);
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
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
              if (controller.isLoading && controller.events.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Semantics(
                      label: '일정을 불러오는 중',
                      liveRegion: true,
                      child: const CircularProgressIndicator(),
                    ),
                  ),
                )
              else if (controller.visibleEvents.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyDay(),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  sliver: SliverList.builder(
                    itemCount: controller.visibleEvents.length,
                    itemBuilder: (context, index) {
                      final event = controller.visibleEvents[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _EventCard(
                          event: event,
                          members: controller.members,
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
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
    return Row(
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
            label: '${day.month}월 ${day.day}일 ${_labels[day.weekday - 1]}요일',
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => onSelected(day),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: isSelected ? scheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: isToday && !isSelected
                      ? Border.all(color: scheme.primary, width: 1.5)
                      : null,
                ),
                child: Column(
                  children: <Widget>[
                    Text(
                      _labels[day.weekday - 1],
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isSelected
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${day.day}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: isSelected ? scheme.onPrimary : scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
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

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.members});
  final PlannerEvent event;
  final List<PlannerMember> members;

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
    return Semantics(
      button: true,
      label:
          '${event.title}, ${event.allDay ? '종일' : '${formatTime(localStart)}부터 ${formatTime(localEnd)}'}, $participantLabel',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/event/${event.id}'),
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
                              child: Text(
                                event.title,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
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

class _EmptyDay extends StatelessWidget {
  const _EmptyDay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.wb_sunny_outlined, size: 52, color: scheme.primary),
            const SizedBox(height: 14),
            Text(
              '비어 있는 하루예요',
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
