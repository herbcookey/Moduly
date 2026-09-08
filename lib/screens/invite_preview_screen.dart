import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/app_models.dart';
import '../repositories/schedule_repository.dart';
import '../state/app_state.dart';

/// 토큰을 포함하지 않는 초대 랜딩 페이지다.
///
/// 컨트롤러가 불투명한 토큰을 소유하고 정제된 [InvitePreview]만 노출한다. 따라서 이
/// 화면은 생성자, 경로 추가 정보, 시맨틱 레이블, 오류 메시지, 분석 콜백을 통해
/// 토큰을 받지 않는다. 가입은 미리보기 후 사용자가 명시적으로 수행하는 동작으로 남는다.
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
    // 컨트롤러는 멱등하며 모든 토큰 검증을 담당한다. 경로를 포착한 뒤 이를 한
    // 번 호출하면 위젯이 마운트되기 직전에 전달된 네이티브 콜드 링크도 처리한다.
    try {
      await controller.previewPendingInvite();
    } catch (_) {
      // 컨트롤러가 페이지에 형식이 지정되고 토큰이 없는 오류를 공개한다.
    }
  }

  Future<void> _retry() async {
    final controller = ref.read(plannerControllerProvider);
    if (controller.isPreviewingInvite || controller.isAcceptingInvite) return;
    try {
      await controller.retryPendingInvite();
    } catch (_) {
      // 아래에 있는 고정된 사용 불가/호출 제한 메시지를 계속 렌더링한다.
    }
  }

  Future<void> _accept() async {
    final controller = ref.read(plannerControllerProvider);
    if (controller.isAcceptingInvite || controller.isPreviewingInvite) return;
    try {
      final joined = await controller.acceptPendingInvite();
      // `null` 결과는 컨트롤러가 오래되거나 만료된 의도를 거부했거나, 다른 수락이
      // 이 세대를 이미 소비했다는 뜻이다. 공개된 안전한 오류/재시도 상태가
      // 보이도록 토큰 없는 초대 화면에 머물며 커밋되지 않은 작업을 성공이라 하지 않는다.
      if (joined != null && mounted) context.go('/home');
    } catch (_) {
      // 컨트롤러가 서버 응답을 안전한 배너/오류 상태로 변환한다.
    }
  }

  Future<void> _alreadyMember() async {
    final controller = ref.read(plannerControllerProvider);
    if (controller.isAcceptingInvite || controller.isPreviewingInvite) return;
    try {
      // 이 멱등 컨트롤러 작업은 기존 그룹을 선택하기 전에 Bearer 토큰을 지운다.
      // 먼저 지우면 라우터의 대기 초대 리디렉션이 사용자를 이 화면으로 되돌리지 않는다.
      final joined = await controller.acceptPendingInvite();
      // 이미 멤버인 미리보기도 화면 이동 전에 신뢰할 수 있는 가입 호출을 완료해야 한다.
      // 이 호출은 대기 세대도 지운다. `null`/오래된 결과는 그룹이 열린 것처럼
      // 가장하지 않고 이 안전한 화면에 남는다.
      if (joined != null && mounted) context.go('/groups');
    } catch (_) {
      // 선택이 실패하면 컨트롤러가 토큰 없는 오류를 공개한다.
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
    // PlannerController는 위젯 경계에서 의도적으로 토큰이 없는 메시지만 노출한다.
    // 고정 메시지를 비교해 행위자 로컬 속도 제한 상태 하나만 구분해서 보존한다. 모든
    // 수명 주기/유효성 실패에는 의도적으로 같은 사용 불가 문구를 렌더링한다.
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
