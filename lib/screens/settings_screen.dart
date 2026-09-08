import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/demo_identity.dart';
import '../repositories/account_deletion_repository.dart';
import 'account_deletion_screen.dart';
import '../state/app_state.dart';
import '../platform/notification_local_scheduler.dart';
import '../models/notification_models.dart';
import '../state/notification_state.dart';
import 'notification_settings_screen.dart';

enum _DataSyncStatus { localPreview, connecting, syncing, synced, issue }

_DataSyncStatus _dataSyncStatus({
  required PlannerController controller,
  required bool configured,
  required bool ready,
  required bool initializationFailed,
}) {
  if (!configured) return _DataSyncStatus.localPreview;
  if (initializationFailed || controller.isOffline) {
    return _DataSyncStatus.issue;
  }
  if (!ready) return _DataSyncStatus.connecting;
  if (controller.isLoading ||
      controller.isSaving ||
      controller.isLoadingEvents ||
      controller.isLoadingMoreEvents ||
      controller.isSearching ||
      controller.isLoadingMoreSearch) {
    return _DataSyncStatus.syncing;
  }
  return _DataSyncStatus.synced;
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(plannerControllerProvider);
    final config = ref.watch(appConfigProvider);
    final supabaseError = ref.watch(supabaseInitializationErrorProvider);
    final supabaseReady = ref.watch(supabaseReadyProvider);
    final syncStatus = _dataSyncStatus(
      controller: controller,
      configured: config.hasSupabase,
      ready: supabaseReady,
      initializationFailed: supabaseError != null,
    );
    final user = controller.user;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: CircleAvatar(
                radius: 25,
                backgroundColor: scheme.primaryContainer,
                child: Icon(Icons.person, color: scheme.onPrimaryContainer),
              ),
              title: Text(
                user?.displayName ??
                    (user?.id == demoUserId ? demoUserName : '멤버'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(user?.email ?? ''),
              trailing: IconButton(
                tooltip: '이름 변경',
                onPressed: user == null || controller.isSaving
                    ? null
                    : () => _showEditDisplayName(
                        context,
                        ref,
                        user.displayName ??
                            (user.id == demoUserId ? demoUserName : ''),
                      ),
                icon: const Icon(Icons.edit_outlined),
              ),
            ),
          ),
          if (supabaseError != null) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              color: scheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.cloud_off_outlined,
                  color: scheme.onErrorContainer,
                ),
                title: Text(
                  'Supabase 연결 필요',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  supabaseError,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            '화면',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Card(
            child: Column(
              children: <Widget>[
                SwitchListTile.adaptive(
                  value: controller.darkMode,
                  onChanged: controller.toggleDarkMode,
                  title: const Text('어두운 화면'),
                  subtitle: const Text('눈이 편안한 색상으로 전환해요.'),
                  secondary: const Icon(Icons.dark_mode_outlined),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: const Text('글자 크기'),
                  subtitle: Slider(
                    value: controller.textScale,
                    min: 0.9,
                    max: 1.25,
                    divisions: 7,
                    label: '${(controller.textScale * 100).round()}%',
                    onChanged: controller.setTextScale,
                  ),
                ),
              ],
            ),
          ),
          if (controller.appearancePreferencesError case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(message, style: TextStyle(color: scheme.error)),
                  ),
                  if (message == '화면 설정을 저장하지 못했어요.')
                    TextButton(
                      onPressed: controller.retryAppearancePreferencesSave,
                      child: const Text('다시 저장'),
                    )
                  else if (message == '화면 설정을 불러오지 못했어요.')
                    TextButton(
                      onPressed: controller.retryAppearancePreferencesLoad,
                      child: const Text('다시 불러오기'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text(
            '알림',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Card(
            child: ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('알림 설정'),
              subtitle: const Text('계정 알림과 기기 권한을 관리해요.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/notifications'),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '계정',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Card(
            child: ListTile(
              leading: Icon(Icons.person_remove_outlined, color: scheme.error),
              title: const Text('계정 삭제'),
              subtitle: const Text('계정과 관련된 데이터를 영구 삭제합니다.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final client = ref.read(supabaseClientProvider);
                final repository = client == null
                    ? ConfigurationBlockedAccountDeletionRepository(
                        ref.read(releaseConfigurationErrorProvider) ??
                            '계정 삭제는 연결된 서버에서만 사용할 수 있어요.',
                      )
                    : SupabaseAccountDeletionRepository(client);
                final controller = ref.read(plannerControllerProvider);
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (routeContext) => AccountDeletionScreen(
                      repository: repository,
                      onDeleted: () async {
                        // Edge Function이 Auth 사용자를 삭제한다. 로그아웃으로
                        // 로컬 세션을 지우며, 이미 무효화된 원격 세션도 허용하고
                        // 항상 로그인 화면으로 돌아간다.
                        try {
                          await controller.signOut();
                        } catch (_) {
                          // 서버에서 계정이 이미 삭제된 상태다.
                        }
                        if (context.mounted) context.go('/login');
                      },
                      onManageGroups: () {
                        if (context.mounted) context.go('/groups');
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '데이터',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: Icon(switch (syncStatus) {
                    _DataSyncStatus.localPreview => Icons.storage_outlined,
                    _DataSyncStatus.connecting => Icons.cloud_queue_outlined,
                    _DataSyncStatus.syncing => Icons.sync,
                    _DataSyncStatus.synced => Icons.cloud_done_outlined,
                    _DataSyncStatus.issue => Icons.sync_problem_outlined,
                  }),
                  title: Text(switch (syncStatus) {
                    _DataSyncStatus.localPreview => '로컬 미리보기',
                    _DataSyncStatus.connecting => '연결 준비 중',
                    _DataSyncStatus.syncing => '동기화 중',
                    _DataSyncStatus.synced => '동기화됨',
                    _DataSyncStatus.issue => '동기화 문제',
                  }),
                  subtitle: Text(switch (syncStatus) {
                    _DataSyncStatus.localPreview =>
                      '이 기기의 데모 데이터로 실행 중이며 서버와 동기화하지 않아요.',
                    _DataSyncStatus.connecting => '원격 데이터 연결을 준비하고 있어요.',
                    _DataSyncStatus.syncing => '원격 데이터를 주고받고 있어요.',
                    _DataSyncStatus.synced => '원격 데이터 연결이 정상적으로 준비됐어요.',
                    _DataSyncStatus.issue => '데이터를 새로고침해 다시 확인해 주세요.',
                  }),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.groups_outlined),
                  title: const Text('그룹 바꾸기'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/groups'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '법률 및 개인정보',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Card(
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('개인정보처리방침'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/privacy-policy'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('이용약관'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/terms-of-service'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => _signOut(context, ref),
            icon: const Icon(Icons.logout),
            label: const Text('로그아웃'),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              'Moduly · MVP',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(plannerControllerProvider).signOut();
    } catch (_) {
      // 로그아웃은 로컬 세션을 먼저 지운다. 원격 세션 폐기 오류가 발생해도
      // 원시 오류를 노출하지 않고 로그인 경로를 유지한다.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('로그아웃 중 문제가 발생했어요. 로그인 화면으로 이동합니다.')),
        );
      }
    }
    if (context.mounted) context.go('/login');
  }

  static Future<void> _showEditDisplayName(
    BuildContext context,
    WidgetRef ref,
    String currentName,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _EditDisplayNameDialog(initialName: currentName),
    );
    if (name == null || !context.mounted) return;
    try {
      await ref.read(plannerControllerProvider).updateDisplayName(name);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이름을 변경했어요.')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이름을 변경하지 못했어요. 다시 시도해 주세요.')),
        );
      }
    }
  }
}

/// Route adapter kept next to settings so the app shell does not need to
/// expose notification internals to the rest of the navigation tree.
class NotificationSettingsRoute extends ConsumerWidget {
  const NotificationSettingsRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(notificationControllerProvider);
    final scheduler = ref.read(localNotificationSchedulerProvider);
    return NotificationSettingsScreen(
      accountEnabled: controller.settings.enabled,
      pushEnabled: controller.settings.pushEnabled,
      permissionState: controller.permission,
      localCapability: controller.capability,
      pushCapability: controller.pushCapability,
      onAccountChanged: controller.isLoading
          ? null
          : (value) => controller.setAccountEnabled(value),
      // The server provider is intentionally unconfigured in this stage.
      // Keep the callback absent even if a persisted push flag is true.
      onPushChanged:
          controller.pushCapability == NotificationCapabilityState.available
          ? (value) => controller.saveSettings(
              controller.settings.copyWith(pushEnabled: value),
            )
          : null,
      onRequestPermission: () => controller.requestPermission(),
      onOpenSystemSettings: scheduler is FlutterLocalNotificationScheduler
          ? scheduler.openAppNotificationSettings
          : null,
      onRetry: () => controller.refreshPermission(),
    );
  }
}

class _EditDisplayNameDialog extends StatefulWidget {
  const _EditDisplayNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_EditDisplayNameDialog> createState() => _EditDisplayNameDialogState();
}

class _EditDisplayNameDialogState extends State<_EditDisplayNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty || name.length > 120) {
      setState(() => _errorText = '1자 이상 120자 이하로 입력해 주세요.');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    // The maxLength counter increases the field's intrinsic height at large
    // text scales.  AlertDialog's scrollable viewport prevents that content
    // from overflowing when the keyboard consumes most of the screen.
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: const Text('이름 변경'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 120,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(labelText: '표시 이름', errorText: _errorText),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _submit, child: const Text('저장')),
    ],
  );
}
