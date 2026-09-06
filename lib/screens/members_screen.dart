import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/invite_code_utils.dart';
import '../models/app_models.dart';
import '../repositories/schedule_repository.dart';
import '../state/app_state.dart';
import 'group_management_dialogs.dart';

class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  /// Resolve the version at the moment a dialog submits, rather than the
  /// version captured when that dialog opened.  Conflict recovery reloads the
  /// controller while keeping the dialog (and its draft) alive, so a retry
  /// must use that freshly loaded value.  A switched/removed/archived group
  /// is a terminal stale callback and fails closed before any repository write.
  static PlannerGroup _latestGroupForSubmit(
    PlannerController controller,
    PlannerGroup openedGroup,
  ) {
    final latest = controller.selectedGroup;
    if (latest == null ||
        latest.id != openedGroup.id ||
        latest.isArchived ||
        controller.user == null) {
      throw const ScheduleConflictException(
        '그룹이 변경되었거나 더 이상 사용할 수 없습니다. 최신 그룹을 선택해 주세요.',
      );
    }
    return latest;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(plannerControllerProvider);
    final group = controller.selectedGroup;
    final scheme = Theme.of(context).colorScheme;
    final owner = controller.isGroupOwner;
    final activeNonOwners = controller.members
        .where(
          (member) =>
              member.isActive &&
              !member.isOwner &&
              member.id != controller.user?.id,
        )
        .toList(growable: false);
    final currentMembership = controller.members
        .where((member) => member.id == controller.user?.id)
        .firstOrNull;
    final canLeave =
        group != null && !owner && currentMembership?.isActive == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('멤버'),
        actions: <Widget>[
          if (owner)
            TextButton.icon(
              onPressed: controller.isSaving
                  ? null
                  : () => _showCreateInvite(context, ref),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('새 코드'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (group != null) await controller.selectGroup(group.id);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: <Widget>[
            if (group != null) ...<Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              group.name,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (owner)
                            IconButton(
                              tooltip: '그룹 정보 편집',
                              onPressed: controller.isSaving
                                  ? null
                                  : () => _showEditGroup(context, ref, group),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                        ],
                      ),
                      if (group.description.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          group.description,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        group.timezone,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (owner)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '소유자는 그룹을 바로 나갈 수 없어요. 유지하려면 먼저 소유권을 이전하고, '
                              '그룹을 끝내려면 보관하세요.',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 10),
                            if (activeNonOwners.isEmpty) ...<Widget>[
                              Text(
                                '활성 멤버가 없어 소유권을 이전할 수 없어요. 그룹을 끝내려면 보관하세요.',
                                style: TextStyle(color: scheme.error),
                              ),
                              const SizedBox(height: 8),
                            ],
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: <Widget>[
                                Semantics(
                                  button: true,
                                  enabled:
                                      activeNonOwners.isNotEmpty &&
                                      !controller.isSaving,
                                  label: '소유권 이전',
                                  hint: activeNonOwners.isEmpty
                                      ? '활성 멤버가 없어 이전할 수 없음'
                                      : null,
                                  child: OutlinedButton.icon(
                                    onPressed:
                                        activeNonOwners.isEmpty ||
                                            controller.isSaving
                                        ? null
                                        : () => _showTransferGroup(
                                            context,
                                            ref,
                                            group,
                                            activeNonOwners,
                                          ),
                                    icon: const Icon(Icons.swap_horiz),
                                    label: const Text('소유권 이전'),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: controller.isSaving
                                      ? null
                                      : () => _showArchiveGroup(
                                          context,
                                          ref,
                                          group,
                                        ),
                                  icon: const Icon(Icons.archive_outlined),
                                  label: const Text('그룹 보관'),
                                ),
                              ],
                            ),
                          ],
                        )
                      else if (canLeave)
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: controller.isSaving
                                ? null
                                : () => _showLeaveGroup(context, ref, group),
                            icon: const Icon(Icons.exit_to_app),
                            label: const Text('그룹 나가기'),
                          ),
                        )
                      else if (group.ownerId == controller.user?.id ||
                          currentMembership?.isOwner == true)
                        OwnerLeaveNotice(
                          onTransfer: activeNonOwners.isEmpty
                              ? null
                              : () => _showTransferGroup(
                                  context,
                                  ref,
                                  group,
                                  activeNonOwners,
                                ),
                          onArchive: () =>
                              _showArchiveGroup(context, ref, group),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            if (controller.isLoading && controller.members.isEmpty)
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: Semantics(
                    label: '멤버 불러오는 중',
                    liveRegion: true,
                    child: const CircularProgressIndicator(),
                  ),
                ),
              )
            else if (controller.members.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: Text('아직 멤버가 없어요.')),
              )
            else ...<Widget>[
              Text(
                '현재 멤버 ${controller.members.length}명',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              ...controller.members.map(
                (member) => _MemberTile(
                  member: member,
                  canRemove: owner && !member.isOwner,
                  onRemove: () => _removeMember(context, ref, member),
                ),
              ),
            ],
            if (owner) ...<Widget>[
              const SizedBox(height: 24),
              _InviteSection(
                invites: controller.invites,
                isSaving: controller.isSaving,
                onRevoke: (invite) => _revokeInvite(context, ref, invite),
              ),
            ] else ...<Widget>[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.link),
                label: const Text('초대 코드는 그룹 소유자에게 요청하세요'),
              ),
            ],
            if (controller.errorMessage != null) ...<Widget>[
              const SizedBox(height: 14),
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

  static Future<void> _showEditGroup(
    BuildContext context,
    WidgetRef ref,
    PlannerGroup group,
  ) async {
    final controller = ref.read(plannerControllerProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => EditGroupDialog(
        group: group,
        onSubmit: (name, description, timezone) async {
          final latest = _latestGroupForSubmit(controller, group);
          await controller.updateGroup(
            name: name,
            description: description,
            timezone: timezone,
            expectedVersion: latest.version,
          );
        },
      ),
    );
  }

  static Future<void> _showTransferGroup(
    BuildContext context,
    WidgetRef ref,
    PlannerGroup group,
    List<PlannerMember> candidates,
  ) async {
    final controller = ref.read(plannerControllerProvider);
    final transferred = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => TransferGroupDialog(
        candidates: candidates,
        onSubmit: (memberId) async {
          final latest = _latestGroupForSubmit(controller, group);
          await controller.transferGroupOwnership(
            newOwnerId: memberId,
            expectedVersion: latest.version,
          );
        },
      ),
    );
    if (transferred == true && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('소유권을 이전했어요.')));
    }
  }

  static Future<void> _showArchiveGroup(
    BuildContext context,
    WidgetRef ref,
    PlannerGroup group,
  ) async {
    final archived = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ArchiveGroupDialog(
        groupName: group.name,
        onSubmit: () {
          final controller = ref.read(plannerControllerProvider);
          final latest = _latestGroupForSubmit(controller, group);
          return controller.archiveGroup(expectedVersion: latest.version);
        },
      ),
    );
    if (archived == true && context.mounted) context.go('/groups');
  }

  static Future<void> _showLeaveGroup(
    BuildContext context,
    WidgetRef ref,
    PlannerGroup group,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('그룹을 나갈까요?'),
        content: Text('${group.name}에서 나가면 멤버 목록과 일정에 더 이상 접근할 수 없습니다.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(plannerControllerProvider).leaveGroup();
      if (context.mounted) context.go('/groups');
    } catch (error) {
      if (!context.mounted) return;
      await _showOperationError(context, error);
    }
  }

  static Future<void> _showOperationError(
    BuildContext context,
    Object error,
  ) async {
    final message = error is ScheduleConflictException
        ? error.message
        : error is ScheduleValidationException
        ? error.message
        : error is FormatException
        ? error.message
        : '작업을 완료하지 못했어요. 최신 내용을 다시 확인해 주세요.';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('변경 내용을 저장하지 못했어요'),
        content: Semantics(
          liveRegion: true,
          label: message,
          child: Text(message),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  static Future<void> _removeMember(
    BuildContext context,
    WidgetRef ref,
    PlannerMember member,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${member.name}님을 제거할까요?'),
        content: const Text('이 멤버는 그룹 일정과 멤버 목록에서 숨겨집니다.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('제거'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(plannerControllerProvider).deactivateMember(member);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${member.name}님을 제거했어요.')));
      }
    } catch (_) {
      // 컨트롤러가 화면에 지역화된 오류 배너를 표시한다.
    }
  }

  static Future<void> _showCreateInvite(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final options = await showDialog<(int, int)>(
      context: context,
      builder: (dialogContext) => const _CreateInviteDialog(),
    );
    if (options == null || !context.mounted) return;
    try {
      final invite = await ref
          .read(plannerControllerProvider)
          .createInviteCode(
            ttl: Duration(days: options.$1),
            maxUses: options.$2,
          );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('초대 코드가 준비됐어요'),
          content: SelectableText(
            '${invite.token == null ? '(보안상 다시 표시되지 않음)' : formatInviteCode(invite.token!)}\n\n'
            '유효 기간: ${_date(invite.expiresAt)}\n'
            '사용 횟수: ${invite.maxUses}회',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('초대 코드를 만들지 못했어요.')));
      }
    }
  }

  static Future<void> _revokeInvite(
    BuildContext context,
    WidgetRef ref,
    InviteCode invite,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('초대 코드를 취소할까요?'),
        content: const Text('이 코드로는 더 이상 그룹에 참여할 수 없습니다.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('취소하기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(plannerControllerProvider).revokeInvite(invite);
    } catch (_) {
      // 오류는 컨트롤러 배너에 표시된다.
    }
  }

  static String _date(DateTime value) =>
      '${value.toLocal().year}.${value.toLocal().month}.${value.toLocal().day}';
}

