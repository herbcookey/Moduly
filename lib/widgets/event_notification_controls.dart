import 'dart:async';

import 'package:flutter/material.dart';

import '../models/notification_models.dart';

typedef EventNotificationBoolCallback = FutureOr<void> Function(bool value);
typedef EventNotificationIntCallback = FutureOr<void> Function(int value);
typedef EventNotificationChannelCallback =
    FutureOr<void> Function(NotificationChannel channel);

/// Reminder controls embedded in an event editor.
///
/// The widget is deliberately presentation-only. The event editor owns the
/// draft and decides when the callbacks are persisted; this keeps a recurring
/// event's reminder preference series-wide without silently writing an
/// occurrence override.  All-day reminders are described in civil calendar
/// days and fire at 09:00 in the event's IANA timezone.
class EventNotificationControls extends StatefulWidget {
  const EventNotificationControls({
    required this.allDay,
    required this.recurring,
    required this.enabled,
    required this.channel,
    required this.timedLeadSeconds,
    required this.allDayDaysBefore,
    required this.localCapability,
    required this.pushCapability,
    this.applyToWholeSeries = true,
    this.onEnabledChanged,
    this.onChannelChanged,
    this.onTimedLeadChanged,
    this.onAllDayDaysChanged,
    this.onApplyToWholeSeriesChanged,
    super.key,
  });

  final bool allDay;
  final bool recurring;
  final bool enabled;
  final NotificationChannel channel;
  final int timedLeadSeconds;
  final int allDayDaysBefore;
  final NotificationCapabilityState localCapability;
  final NotificationCapabilityState pushCapability;
  final bool applyToWholeSeries;
  final EventNotificationBoolCallback? onEnabledChanged;
  final EventNotificationChannelCallback? onChannelChanged;
  final EventNotificationIntCallback? onTimedLeadChanged;
  final EventNotificationIntCallback? onAllDayDaysChanged;
  final EventNotificationBoolCallback? onApplyToWholeSeriesChanged;

  @override
  State<EventNotificationControls> createState() =>
      _EventNotificationControlsState();
}

