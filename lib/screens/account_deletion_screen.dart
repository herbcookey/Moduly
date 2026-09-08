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
    this.onManageGroups,
    super.key,
  });

  final AccountDeletionRepository repository;
  final AccountDeletedCallback? onDeleted;

  /// 사용자가 계속하기 전에 소유 중인 활성 그룹의 소유권을 이전하거나 보관해야 할 때
  /// 그룹 관리 화면을 연다.
  final VoidCallback? onManageGroups;

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  final _confirmationController = TextEditingController();
  bool _isLoadingImpact = true;
  bool _isSubmitting = false;
  bool _completed = false;
  bool _preflightUnsupported = false;
  AccountDeletionImpact? _impact;
  String? _preflightError;
  String? _errorMessage;
  AccountDeletionResult? _result;

  @override
  void initState() {
    super.initState();
    _loadPreflight();
  }

  @override
  void dispose() {
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _loadPreflight() async {
    if (_isSubmitting || _completed) return;
    setState(() {
      _isLoadingImpact = true;
      _impact = null;
      _preflightError = null;
      _errorMessage = null;
      _preflightUnsupported = false;
    });
    try {
      final impact = await widget.repository.preflight();
      if (!mounted) return;
      setState(() {
        _impact = impact;
        _isLoadingImpact = false;
      });
    } on AccountDeletionCapabilityException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingImpact = false;
        _preflightUnsupported = true;
        _preflightError = error.safeMessage;
      });
    } on AccountDeletionException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingImpact = false;
        _preflightUnsupported =
            error.code == AccountDeletionErrorCode.capability;
        _preflightError = error.safeMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingImpact = false;
        _preflightError = '삭제 영향을 불러오지 못했어요. 다시 시도해 주세요.';
      });
    }
  }

  Future<void> _deleteAccount() async {
    if (_isSubmitting || _completed || _isLoadingImpact) return;
    // 형식이 지정된 사전 점검은 필수다. 이것이 없으면 표시할 영향 요약이나 실행할
    // 확인 상태를 신뢰할 수 없다.
    if (_preflightUnsupported || _impact == null) return;
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
      final result = await widget.repository.deleteAccountWithResult(
        confirmation: confirmation,
      );
      if (!result.deleted) {
        throw const AccountDeletionException(
          '서버 응답 형식이 올바르지 않습니다.',
          code: AccountDeletionErrorCode.protocol,
        );
      }
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _completed = true;
        _result = result;
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
    final impact = _impact;
    final isBlocked = _preflightUnsupported;
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
                      '소유한 활성·보관 그룹과 그 안의 일정·멤버·초대 코드가 영구 삭제됩니다. '
                      '다른 그룹의 멤버십과 내가 만든 일정도 함께 삭제됩니다.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '삭제 영향 미리보기',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            if (_isLoadingImpact)
              Semantics(
                liveRegion: true,
                label: '삭제 영향 불러오는 중',
                child: const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              )
            else if (impact != null)
              _ImpactSummary(
                impact: impact,
                onManageGroups: widget.onManageGroups,
              )
            else
              Card(
                color: isBlocked ? scheme.errorContainer : null,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Semantics(
                        liveRegion: true,
                        label: _preflightError ?? '삭제 영향을 불러오지 못했어요.',
                        child: Text(
                          _preflightError ?? '삭제 영향을 불러오지 못했어요.',
                          style: TextStyle(
                            color: isBlocked ? scheme.onErrorContainer : null,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (!isBlocked)
                        OutlinedButton.icon(
                          onPressed: _isSubmitting ? null : _loadPreflight,
                          icon: const Icon(Icons.refresh),
                          label: const Text('다시 불러오기'),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            const Text(
              '삭제가 시작되면 Auth 계정과 연결된 데이터가 cascade로 모두 삭제됩니다. '
              '감사 기록에서도 개인 식별 정보가 제거될 수 있으며 복구할 수 없습니다.',
            ),
            const SizedBox(height: 20),
            Text(
              '계속하려면 아래에 “$accountDeletionConfirmation”을 입력하세요.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmationController,
              enabled: !_isSubmitting && !_completed && !isBlocked,
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
              if (_result != null && _result!.summary.groups > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '연결된 데이터 ${_result!.summary.groups}개 그룹도 모두 삭제했어요.',
                  ),
                ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed:
                  _isSubmitting ||
                      _completed ||
                      _isLoadingImpact ||
                      isBlocked ||
                      impact == null
                  ? null
                  : _deleteAccount,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
                minimumSize: const Size.fromHeight(48),
              ),
              child: _isSubmitting
                  ? Semantics(
                      label: '계정 삭제 중',
                      liveRegion: true,
                      child: const SizedBox(
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

class _ImpactSummary extends StatelessWidget {
  const _ImpactSummary({required this.impact, this.onManageGroups});

  final AccountDeletionImpact impact;
  final VoidCallback? onManageGroups;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '영구 삭제되는 항목',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '그룹 ${impact.groups}개 · 일정 ${impact.events}개 · '
              '초대 코드 ${impact.invites}개 · 멤버십 ${impact.memberships}개',
            ),
            if (impact.activeOwnedGroups.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              Text('활성 소유 그룹', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ...impact.activeOwnedGroups.map(
                (group) => Text('• ${group.name} · 멤버 ${group.memberCount}명'),
              ),
              const SizedBox(height: 8),
              Text(
                '그룹을 유지하려면 먼저 소유권을 다른 활성 멤버에게 이전하거나 그룹을 보관하세요.',
                style: TextStyle(color: scheme.error),
              ),
              if (onManageGroups != null) ...<Widget>[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onManageGroups,
                  icon: const Icon(Icons.groups_outlined),
                  label: const Text('그룹 관리로 이동'),
                ),
              ],
            ],
            if (impact.archivedOwnedGroups.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                '보관된 소유 그룹 ${impact.archivedOwnedGroups.length}개도 함께 삭제됩니다.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
