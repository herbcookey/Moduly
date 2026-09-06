import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../core/invite_code_utils.dart';
import '../models/app_models.dart';
import '../state/app_state.dart';

class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(plannerControllerProvider);
    final group = controller.selectedGroup;
    final scheme = Theme.of(context).colorScheme;
    final owner = controller.isGroupOwner;
    return Scaffold(
      appBar: AppBar(
        title: const Text('멤버'),
        actions: <Widget>[
          if (owner)
            IconButton(
              tooltip: '멤버 초대',
              onPressed: controller.isSaving
                  ? null
                  : () => _showCreateInvite(context, ref),
              icon: const Icon(Icons.person_add_alt_1),
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
              Text(
                group.name,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (group.description.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  group.description,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
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
                onCreate: () => _showCreateInvite(context, ref),
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
    required this.onCreate,
    required this.onRevoke,
  });
  final List<InviteCode> invites;
  final bool isSaving;
  final VoidCallback onCreate;
  final ValueChanged<InviteCode> onRevoke;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '초대 코드',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: isSaving ? null : onCreate,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('새 코드'),
            ),
          ],
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
