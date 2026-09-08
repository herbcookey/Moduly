import 'dart:async';

import 'package:flutter/material.dart';

import '../models/notification_models.dart';

typedef NotificationBoolCallback = FutureOr<void> Function(bool value);
typedef NotificationActionCallback = FutureOr<void> Function();

/// 표시만 담당하는 알림 설정 페이지다.
///
/// 계정 설정, OS 권한, 서버 공급자 기능을 의도적으로 별도 값으로 제공한다. 따라서
/// 호출자는 권한이 허용된 기기와 설정되지 않은 서버 푸시를 혼동하지 않고 표시할 수
/// 있다. 모든 콜백은 선택 사항이므로 세션을 불러오는 동안 이 페이지를 읽기 전용
/// 진단 화면으로 사용할 수도 있다.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    required this.accountEnabled,
    required this.pushEnabled,
    required this.permissionState,
    required this.localCapability,
    required this.pushCapability,
    this.accountLabel = '로컬 알림 사용',
    this.onAccountChanged,
    this.onPushChanged,
    this.onRequestPermission,
    this.onOpenSystemSettings,
    this.onRetry,
    super.key,
  });

  final bool accountEnabled;
  final bool pushEnabled;
  final NotificationPermissionState permissionState;
  final NotificationCapabilityState localCapability;
  final NotificationCapabilityState pushCapability;
  final String accountLabel;
  final NotificationBoolCallback? onAccountChanged;
  final NotificationBoolCallback? onPushChanged;
  final NotificationActionCallback? onRequestPermission;
  final NotificationActionCallback? onOpenSystemSettings;
  final NotificationActionCallback? onRetry;

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  late bool _accountEnabled;
  late bool _pushEnabled;
  bool _busy = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _copyFromWidget();
  }

  @override
  void didUpdateWidget(covariant NotificationSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_busy) _copyFromWidget();
  }

  void _copyFromWidget() {
    _accountEnabled = widget.accountEnabled;
    _pushEnabled = widget.pushEnabled;
  }

  Future<bool> _run(FutureOr<void> Function() action) async {
    if (_busy) return false;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await action();
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => _actionError = '변경하지 못했어요. 잠시 후 다시 시도해 주세요.');
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setAccount(bool value) async {
    if (widget.onAccountChanged == null) return;
    final previous = _accountEnabled;
    setState(() => _accountEnabled = value);
    final succeeded = await _run(() => widget.onAccountChanged!(value));
    if (!succeeded && mounted) setState(() => _accountEnabled = previous);
  }

  Future<void> _setPush(bool value) async {
    if (widget.onPushChanged == null) return;
    final previous = _pushEnabled;
    setState(() => _pushEnabled = value);
    final succeeded = await _run(() => widget.onPushChanged!(value));
    if (!succeeded && mounted) setState(() => _pushEnabled = previous);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final permission = widget.permissionState;
    final localAvailable =
        widget.localCapability == NotificationCapabilityState.available;
    final pushAvailable =
        widget.pushCapability == NotificationCapabilityState.available;
    final pushToggleEnabled =
        pushAvailable && widget.onPushChanged != null && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('알림')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          Semantics(
            container: true,
            label: '알림 설정 안내',
            child: Text(
              '계정 설정과 기기 권한은 따로 관리돼요.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile.adaptive(
              value: _accountEnabled,
              onChanged: widget.onAccountChanged == null || _busy
                  ? null
                  : _setAccount,
              title: Text(widget.accountLabel),
              subtitle: const Text('계정에 저장되는 로컬 알림 설정이에요. 꺼도 일정별 설정은 보관돼요.'),
              secondary: const Icon(Icons.notifications_active_outlined),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel(context, '기기 알림'),
          const SizedBox(height: 6),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  // OS 권한은 의도적으로 두 번째 제품 스위치가 아니라 상태 행이다.
                  // 위의 계정 전체 제어가 저장되는 로컬 알림 설정이고, 아래 동작은
                  // 운영체제 권한을 요청하거나 다시 확인하기만 한다.
                  title: const Text('이 기기에서 받기'),
                  subtitle: Text(_localSubtitle(permission, localAvailable)),
                  leading: Icon(
                    _localIcon(permission, localAvailable),
                    color: _localColor(context, permission, localAvailable),
                  ),
                ),
                if (_showPermissionAction(permission, localAvailable))
                  const Divider(height: 1),
                if (_showPermissionAction(permission, localAvailable))
                  _permissionAction(context, permission),
                if (widget.localCapability ==
                    NotificationCapabilityState.disabled)
                  const Divider(height: 1),
                if (widget.localCapability ==
                    NotificationCapabilityState.disabled)
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('기기 알림 다시 확인'),
                    subtitle: const Text('알림 모듈을 다시 초기화해요.'),
                    onTap: widget.onRetry == null || _busy
                        ? null
                        : () => _run(widget.onRetry!),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel(context, '서버 푸시'),
          const SizedBox(height: 6),
          Card(
            child: SwitchListTile.adaptive(
              value: _pushEnabled,
              onChanged: pushToggleEnabled ? _setPush : null,
              title: const Text('다른 기기에서도 받기'),
              subtitle: Text(_pushSubtitle(widget.pushCapability)),
              secondary: Icon(
                pushAvailable
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                color: pushAvailable ? scheme.primary : scheme.outline,
              ),
            ),
          ),
          if (_actionError != null) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              container: true,
              label: _actionError!,
              child: Text(_actionError!, style: TextStyle(color: scheme.error)),
            ),
          ],
          const SizedBox(height: 20),
          Semantics(
            liveRegion: true,
            container: true,
            excludeSemantics: true,
            label: _permissionStatusLabel(permission, localAvailable),
            child: Text(
              _permissionStatusLabel(permission, localAvailable),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String value) => Text(
    value,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w700,
    ),
  );

  bool _showPermissionAction(
    NotificationPermissionState permission,
    bool available,
  ) =>
      available &&
      (permission == NotificationPermissionState.notDetermined ||
          permission == NotificationPermissionState.denied ||
          permission == NotificationPermissionState.provisional);

  Widget _permissionAction(
    BuildContext context,
    NotificationPermissionState permission,
  ) {
    final isDenied = permission == NotificationPermissionState.denied;
    final label = isDenied ? '설정 열기' : '권한 요청';
    final callback = isDenied
        ? widget.onOpenSystemSettings
        : widget.onRequestPermission;
    return ListTile(
      leading: Icon(isDenied ? Icons.settings_outlined : Icons.lock_open),
      title: Text(label),
      subtitle: Text(
        isDenied ? '기기 설정에서 알림을 허용해 주세요.' : '알림이 필요할 때만 기기 권한을 요청해요.',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: callback == null || _busy ? null : () => _run(callback),
    );
  }

  String _localSubtitle(
    NotificationPermissionState permission,
    bool available,
  ) {
    if (!available || permission == NotificationPermissionState.unsupported) {
      return '이 플랫폼에서는 기기 알림을 지원하지 않아요.';
    }
    switch (permission) {
      case NotificationPermissionState.notDetermined:
        return '권한이 아직 없어요. 켜면 기기에서 알려 드려요.';
      case NotificationPermissionState.denied:
        return '기기 설정에서 알림 권한을 허용해 주세요.';
      case NotificationPermissionState.provisional:
        return '임시 허용 상태예요. 전체 허용은 기기 설정에서 할 수 있어요.';
      case NotificationPermissionState.disabled:
        return '기기 알림을 초기화하지 못했어요.';
      case NotificationPermissionState.unconfigured:
        return '기기 알림 설정이 아직 준비되지 않았어요.';
      case NotificationPermissionState.authorized:
        return '이 기기에서 일정 알림을 받아요.';
      case NotificationPermissionState.unsupported:
        return '이 플랫폼에서는 기기 알림을 지원하지 않아요.';
    }
  }

  String _pushSubtitle(NotificationCapabilityState capability) {
    switch (capability) {
      case NotificationCapabilityState.available:
        return '서버 설정이 완료된 계정에서만 사용할 수 있어요.';
      case NotificationCapabilityState.unconfigured:
        return '서버 푸시는 아직 설정되지 않았어요.';
      case NotificationCapabilityState.disabled:
        return '서버 푸시를 사용할 수 없어요.';
      case NotificationCapabilityState.unsupported:
        return '이 플랫폼에서는 서버 푸시를 지원하지 않아요.';
    }
  }

  String _permissionStatusLabel(
    NotificationPermissionState permission,
    bool available,
  ) {
    if (!available || permission == NotificationPermissionState.unsupported) {
      return '기기 알림: 지원하지 않음';
    }
    switch (permission) {
      case NotificationPermissionState.authorized:
        return '기기 알림 상태: 허용됨';
      case NotificationPermissionState.provisional:
        return '기기 알림 상태: 임시 허용';
      case NotificationPermissionState.notDetermined:
        return '기기 알림 상태: 아직 결정하지 않음';
      case NotificationPermissionState.denied:
        return '기기 알림 상태: 권한이 거부됨';
      case NotificationPermissionState.disabled:
        return '기기 알림 상태: 사용할 수 없음';
      case NotificationPermissionState.unconfigured:
        return '기기 알림 상태: 설정되지 않음';
      case NotificationPermissionState.unsupported:
        return '기기 알림 상태: 지원하지 않음';
    }
  }

  IconData _localIcon(NotificationPermissionState permission, bool available) {
    if (!available || permission == NotificationPermissionState.unsupported) {
      return Icons.notifications_off_outlined;
    }
    return switch (permission) {
      NotificationPermissionState.authorized => Icons.notifications_active,
      NotificationPermissionState.provisional => Icons.notifications_none,
      NotificationPermissionState.notDetermined => Icons.notifications_none,
      NotificationPermissionState.denied => Icons.notifications_off_outlined,
      NotificationPermissionState.disabled => Icons.error_outline,
      NotificationPermissionState.unconfigured => Icons.help_outline,
      NotificationPermissionState.unsupported =>
        Icons.notifications_off_outlined,
    };
  }

  Color? _localColor(
    BuildContext context,
    NotificationPermissionState permission,
    bool available,
  ) {
    if (!available || permission == NotificationPermissionState.unsupported) {
      return Theme.of(context).colorScheme.outline;
    }
    if (permission == NotificationPermissionState.denied ||
        permission == NotificationPermissionState.disabled) {
      return Theme.of(context).colorScheme.error;
    }
    return Theme.of(context).colorScheme.primary;
  }
}
