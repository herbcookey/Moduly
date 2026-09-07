import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/app_models.dart';
import '../repositories/schedule_repository.dart';
import '../state/app_state.dart';

/// Token-free invite landing page.
///
/// The controller owns the opaque token and exposes only a sanitized
/// [InvitePreview].  This screen therefore never receives a token through a
/// constructor, route extra, semantics label, error message, or analytics
/// callback.  Joining remains an explicit user action after the preview.
class InvitePreviewScreen extends ConsumerStatefulWidget {
  const InvitePreviewScreen({super.key});

  @override
  ConsumerState<InvitePreviewScreen> createState() =>
      _InvitePreviewScreenState();
}

class _InvitePreviewScreenState extends ConsumerState<InvitePreviewScreen> {
  bool _initialLoadRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialLoadRequested) return;
      _initialLoadRequested = true;
      unawaited(_previewPendingInvite());
    });
  }

  Future<void> _previewPendingInvite() async {
    final controller = ref.read(plannerControllerProvider);
    if (!controller.isAuthenticated || !controller.hasPendingInvite) return;
    // The controller is idempotent and owns all token validation.  Calling
    // this once after route capture also handles a native cold link that was
    // delivered just before the widget was mounted.
    try {
      await controller.previewPendingInvite();
    } catch (_) {
      // The controller publishes a typed, token-free error for the page.
    }
  }

  Future<void> _retry() async {
    final controller = ref.read(plannerControllerProvider);
    if (controller.isPreviewingInvite || controller.isAcceptingInvite) return;
    try {
      await controller.retryPendingInvite();
    } catch (_) {
      // Keep the stable unavailable/rate-limit message rendered below.
    }
  }

  Future<void> _accept() async {
    final controller = ref.read(plannerControllerProvider);
    if (controller.isAcceptingInvite || controller.isPreviewingInvite) return;
    try {
      final joined = await controller.acceptPendingInvite();
      // A null result means the controller rejected a stale/expired intent or
      // another accept already consumed this generation.  Stay on the
      // token-free invite surface so the published safe error/retry state is
      // visible; never claim success after a non-commit.
      if (joined != null && mounted) context.go('/home');
    } catch (_) {
      // The controller maps the server response to a safe banner/error state.
    }
  }

  Future<void> _alreadyMember() async {
    final controller = ref.read(plannerControllerProvider);
    if (controller.isAcceptingInvite || controller.isPreviewingInvite) return;
    try {
      // This idempotent controller operation clears the bearer token before
      // selecting the existing group.  Clearing first prevents the router's
      // pending-invite redirect from sending the user back to this screen.
      final joined = await controller.acceptPendingInvite();
      // Even an already-member preview must complete the authoritative join
      // call (which also clears the pending generation) before navigation.
      // A null/stale result stays on this safe surface instead of pretending
      // that the group was opened.
      if (joined != null && mounted) context.go('/groups');
    } catch (_) {
      // The controller publishes a token-free error if selection fails.
    }
  }

  void _cancel() {
    ref.read(plannerControllerProvider).cancelPendingInvite();
    if (mounted) context.go('/groups');
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(plannerControllerProvider);
    final preview = controller.pendingInvitePreview;
    final error = controller.pendingInviteError;
    final scheme = Theme.of(context).colorScheme;
    final loading = controller.isPreviewingInvite;
    final accepting = controller.isAcceptingInvite;
    // PlannerController deliberately exposes only a token-free message at the
    // widget boundary.  Preserve the one distinct, actor-local rate-limit
    // state by matching its stable message; every lifecycle/validity failure
    // intentionally renders the same unavailable copy.
    final rateLimited = error == InviteRateLimitException().message;

    return Scaffold(
      appBar: AppBar(
        title: const Text('초대 확인'),
        leading: Semantics(
          button: true,
          label: '초대 확인 닫기',
          child: IconButton(
            tooltip: '뒤로',
            onPressed: _cancel,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
          children: <Widget>[
            Text(
              '그룹 초대',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '참여하기 전에 그룹 정보를 확인해 주세요.',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            if (!controller.isAuthenticated)
              _InviteSignInPrompt(
                onSignIn: () => context.go('/login'),
                onCancel: _cancel,
              )
            else if (loading || accepting)
              _LoadingInvite(accepting: accepting)
            else if (preview != null)
              _InviteDetails(
                preview: preview,
                onAccept: preview.alreadyMember ? null : _accept,
                onAlreadyMember: preview.alreadyMember ? _alreadyMember : null,
                onCancel: _cancel,
              )
            else
              _InviteError(
                rateLimited: rateLimited,
                onRetry: _retry,
                onCancel: _cancel,
              ),
          ],
        ),
      ),
    );
  }
}

class _InviteSignInPrompt extends StatelessWidget {
  const _InviteSignInPrompt({required this.onSignIn, required this.onCancel});

  final VoidCallback onSignIn;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '초대 정보를 확인하려면 먼저 로그인해 주세요.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onSignIn, child: const Text('로그인하고 계속하기')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onCancel, child: const Text('취소')),
          ],
        ),
      ),
    );
  }
}

