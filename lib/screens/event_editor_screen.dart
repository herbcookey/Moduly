import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/timezone_utils.dart';
import '../models/app_models.dart';
import '../state/app_state.dart';

class EventEditorScreen extends ConsumerStatefulWidget {
  const EventEditorScreen({this.eventId, super.key});
  final String? eventId;

  @override
  ConsumerState<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends ConsumerState<EventEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _noteController;
  late DateTime _start;
  late DateTime _end;
  bool _allDay = false;
  int _colorValue = 0xff477b76;
  bool _didSeed = false;
  final Set<String> _selectedMemberIds = <String>{};
  int? _bodyDraftBaseVersion;
  int? _participantDraftBaseVersion;
  bool _bodyDraftDirty = false;
  bool _memberSelectionDirty = false;
  bool _eventUnavailable = false;

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
      if (event.id == widget.eventId && !event.isDeleted) return event;
    }
    return null;
  }

  void _applyEventToBody(PlannerEvent event) {
    _titleController.text = event.title;
    _noteController.text = event.note;
    final wallStart = utcToWallTime(event.startAt, event.timezone);
    final wallEnd = utcToWallTime(event.endAt, event.timezone);
    if (event.allDay) {
      // All-day endAt is an exclusive wall-time boundary. Legacy rows may
      // lack the date metadata, so derive the inclusive editor date from
      // that boundary just as we do when metadata is present.
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
    _didSeed = true;
    final controller = ref.read(plannerControllerProvider);
    final existing = _existing(controller);
    if (existing != null) {
      _applyEventToBody(existing);
      _selectedMemberIds
        ..clear()
        ..addAll(existing.memberIds);
      _bodyDraftBaseVersion = existing.version;
      _participantDraftBaseVersion = existing.version;
      _bodyDraftDirty = false;
      _memberSelectionDirty = false;
    } else if (widget.eventId == null) {
      _start = DateTime(
        controller.selectedDay.year,
        controller.selectedDay.month,
        controller.selectedDay.day,
        9,
      );
      _end = _start.add(const Duration(hours: 1));
      final currentUserId = controller.user?.id;
      if (currentUserId != null && currentUserId.isNotEmpty) {
        _selectedMemberIds
          ..clear()
          ..add(currentUserId);
      }
      _bodyDraftBaseVersion = null;
      _participantDraftBaseVersion = null;
      _bodyDraftDirty = false;
      _memberSelectionDirty = false;
    } else {
      // An edit deep link must never be treated as a create route while its
      // target is unavailable. The loading/terminal view is selected in build
      // once the controller has finished its authoritative snapshot.
      _selectedMemberIds.clear();
      _bodyDraftBaseVersion = null;
      _participantDraftBaseVersion = null;
      _bodyDraftDirty = false;
      _memberSelectionDirty = false;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: start || !_allDay
          ? DateTime(2020)
          : DateTime(_start.year, _start.month, _start.day),
      lastDate: DateTime(2100),
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
    final currentUserId = controller.user?.id;
    final existing = _existing(controller);
    if (widget.eventId != null && existing == null) return;
    final canEditBody = existing == null || existing.ownerId == currentUserId;
    final canEditParticipants = existing == null
        ? currentUserId != null && controller.selectedGroup != null
        : controller.canEditEventParticipants(existing);
    if (!canEditBody && !canEditParticipants) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이 일정은 작성자만 수정할 수 있어요.')));
      return;
    }
    if (canEditBody && !(_formKey.currentState?.validate() ?? false)) return;
    if (existing != null && !canEditBody && canEditParticipants) {
      try {
        final participantDraft = existing.copyWith(
          version: _participantDraftBaseVersion ?? existing.version,
        );
        await controller.replaceEventMembers(
          participantDraft,
          _selectedMemberIds.toList(growable: false),
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('참여자를 저장했어요.')));
          context.go('/home');
        }
      } catch (_) {
        if (mounted) setState(() {});
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
    );
    try {
      await controller.saveEvent(existing: existingDraft, draft: draft);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('일정을 저장했어요.')));
        context.go('/home');
      }
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(PlannerEvent event) async {
    final currentUserId = ref.read(plannerControllerProvider).user?.id;
    if (event.ownerId != currentUserId) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이 일정은 작성자만 삭제할 수 있어요.')));
      return;
    }
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
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(plannerControllerProvider).deleteEvent(event);
      if (mounted) context.go('/home');
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(plannerControllerProvider);
    final existing = _existing(controller);
    if (widget.eventId != null && existing == null && !controller.isLoading) {
      _eventUnavailable = true;
    }
    if (_eventUnavailable || (widget.eventId != null && existing == null)) {
      final loading = !_eventUnavailable && controller.isLoading;
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
    if (existing != null) _syncIncomingEventDraft(existing);
    final canEditBody =
        existing == null || existing.ownerId == controller.user?.id;
    final canEditParticipants = existing == null
        ? controller.user != null && controller.selectedGroup != null
        : controller.canEditEventParticipants(existing);
    final canSave = canEditBody || canEditParticipants;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          existing == null
              ? '새 일정'
              : canSave
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
          if (canSave)
            TextButton(
              onPressed: controller.isSaving ? null : _save,
              child: const Text('저장'),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
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
            const Divider(height: 30),
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
            const SizedBox(height: 18),
            _ParticipantPicker(
              members: controller.members,
              selectedMemberIds: _selectedMemberIds,
              enabled: canEditParticipants,
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
            if (controller.errorMessage != null) ...<Widget>[
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                label: '오류: ${controller.errorMessage!}',
                child: Text(
                  controller.errorMessage!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
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

class _ParticipantPicker extends StatelessWidget {
  const _ParticipantPicker({
    required this.members,
    required this.selectedMemberIds,
    required this.enabled,
    required this.onChanged,
  });

  final List<PlannerMember> members;
  final Set<String> selectedMemberIds;
  final bool enabled;
  final void Function(String memberId, bool selected) onChanged;

  @override
  Widget build(BuildContext context) {
    final activeMembers = members
        .where(_isSelectableMember)
        .toList(growable: false);
    final activeIds = activeMembers.map((member) => member.id).toSet();
    final previousMemberIds = selectedMemberIds
        .where((memberId) => !activeIds.contains(memberId))
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
        if (activeMembers.isEmpty && previousMemberIds.isEmpty)
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
    required this.onChanged,
  });

  final PlannerMember member;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final avatarColor = colorFromValue(member.avatarColor);
    return Semantics(
      container: true,
      label: '참여자 ${member.name}',
      selected: selected,
      enabled: enabled,
      child: CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: selected,
        onChanged: enabled ? (value) => onChanged(value ?? false) : null,
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
