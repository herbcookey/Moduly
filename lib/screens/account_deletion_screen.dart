import 'package:flutter/material.dart';

import '../repositories/account_deletion_repository.dart';

typedef AccountDeletedCallback = Future<void> Function();

/// 명시적인 확인 문구와 한 번에 하나만 실행되는 요청을 사용하는 계정
/// 삭제 작업이다. 신원과 삭제의 권한은 서버가 가지며, 이 화면은 확인을
/// 받고 안전한 상태만 표시한다.
class AccountDeletionScreen extends StatefulWidget {
  const AccountDeletionScreen({
    required this.repository,
    this.onDeleted,
    super.key,
  });

  final AccountDeletionRepository repository;
  final AccountDeletedCallback? onDeleted;

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  final _confirmationController = TextEditingController();
  bool _isSubmitting = false;
  bool _completed = false;
  String? _errorMessage;

  @override
  void dispose() {
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _deleteAccount() async {
    if (_isSubmitting || _completed) return;
    final confirmation = _confirmationController.text.trim();
    if (confirmation != accountDeletionConfirmation) {
      setState(() => _errorMessage = '확인 문구를 정확히 입력해 주세요.');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await widget.repository.deleteAccount(confirmation: confirmation);
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _completed = true;
      });
      final callback = widget.onDeleted;
      if (callback != null) await callback();
    } on AccountDeletionException catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = error.safeMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _errorMessage = '계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('계정 삭제')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: <Widget>[
            Card(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.warning_amber_rounded, color: scheme.error),
                    const SizedBox(height: 10),
                    Text(
                      '계정을 삭제하면 되돌릴 수 없어요',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '소유한 일정방과 그 안의 일정·멤버·초대 코드가 영구 삭제됩니다. '
                      '다른 일정방의 멤버 권한과 내가 만든 일정도 함께 삭제됩니다.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '삭제 정책',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '• 소유 일정방과 관련 일정, 멤버십, 초대 코드는 영구 삭제됩니다.\n'
              '• 다른 일정방에서의 멤버십과 작성 일정도 삭제됩니다.\n'
              '• 보안 감사 기록은 개인 식별을 줄이기 위해 작성자 정보가 제거될 수 있습니다.\n'
              '• 삭제가 완료되면 모든 기기에서 로그아웃되며 복구할 수 없습니다.',
            ),
            const SizedBox(height: 24),
            Text(
              '계속하려면 아래에 “$accountDeletionConfirmation”을 입력하세요.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmationController,
              enabled: !_isSubmitting && !_completed,
              autofocus: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _deleteAccount(),
              decoration: const InputDecoration(
                labelText: '확인 문구',
                hintText: accountDeletionConfirmation,
              ),
            ),
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                label: '오류: $_errorMessage',
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ],
            if (_completed) ...<Widget>[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                label: '계정이 삭제되었습니다. 안전하게 로그아웃했어요.',
                child: const Text('계정이 삭제되었습니다. 안전하게 로그아웃했어요.'),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _isSubmitting || _completed ? null : _deleteAccount,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
                minimumSize: const Size.fromHeight(48),
              ),
              child: _isSubmitting
                  ? Semantics(
                      label: '계정 삭제 중',
                      liveRegion: true,
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Text(_completed ? '삭제 완료' : '계정 영구 삭제'),
            ),
            if (!_completed) ...<Widget>[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () => Navigator.of(context).maybePop(),
                child: const Text('취소'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
