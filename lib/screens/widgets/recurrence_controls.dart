import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_models.dart';

/// Korean labels used by the recurrence editor.  Keep the mapping in one
/// place so cards, the editor, and screen-reader announcements use the same
/// vocabulary.
const List<String> recurrenceWeekdayLabels = <String>[
  '월',
  '화',
  '수',
  '목',
  '금',
  '토',
  '일',
];

String recurrenceFrequencyLabel(RecurrenceFrequency frequency) =>
    switch (frequency) {
      RecurrenceFrequency.daily => '매일',
      RecurrenceFrequency.weekly => '매주',
      RecurrenceFrequency.monthly => '매월',
    };

String recurrenceEndLabel(RecurrenceEnd end) => switch (end) {
  RecurrenceEnd.never => '반복 종료 없음',
  RecurrenceEnd.count => '횟수',
  RecurrenceEnd.until => '종료일',
};

String recurrenceCadenceLabel(RecurrenceFrequency frequency, int interval) {
  if (interval <= 1) return recurrenceFrequencyLabel(frequency);
  return switch (frequency) {
    RecurrenceFrequency.daily => '$interval일마다',
    RecurrenceFrequency.weekly => '$interval주마다',
    RecurrenceFrequency.monthly => '$interval개월마다',
  };
}

/// Returns the short, user-facing Korean summary shown below the controls and
/// on repeated event cards.  [start] is used for a monthly fallback when a
/// legacy rule does not carry a day (new rules always carry one).
String recurrenceSummary(RecurrenceRule rule, {DateTime? start}) {
  final interval = recurrenceCadenceLabel(rule.frequency, rule.interval);
  final cadence = switch (rule.frequency) {
    RecurrenceFrequency.daily => interval,
    RecurrenceFrequency.weekly =>
      '$interval ${rule.weekdays.map((day) => recurrenceWeekdayLabels[day - 1]).join('·')}',
    RecurrenceFrequency.monthly =>
      '$interval ${rule.monthlyDay ?? start?.day ?? 1}일',
  };
  final end = switch (rule.end) {
    RecurrenceEnd.never => '반복 종료 없음',
    RecurrenceEnd.count => '${rule.count}회',
    RecurrenceEnd.until =>
      '${rule.untilDate!.year}년 ${rule.untilDate!.month}월 ${rule.untilDate!.day}일까지',
  };
  return '$cadence · $end';
}

String recurrenceMonthlyClampNotice(int day) =>
    '매월 $day일에 반복해요. 해당 월에 $day일이 없으면 그 달의 마지막 날에 표시돼요.';

/// A bounded, accessible recurrence rule editor.  A null rule represents the
/// default “반복 안 함” choice.  The state exposes [validateRule] so a parent
/// form can block a save while preserving the user's partially entered text.
class RecurrenceEditor extends StatefulWidget {
  const RecurrenceEditor({
    required this.start,
    this.initialRule,
    this.enabled = true,
    this.onChanged,
    super.key,
  });

  final DateTime start;
  final RecurrenceRule? initialRule;
  final bool enabled;
  final ValueChanged<RecurrenceRule?>? onChanged;

  @override
  RecurrenceEditorState createState() => RecurrenceEditorState();
}

class RecurrenceEditorState extends State<RecurrenceEditor> {
  RecurrenceFrequency? _frequency;
  RecurrenceEnd _end = RecurrenceEnd.never;
  late final TextEditingController _intervalController;
  late final TextEditingController _countController;
  late final TextEditingController _monthlyDayController;
  final Set<int> _weekdays = <int>{};
  DateTime? _untilDate;
  bool _weekdaysTouched = false;
  bool _monthlyDayTouched = false;
  bool _showOptions = false;
  bool _fieldsTouched = false;
  late DateTime _seededStart;
  String? _validationError;

  RecurrenceRule? get currentRule {
    if (_frequency == null) return null;
    try {
      return _ruleFromFields();
    } on FormatException {
      return null;
    }
  }