class _LoadingInvite extends StatelessWidget {
  const _LoadingInvite({required this.accepting});

  final bool accepting;

  @override
  Widget build(BuildContext context) {
    final label = accepting ? '그룹에 참여하는 중' : '초대 정보를 확인하는 중';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: <Widget>[
            Semantics(
              label: label,
              liveRegion: true,
              child: const CircularProgressIndicator(),
            ),
            const SizedBox(height: 18),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _InviteDetails extends StatelessWidget {
  const _InviteDetails({
    required this.preview,
    required this.onAccept,
    required this.onAlreadyMember,
    required this.onCancel,
  });

  final InvitePreview preview;
  final VoidCallback? onAccept;
  final VoidCallback? onAlreadyMember;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = preview.groupName.trim().isEmpty
        ? '이름 없는 그룹'
        : preview.groupName.trim();
    final description = preview.groupDescription.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              header: true,
              label: '그룹 이름 $title',
              child: Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (description.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                description,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
            const SizedBox(height: 16),
            _InviteInfoRow(
              icon: Icons.schedule_outlined,
              label: '그룹 시간대',
              value: preview.groupTimezone.trim().isEmpty
                  ? '시간대 정보 없음'
                  : preview.groupTimezone.trim(),
            ),
            const SizedBox(height: 8),
            _InviteInfoRow(
              icon: Icons.event_available_outlined,
              label: '초대 유효 기간',
              value: _formatExpiry(preview.expiresAt),
            ),
            if (preview.alreadyMember) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '이미 참여 중인 그룹이에요.',
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
            ],
            const SizedBox(height: 24),
            if (preview.alreadyMember)
              FilledButton(
                onPressed: onAlreadyMember,
                child: const Text('그룹 목록으로 이동'),
              )
            else
              Semantics(
                button: true,
                label: '그룹에 참여',
                hint: '이 그룹에 참여하려면 한 번 더 확인해 주세요',
                excludeSemantics: true,
                child: FilledButton(
                  onPressed: onAccept,
                  child: const Text('이 그룹에 참여'),
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onCancel, child: const Text('취소')),
          ],
        ),
      ),
    );
  }

  static String _formatExpiry(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}.$month.$day $hour:$minute까지';
  }
}

class _InviteInfoRow extends StatelessWidget {
  const _InviteInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              softWrap: true,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteError extends StatelessWidget {
  const _InviteError({
    required this.rateLimited,
    required this.onRetry,
    required this.onCancel,
  });

  final bool rateLimited;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = rateLimited
        ? '요청이 너무 많아요. 잠시 후 다시 시도해 주세요.'
        : '초대 링크가 만료되었거나 더 이상 유효하지 않아요.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Icon(Icons.link_off_outlined, size: 48, color: scheme.error),
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              label: message,
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('다시 시도')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onCancel, child: const Text('닫기')),
          ],
        ),
      ),
    );
  }
}