class _CreateInviteDialog extends StatefulWidget {
  const _CreateInviteDialog();

  @override
  State<_CreateInviteDialog> createState() => _CreateInviteDialogState();
}

class _CreateInviteDialogState extends State<_CreateInviteDialog> {
  final TextEditingController _maxUsesController = TextEditingController(
    text: '20',
  );
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  int _days = 7;

  @override
  void dispose() {
    _maxUsesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    // Keep the title and form in the dialog's flexible scroll viewport.  A
    // focused field can leave only a short viewport when the keyboard is
    // visible, especially with a large text scale; a non-scrollable
    // AlertDialog lets the form's intrinsic height overflow that viewport.
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: const Text('초대 코드 만들기'),
    content: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DropdownButtonFormField<int>(
            initialValue: _days,
            decoration: const InputDecoration(labelText: '유효 기간'),
            items: const <DropdownMenuItem<int>>[
              DropdownMenuItem(value: 1, child: Text('1일')),
              DropdownMenuItem(value: 7, child: Text('7일')),
              DropdownMenuItem(value: 30, child: Text('30일')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _days = value);
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _maxUsesController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '최대 사용 횟수',
              hintText: '1~100,000회',
            ),
            validator: (value) {
              final maxUses = int.tryParse(value?.trim() ?? '');
              if (maxUses == null) return '사용 횟수를 입력해 주세요.';
              if (maxUses < 1 || maxUses > 100000) {
                return '사용 횟수는 1~100,000회로 입력해 주세요.';
              }
              return null;
            },
          ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () {
          if (!(_formKey.currentState?.validate() ?? false)) return;
          final maxUses = int.parse(_maxUsesController.text.trim());
          Navigator.pop(context, (_days, maxUses));
        },
        child: const Text('만들기'),
      ),
    ],
  );
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.canRemove,
    required this.onRemove,
  });
  final PlannerMember member;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: colorFromValue(member.avatarColor),
          child: Text(
            initials(member.name),
            style: TextStyle(
              color: contrastingForeground(colorFromValue(member.avatarColor)),
            ),
          ),
        ),
        title: Text(
          member.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: member.email.trim().isEmpty ? null : Text(member.email),
        trailing: member.isOwner
            ? const Chip(label: Text('소유자'))
            : canRemove
            ? IconButton(
                tooltip: '멤버 제거',
                onPressed: onRemove,
                icon: const Icon(Icons.person_remove_outlined),
              )
            : null,
      ),
    );
  }
}

class _InviteSection extends StatelessWidget {
  const _InviteSection({
    required this.invites,
    required this.isSaving,
    required this.onRevoke,
  });
  final List<InviteCode> invites;
  final bool isSaving;
  final ValueChanged<InviteCode> onRevoke;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '초대 코드',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        if (invites.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '활성 초대 코드가 없어요. 필요할 때 새로 만들어 보세요.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          ...invites.map(
            (invite) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  invite.isRevoked ? Icons.link_off : Icons.link,
                  color: invite.isRevoked ? scheme.outline : scheme.primary,
                ),
                title: Text(
                  invite.isRevoked
                      ? '취소된 코드'
                      : invite.isExpired
                      ? '만료된 코드'
                      : '사용 가능한 코드',
                ),
                subtitle: Text(
                  '만료 ${MembersScreen._date(invite.expiresAt)} · ${invite.usesCount}/${invite.maxUses}회 사용',
                ),
                trailing: !invite.isRevoked && !invite.isExpired
                    ? IconButton(
                        tooltip: '코드 취소',
                        onPressed: isSaving ? null : () => onRevoke(invite),
                        icon: const Icon(Icons.block_outlined),
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}