  bool get hasRecurrenceSelection => _frequency != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRule;
    _frequency = initial?.frequency;
    _showOptions = initial != null;
    _seededStart = widget.start;
    _end = initial?.end ?? RecurrenceEnd.never;
    _intervalController = TextEditingController(
      text: '${initial?.interval ?? 1}',
    );
    _countController = TextEditingController(text: '${initial?.count ?? 1}');
    final monthlyDay = initial?.monthlyDay ?? widget.start.day;
    _monthlyDayController = TextEditingController(text: '$monthlyDay');
    if (initial?.weekdays.isNotEmpty ?? false) {
      _weekdays.addAll(initial!.weekdays);
      _weekdaysTouched = true;
    } else if (_frequency == RecurrenceFrequency.weekly) {
      _weekdays.add(widget.start.weekday);
    }
    _untilDate = initial?.untilDate;
  }

  @override
  void didUpdateWidget(covariant RecurrenceEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRule != widget.initialRule && !_fieldsTouched) {
      final initial = widget.initialRule;
      _frequency = initial?.frequency;
      _end = initial?.end ?? RecurrenceEnd.never;
      _intervalController.text = '${initial?.interval ?? 1}';
      _countController.text = '${initial?.count ?? 1}';
      _monthlyDayController.text = '${initial?.monthlyDay ?? widget.start.day}';
      _weekdays
        ..clear()
        ..addAll(initial?.weekdays ?? const <int>[]);
      _weekdaysTouched = initial?.weekdays.isNotEmpty ?? false;
      if (_frequency == RecurrenceFrequency.weekly && _weekdays.isEmpty) {
        _weekdays.add(widget.start.weekday);
      }
      _monthlyDayTouched = initial?.monthlyDay != null;
      _untilDate = initial?.untilDate;
      _showOptions = initial != null;
      _validationError = null;
    }
    if (oldWidget.start == widget.start ||
        widget.start == _seededStart ||
        _frequency == null) {
      return;
    }
    _seededStart = widget.start;
    var changed = false;
    if (!_weekdaysTouched && _frequency == RecurrenceFrequency.weekly) {
      _weekdays
        ..clear()
        ..add(widget.start.weekday);
      changed = true;
    }
    if (!_monthlyDayTouched && _frequency == RecurrenceFrequency.monthly) {
      _monthlyDayController.text = '${widget.start.day}';
      changed = true;
    }
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _emit();
      });
    }
  }

  @override
  void dispose() {
    _intervalController.dispose();
    _countController.dispose();
    _monthlyDayController.dispose();
    super.dispose();
  }

  RecurrenceRule _ruleFromFields() {
    final interval = int.tryParse(_intervalController.text.trim());
    if (interval == null || interval < 1 || interval > 999) {
      throw const FormatException('반복 간격은 1~999 사이로 입력해 주세요.');
    }
    final count = int.tryParse(_countController.text.trim());
    final monthlyDay = int.tryParse(_monthlyDayController.text.trim());
    if (_frequency == RecurrenceFrequency.weekly && _weekdays.isEmpty) {
      throw const FormatException('요일을 하나 이상 선택해 주세요.');
    }
    if (_frequency == RecurrenceFrequency.monthly &&
        (monthlyDay == null || monthlyDay < 1 || monthlyDay > 31)) {
      throw const FormatException('월간 반복 날짜는 1~31일로 입력해 주세요.');
    }
    if (_end == RecurrenceEnd.count &&
        (count == null || count < 1 || count > 10000)) {
      throw const FormatException('반복 횟수는 1~10,000회로 입력해 주세요.');
    }
    if (_end == RecurrenceEnd.until &&
        (_untilDate == null || _untilDate!.isBefore(_dateOnly(widget.start)))) {
      throw const FormatException('종료일은 시작일 이후로 선택해 주세요.');
    }
    return RecurrenceRule(
      frequency: _frequency!,
      interval: interval,
      weekdays: _frequency == RecurrenceFrequency.weekly
          ? (_weekdays.toList()..sort())
          : const <int>[],
      end: _end,
      count: _end == RecurrenceEnd.count ? count : null,
      untilDate: _end == RecurrenceEnd.until ? _untilDate : null,
      monthlyDay: _frequency == RecurrenceFrequency.monthly ? monthlyDay : null,
    );
  }

  /// Validates current fields and returns the exact rule to persist.  The
  /// inline error remains visible after a failed attempt so the next action
  /// is obvious with keyboard and assistive-technology input.
  RecurrenceRule? validateRule() {
    if (_frequency == null) {
      setState(() => _validationError = null);
      return null;
    }
    try {
      final rule = _ruleFromFields();
      setState(() => _validationError = null);
      return rule;
    } on FormatException catch (error) {
      setState(() => _validationError = error.message);
      return null;
    }
  }

  void _emit() {
    if (_frequency == null) {
      _validationError = null;
      widget.onChanged?.call(null);
      return;
    }
    try {
      final rule = _ruleFromFields();
      _validationError = null;
      widget.onChanged?.call(rule);
    } on FormatException catch (error) {
      _validationError = error.message;
      widget.onChanged?.call(null);
    }
  }

  void _setFrequency(RecurrenceFrequency? frequency) {
    setState(() {
      _fieldsTouched = true;
      _frequency = frequency;
      _showOptions = frequency != null;
      _validationError = null;
      if (frequency == RecurrenceFrequency.weekly && _weekdays.isEmpty) {
        _weekdays.add(widget.start.weekday);
        _weekdaysTouched = false;
      }
      if (frequency == RecurrenceFrequency.monthly &&
          !_monthlyDayTouched &&
          _monthlyDayController.text.trim().isEmpty) {
        _monthlyDayController.text = '${widget.start.day}';
      }
    });
    _emit();
  }

  Future<void> _pickUntilDate() async {
    final initial = _untilDate ?? _dateOnly(widget.start);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: _dateOnly(widget.start),
      lastDate: DateTime(2100, 12, 31),
      helpText: '반복 종료일',
      cancelText: '취소',
      confirmText: '선택',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _fieldsTouched = true;
      _untilDate = _dateOnly(picked);
      _validationError = null;
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final rule = currentRule;
    final summary = rule == null
        ? (_frequency == null ? '반복 안 함' : '반복 규칙을 입력해 주세요.')
        : recurrenceSummary(rule, start: widget.start);
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '반복 설정',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!_showOptions)
            Semantics(
              button: widget.enabled,
              enabled: widget.enabled,
              label: '반복 설정 열기',
              child: InkWell(
                onTap: widget.enabled
                    ? () => setState(() => _showOptions = true)
                    : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: <Widget>[
                      Text(
                        '반복',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '반복 안 함',
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            )
          else ...<Widget>[
            Text(
              '반복',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                _FrequencyChip(
                  label: '반복 안 함',
                  selected: _frequency == null,
                  enabled: widget.enabled,
                  onTap: () => _setFrequency(null),
                ),
                for (final frequency in RecurrenceFrequency.values)
                  _FrequencyChip(
                    label: recurrenceFrequencyLabel(frequency),
                    selected: _frequency == frequency,
                    enabled: widget.enabled,
                    onTap: () => _setFrequency(frequency),
                  ),
              ],
            ),
          ],
          if (_showOptions && _frequency != null) ...<Widget>[
            const SizedBox(height: 12),
            _IntervalInput(
              frequency: _frequency!,
              controller: _intervalController,
              enabled: widget.enabled,
              onChanged: (_) {
                setState(() => _fieldsTouched = true);
                _emit();
              },
            ),
            if (_frequency == RecurrenceFrequency.weekly) ...<Widget>[
              const SizedBox(height: 12),
              Text('반복할 요일', style: textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: List<Widget>.generate(7, (index) {
                  final day = index + 1;
                  final selected = _weekdays.contains(day);
                  return Semantics(
                    button: true,
                    selected: selected,
                    enabled: widget.enabled,
                    label: '${recurrenceWeekdayLabels[index]}요일',
                    child: FilterChip(
                      label: Text(recurrenceWeekdayLabels[index]),
                      selected: selected,
                      onSelected: widget.enabled
                          ? (value) {
                              setState(() {
                                _fieldsTouched = true;
                                _weekdaysTouched = true;
                                if (value) {
                                  _weekdays.add(day);
                                } else {
                                  _weekdays.remove(day);
                                }
                              });
                              _emit();
                            }
                          : null,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      visualDensity: VisualDensity.standard,
                    ),
                  );
                }),
              ),
            ],
            if (_frequency == RecurrenceFrequency.monthly) ...<Widget>[
              const SizedBox(height: 12),
              _MonthlyDayInput(
                controller: _monthlyDayController,
                enabled: widget.enabled,
                onChanged: (_) {
                  setState(() {
                    _fieldsTouched = true;
                    _monthlyDayTouched = true;
                  });
                  _emit();
                },
              ),
              const SizedBox(height: 4),
              Text(
                recurrenceMonthlyClampNotice(
                  int.tryParse(_monthlyDayController.text.trim()) ??
                      widget.start.day,
                ),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text('반복 종료', style: textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                _EndChip(
                  label: '종료 없음',
                  selected: _end == RecurrenceEnd.never,
                  enabled: widget.enabled,
                  onTap: () {
                    setState(() {
                      _fieldsTouched = true;
                      _end = RecurrenceEnd.never;
                      _validationError = null;
                    });
                    _emit();
                  },
                ),
                _EndChip(
                  label: '횟수',
                  selected: _end == RecurrenceEnd.count,
                  enabled: widget.enabled,
                  onTap: () {
                    setState(() {
                      _fieldsTouched = true;
                      _end = RecurrenceEnd.count;
                      _validationError = null;
                    });
                    _emit();
                  },
                ),
                _EndChip(
                  label: '종료일',
                  selected: _end == RecurrenceEnd.until,
                  enabled: widget.enabled,
                  onTap: () {
                    setState(() {
                      _fieldsTouched = true;
                      _end = RecurrenceEnd.until;
                      _validationError = null;
                    });
                    _emit();
                  },
                ),
              ],
            ),
            if (_end == RecurrenceEnd.count) ...<Widget>[
              const SizedBox(height: 8),
              _CountInput(
                controller: _countController,
                enabled: widget.enabled,
                onChanged: (_) {
                  setState(() => _fieldsTouched = true);
                  _emit();
                },
              ),
            ],
            if (_end == RecurrenceEnd.until) ...<Widget>[
              const SizedBox(height: 8),
              Semantics(
                button: true,
                label: _untilDate == null
                    ? '반복 종료일 선택'
                    : '반복 종료일 ${_formatDate(_untilDate!)}',
                child: OutlinedButton.icon(
                  onPressed: widget.enabled ? _pickUntilDate : null,
                  icon: const Icon(Icons.event_outlined),
                  label: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _untilDate == null
                          ? '종료일을 선택해 주세요'
                          : _formatDate(_untilDate!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ],
          if (_showOptions) ...<Widget>[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              label: '반복 요약: $summary',
              child: Text(
                summary,
                key: const ValueKey<String>('recurrence-summary'),
                style: textTheme.bodyMedium?.copyWith(
                  color: _validationError == null
                      ? scheme.onSurfaceVariant
                      : scheme.error,
                ),
              ),
            ),
          ],
          if (_validationError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Semantics(
                liveRegion: true,
                label: '반복 오류: $_validationError',
                child: Text(
                  _validationError!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FrequencyChip extends StatelessWidget {
  const _FrequencyChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    enabled: enabled,
    label: label,
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: enabled ? (_) => onTap() : null,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    ),
  );
}

class _EndChip extends StatelessWidget {
  const _EndChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    enabled: enabled,
    label: '반복 $label',
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: enabled ? (_) => onTap() : null,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
    ),
  );
}

class _IntervalInput extends StatelessWidget {
  const _IntervalInput({
    required this.frequency,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final RecurrenceFrequency frequency;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: <Widget>[
      SizedBox(
        width: 120,
        child: TextFormField(
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          maxLength: 3,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(labelText: '간격', counterText: ''),
          onChanged: onChanged,
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          recurrenceCadenceLabel(
            frequency,
            int.tryParse(controller.text.trim()) ?? 1,
          ),
        ),
      ),
    ],
  );
}

class _MonthlyDayInput extends StatelessWidget {
  const _MonthlyDayInput({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 140,
    child: TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      maxLength: 2,
      decoration: const InputDecoration(
        labelText: '날짜',
        suffixText: '일',
        counterText: '',
      ),
      onChanged: onChanged,
    ),
  );
}

class _CountInput extends StatelessWidget {
  const _CountInput({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 160,
    child: TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      maxLength: 5,
      decoration: const InputDecoration(
        labelText: '반복 횟수',
        suffixText: '회',
        counterText: '',
      ),
      onChanged: onChanged,
    ),
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _formatDate(DateTime value) =>
    '${value.year}년 ${value.month}월 ${value.day}일';

/// Explicit scope confirmation used for recurring occurrence mutations.
/// The safest default is always `이번 일정만`; cancel and barrier-dismiss both
/// return null and must be treated as no-op by the caller.
Future<EventEditScope?> showRecurrenceScopeDialog(
  BuildContext context, {
  required bool deleting,
  EventEditScope initial = EventEditScope.thisOccurrence,
}) {
  return showDialog<EventEditScope>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      var selected = initial;
      return StatefulBuilder(
        builder: (context, setState) {
          final title = deleting ? '반복 일정을 어떻게 삭제할까요?' : '반복 일정을 어떻게 수정할까요?';
          final options = deleting
              ? <_ScopeOption>[
                  const _ScopeOption(
                    EventEditScope.thisOccurrence,
                    '이번 일정만',
                    '이번 일정만 삭제하고 이후 반복은 유지합니다.',
                  ),
                  const _ScopeOption(
                    EventEditScope.future,
                    '이번 일정과 이후',
                    '선택한 일정부터 이후 반복을 삭제합니다. 이전 일정은 유지됩니다.',
                  ),
                  const _ScopeOption(
                    EventEditScope.all,
                    '전체 시리즈',
                    '모든 반복 일정을 삭제합니다. 되돌릴 수 없어요.',
                  ),
                ]
              : <_ScopeOption>[
                  const _ScopeOption(
                    EventEditScope.thisOccurrence,
                    '이번 일정만',
                    '이번 일정만 바꾸고 나머지는 그대로 둡니다.',
                  ),
                  const _ScopeOption(
                    EventEditScope.future,
                    '이번 일정과 이후',
                    '선택한 일정부터 새 규칙을 적용합니다. 이후 예외가 초기화될 수 있어요.',
                  ),
                  const _ScopeOption(
                    EventEditScope.all,
                    '전체 일정',
                    '모든 반복 일정에 적용합니다. 기존 예외가 초기화될 수 있어요.',
                  ),
                ];
          return AlertDialog(
            title: Text(title),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                RadioGroup<EventEditScope>(
                  groupValue: selected,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => selected = value);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final option in options)
                        RadioListTile<EventEditScope>(
                          value: option.scope,
                          title: Text(option.title),
                          subtitle: Text(option.description),
                          contentPadding: EdgeInsets.zero,
                          dense: false,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, selected),
                child: Text(deleting ? '삭제' : '저장'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _ScopeOption {
  const _ScopeOption(this.scope, this.title, this.description);

  final EventEditScope scope;
  final String title;
  final String description;
}
