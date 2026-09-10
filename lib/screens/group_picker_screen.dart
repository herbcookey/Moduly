import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/timezone_utils.dart';
import '../core/invite_code_utils.dart';
import '../state/app_state.dart';
import 'timezone_picker.dart';

class GroupPickerScreen extends ConsumerStatefulWidget {
  const GroupPickerScreen({super.key});

  @override
  ConsumerState<GroupPickerScreen> createState() => _GroupPickerScreenState();
}

class _GroupPickerScreenState extends ConsumerState<GroupPickerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(plannerControllerProvider);
      if (controller.groups.isEmpty && controller.isAuthenticated) {
        controller.loadGroups();
      }
    });
  }

  Future<void> _showCreateDialog() async {
    if (!mounted || ref.read(plannerControllerProvider).isSaving) return;
    final controller = ref.read(plannerControllerProvider);
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => _CreateGroupDialog(
        onSubmit: (name, description, timezone) async {
          await controller.createGroup(name, description, timezone: timezone);
        },
      ),
    );
    if (created == true && mounted) context.go('/home');
  }

  Future<void> _showJoinDialog() async {
    if (!mounted || ref.read(plannerControllerProvider).isSaving) return;
    final code = await showDialog<String>(
      context: context,
      builder: (context) => const _JoinGroupDialog(),
    );
    if (code == null || code.trim().isEmpty || !mounted) return;
    final controller = ref.read(plannerControllerProvider);
    try {
      await controller.joinGroup(code.trim());
      if (mounted) context.go('/home');
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(plannerControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('어디서 함께할까요?'),
        actions: <Widget>[
          IconButton(
            tooltip: '로그아웃',
            onPressed: controller.isSaving ? null : _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.loadGroups,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
          children: <Widget>[
            Text(
              '그룹을 선택하면\n오늘의 약속이 보여요.',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '가족, 프로젝트, 동아리 등 어떤 모임도 좋아요.',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            if (controller.isLoading && controller.groups.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Semantics(
                    label: '그룹 불러오는 중',
                    liveRegion: true,
                    child: const CircularProgressIndicator(),
                  ),
                ),
              )
            else if (controller.groups.isEmpty)
              _EmptyGroups(
                isSaving: controller.isSaving,
                onCreate: _showCreateDialog,
                onJoin: _showJoinDialog,
              )
            else ...<Widget>[
              ...controller.groups.map(
                (group) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: controller.isSaving
                          ? null
                          : () {
                              // 그룹 선택은 동기 상태(선택된 그룹/달력 범위)를 먼저
                              // 설치한다. 네트워크 기반 멤버/일정 조회가 끝날 때까지
                              // 화면 전환을 막지 않고 홈을 즉시 표시하되, 방어적으로
                              // Future 오류를 소비해 위젯 콜백의 unhandled 오류를
                              // 만들지 않는다. 상세 오류는 컨트롤러가 상태에 기록한다.
                              unawaited(
                                _settleGroupSelection(controller, group.id),
                              );
                              if (context.mounted) context.go('/home');
                            },
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: <Widget>[
                            CircleAvatar(
                              backgroundColor: colorFromValue(group.colorValue),
                              child: Icon(
                                Icons.groups,
                                color: contrastingForeground(
                                  colorFromValue(group.colorValue),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    group.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  if (group.description.isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 4),
                                    Text(
                                      group.description,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: controller.isSaving ? null : _showJoinDialog,
                icon: const Icon(Icons.link),
                label: const Text('초대 코드로 참여'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: controller.isSaving ? null : _showCreateDialog,
                icon: const Icon(Icons.add),
                label: const Text('새 그룹 만들기'),
              ),
            ],
            if (controller.errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                label: '오류: ${controller.errorMessage!}',
                child: Text(
                  controller.errorMessage!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _settleGroupSelection(
    PlannerController controller,
    String groupId,
  ) async {
    try {
      await controller.selectGroup(groupId);
    } catch (_) {
      // PlannerController는 일반적으로 오류를 errorMessage에 기록한다. 선택
      // 호출 계약이 바뀌거나 사용자 지정 저장소가 예외를 밖으로 전달하더라도
      // 백그라운드 선택 Future가 위젯 트리에 unhandled 오류로 남지 않게 한다.
    }
  }

  Future<void> _signOut() async {
    try {
      await ref.read(plannerControllerProvider).signOut();
    } catch (_) {
      // 로그아웃은 로컬 세션을 먼저 지운다. 원격 세션 폐기 오류가 발생해도
      // 원시 오류를 노출하지 않고 로그인 경로를 유지한다.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('로그아웃 중 문제가 발생했어요. 로그인 화면으로 이동합니다.')),
        );
      }
    }
    if (mounted) context.go('/login');
  }
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog({required this.onSubmit});

  final Future<void> Function(String name, String description, String timezone)
  onSubmit;

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String _timezone = defaultPlannerTimezone;
  String? _asyncError;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isSubmitting = true;
      _asyncError = null;
    });
    try {
      await widget.onSubmit(
        _nameController.text.trim(),
        _descriptionController.text.trim(),
        _timezone,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      final message = error is FormatException
          ? error.message
          : error.toString().contains('그룹 작업이 진행 중')
          ? '그룹 작업이 진행 중입니다. 잠시 후 다시 시도해 주세요.'
          : '그룹을 만들지 못했어요. 입력 내용을 확인한 뒤 다시 시도해 주세요.';
      setState(() {
        _isSubmitting = false;
        _asyncError = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final maxHeight = (media.size.height - media.viewInsets.bottom - 240)
        .clamp(180.0, 520.0)
        .toDouble();
    final maxWidth = (media.size.width - media.viewInsets.horizontal - 32)
        .clamp(220.0, 520.0)
        .toDouble();
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('새 그룹 만들기'),
      content: SizedBox(
        width: maxWidth,
        height: maxHeight,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  maxLength: 160,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  decoration: const InputDecoration(labelText: '그룹 이름'),
                  validator: (value) {
                    final name = value?.trim() ?? '';
                    if (name.isEmpty) return '그룹 이름을 입력해 주세요.';
                    if (name.length > 160) {
                      return '그룹 이름은 160자 이하로 입력해 주세요.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                IanaTimezoneField(
                  value: _timezone,
                  enabled: !_isSubmitting,
                  onChanged: (value) => setState(() => _timezone = value),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  maxLines: 2,
                  maxLength: 10000,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: '설명 (선택)'),
                  validator: (value) => (value?.length ?? 0) > 10000
                      ? '설명은 10,000자 이하로 입력해 주세요.'
                      : null,
                ),
                if (_asyncError != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Semantics(
                    liveRegion: true,
                    label: '오류: $_asyncError',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _asyncError!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('만들기'),
        ),
      ],
    );
  }
}

class _JoinGroupDialog extends StatefulWidget {
  const _JoinGroupDialog();

  @override
  State<_JoinGroupDialog> createState() => _JoinGroupDialogState();
}

class _JoinGroupDialogState extends State<_JoinGroupDialog> {
  final TextEditingController _codeController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    // 동작은 고정되고 접근 가능한 상태로 유지하면서 제목/양식이 키보드로 제한된
    // 표시 영역에 맞게 줄어들게 한다.
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: const Text('초대 코드로 참여'),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _codeController,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: '초대 코드',
          hintText: '예: 7K9M-W3PX-Q2RT',
        ),
        validator: _inviteCodeValidator,
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(onPressed: _submit, child: const Text('참여')),
    ],
  );

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(context, _codeController.text);
  }
}

String? _inviteCodeValidator(String? value) {
  final compact = normalizeInviteCode(value ?? '');
  if (compact.isEmpty) return '초대 코드를 입력해 주세요.';
  // 로컬 미리보기에서는 문서에 명시된 데모 토큰을 계속 허용한다. 원격 초대는 현재의
  // 12자 알파벳이나 레거시 48자 16진수 토큰 중 하나를 사용한다.
  final isDemoCode = compact == 'FAMILY';
  final isShortCode =
      compact.length == inviteCodeLength &&
      compact.split('').every(inviteCodeAlphabet.contains);
  final isLegacyCode = RegExp(
    r'^[0-9a-f]{48}$',
    caseSensitive: false,
  ).hasMatch(compact);
  if (!isDemoCode && !isShortCode && !isLegacyCode) {
    return '초대 코드를 확인해 주세요.';
  }
  return null;
}

class _EmptyGroups extends StatelessWidget {
  const _EmptyGroups({
    required this.isSaving,
    required this.onCreate,
    required this.onJoin,
  });
  final bool isSaving;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: <Widget>[
            Icon(
              Icons.people_outline,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              '아직 그룹이 없어요',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '새 그룹을 만들거나 초대 코드를 입력해 보세요.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isSaving ? null : onCreate,
                icon: const Icon(Icons.add),
                label: const Text('새 그룹 만들기'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: isSaving ? null : onJoin,
                icon: const Icon(Icons.link),
                label: const Text('초대 코드로 참여'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