class _EventNotificationControlsState extends State<EventNotificationControls> {
  late bool _enabled;
  late NotificationChannel _channel;
  late int _timedLeadSeconds;
  late int _allDayDaysBefore;
  late bool _applyToWholeSeries;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(covariant EventNotificationControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy) _syncFromWidget();
  }

  void _syncFromWidget() {
    _enabled = widget.enabled;
    _channel = widget.channel;
    _timedLeadSeconds = widget.timedLeadSeconds;
    _allDayDaysBefore = widget.allDayDaysBefore;
    _applyToWholeSeries = widget.applyToWholeSeries;
  }

  Future<bool> _run(FutureOr<void> Function() action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } catch (_) {
      // The editor owns persistence and may reject a draft asynchronously.
      // Keep this presentation widget from leaking an unhandled future; the
      // caller below restores the previous control value on failure.
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runWithRollback(
    FutureOr<void> Function() action,
    VoidCallback rollback,
  ) async {
    final succeeded = await _run(action);
    if (!succeeded && mounted) setState(rollback);
  }

  bool get _localAvailable =>
      widget.localCapability == NotificationCapabilityState.available;

  bool get _pushAvailable =>
      widget.pushCapability == NotificationCapabilityState.available;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = _enabled && !_busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SwitchListTile.adaptive(
              value: _enabled,
              onChanged: widget.onEnabledChanged == null || _busy
                  ? null
                  : (value) {
                      final previous = _enabled;
                      setState(() => _enabled = value);
                      unawaited(
                        _runWithRollback(
                          () => widget.onEnabledChanged!(value),
                          () => _enabled = previous,
                        ),
                      );
                    },
              title: const Text('내 알림'),
              subtitle: const Text('이 일정의 알림을 나만 받아요.'),
              secondary: const Icon(Icons.notifications_outlined),
            ),
            if (_enabled) ...<Widget>[
              const Divider(height: 1),
              _channelChoice(context, enabled),
              if (widget.allDay)
                _allDayOffset(context, enabled)
              else
                _timedOffset(context, enabled),
              if (widget.recurring) ...<Widget>[
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: _applyToWholeSeries,
                  onChanged: widget.onApplyToWholeSeriesChanged == null || _busy
                      ? null
                      : (value) {
                          final previous = _applyToWholeSeries;
                          setState(() => _applyToWholeSeries = value);
                          unawaited(
                            _runWithRollback(
                              () => widget.onApplyToWholeSeriesChanged!(value),
                              () => _applyToWholeSeries = previous,
                            ),
                          );
                        },
                  title: const Text('반복 일정 전체에 적용'),
                  subtitle: const Text('미래 회차에도 같은 알림 설정을 사용해요.'),
                  secondary: const Icon(Icons.repeat),
                ),
              ],
            ],
            if (!_localAvailable && !_pushAvailable)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  '이 기기에서는 알림을 사용할 수 없어요.',
                  style: TextStyle(color: scheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _channelChoice(BuildContext context, bool enabled) {
    final localEnabled = _localAvailable;
    final pushEnabled = _pushAvailable;
    final canChange = widget.onChannelChanged != null && enabled;
    return Semantics(
      container: true,
      label: '알림 방법',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('알림 방법', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ChoiceChip(
                  label: const Text('이 기기'),
                  selected: _channel == NotificationChannel.local,
                  onSelected: !localEnabled || !canChange
                      ? null
                      : (selected) {
                          if (!selected) return;
                          final previous = _channel;
                          setState(() => _channel = NotificationChannel.local);
                          unawaited(
                            _runWithRollback(
                              () => widget.onChannelChanged!(
                                NotificationChannel.local,
                              ),
                              () => _channel = previous,
                            ),
                          );
                        },
                ),
                Semantics(
                  container: true,
                  label: pushEnabled ? '다른 기기' : '다른 기기, 서버 설정 필요',
                  child: ChoiceChip(
                    label: const Text('다른 기기'),
                    selected: _channel == NotificationChannel.push,
                    onSelected: !pushEnabled || !canChange
                        ? null
                        : (selected) {
                            if (!selected) return;
                            final previous = _channel;
                            setState(() => _channel = NotificationChannel.push);
                            unawaited(
                              _runWithRollback(
                                () => widget.onChannelChanged!(
                                  NotificationChannel.push,
                                ),
                                () => _channel = previous,
                              ),
                            );
                          },
                  ),
                ),
              ],
            ),
            if (!pushEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  widget.pushCapability ==
                          NotificationCapabilityState.unconfigured
                      ? '서버 푸시는 아직 설정되지 않았어요.'
                      : '다른 기기 알림을 사용할 수 없어요.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _timedOffset(BuildContext context, bool enabled) {
    const values = <int>[0, 300, 900, 1800, 3600, 86400];
    final value = values.contains(_timedLeadSeconds) ? _timedLeadSeconds : 900;
    return ListTile(
      leading: const Icon(Icons.schedule_outlined),
      title: const Text('미리 알림'),
      subtitle: const Text('일정 시작 전 경과 시간 기준으로 알려 드려요.'),
      trailing: DropdownButton<int>(
        value: value,
        onChanged: widget.onTimedLeadChanged == null || !enabled
            ? null
            : (next) {
                if (next == null) return;
                final previous = _timedLeadSeconds;
                setState(() => _timedLeadSeconds = next);
                unawaited(
                  _runWithRollback(
                    () => widget.onTimedLeadChanged!(next),
                    () => _timedLeadSeconds = previous,
                  ),
                );
              },
        items: values
            .map(
              (seconds) => DropdownMenuItem<int>(
                value: seconds,
                child: Text(_timedLabel(seconds)),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  Widget _allDayOffset(BuildContext context, bool enabled) {
    const values = <int>[0, 1, 2, 3, 7, 14];
    final value = values.contains(_allDayDaysBefore) ? _allDayDaysBefore : 0;
    return ListTile(
      leading: const Icon(Icons.today_outlined),
      title: const Text('미리 알림'),
      subtitle: const Text('일정 시간대의 오전 9시에 알려 드려요.'),
      trailing: DropdownButton<int>(
        value: value,
        onChanged: widget.onAllDayDaysChanged == null || !enabled
            ? null
            : (next) {
                if (next == null) return;
                final previous = _allDayDaysBefore;
                setState(() => _allDayDaysBefore = next);
                unawaited(
                  _runWithRollback(
                    () => widget.onAllDayDaysChanged!(next),
                    () => _allDayDaysBefore = previous,
                  ),
                );
              },
        items: values
            .map(
              (days) => DropdownMenuItem<int>(
                value: days,
                child: Text(_allDayLabel(days)),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  String _timedLabel(int seconds) {
    if (seconds == 0) return '정시';
    if (seconds % 86400 == 0) return '${seconds ~/ 86400}일 전';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600}시간 전';
    return '${seconds ~/ 60}분 전';
  }

  String _allDayLabel(int days) => days == 0 ? '당일' : '$days일 전';
}
