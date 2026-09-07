import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/auth_repository.dart';
import '../state/app_state.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  SocialAuthProvider? _socialProviderInFlight;

  void _fillDemoValues() {
    _emailController.text = 'me@example.com';
    _passwordController.text = 'planner';
    setState(() {});
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final controller = ref.read(plannerControllerProvider);
    try {
      await controller.signIn(_emailController.text, _passwordController.text);
      if (mounted) context.go('/groups');
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _socialLogin(SocialAuthProvider provider) async {
    final controller = ref.read(plannerControllerProvider);
    if (_socialProviderInFlight != null || controller.isSaving) return;
    setState(() => _socialProviderInFlight = provider);
    try {
      await controller.signInWithOAuth(provider);
    } catch (_) {
      // PlannerController가 아래 배너에 표시할 안전한 한국어 오류를 저장한다.
      // 제공자 오류가 위젯 밖으로 전파되지 않도록 이 콜백에서는 표시하지 않는다.
    } finally {
      if (mounted) setState(() => _socialProviderInFlight = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(plannerControllerProvider);
    final auth = ref.watch(authRepositoryProvider);
    final demoMode = !auth.isRemote && ref.watch(localDemoAllowedProvider);
    return AuthFrame(
      title: '함께 만드는\n하루의 리듬',
      subtitle: '가족과 팀의 약속을 한 곳에서 가볍게 정리해요.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '이메일',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: (value) => value == null || !value.contains('@')
                  ? '이메일을 입력해 주세요.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              onFieldSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '비밀번호',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (value) =>
                  value == null || value.length < authPasswordMinimumLength
                  ? '$authPasswordMinimumLength자 이상 입력해 주세요.'
                  : null,
            ),
            if (controller.hasPendingInvite) ...<Widget>[
              const SizedBox(height: 16),
              const _PendingInviteLoginNotice(),
            ],
            if (demoMode) ...<Widget>[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: controller.isSaving ? null : _fillDemoValues,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('데모 값 채우기'),
              ),
              Text(
                '데모 모드에서는 예시 값으로 바로 시작할 수 있어요.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
            if (controller.errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              ErrorBanner(message: controller.errorMessage!),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: controller.isSaving ? null : _submit,
              child: controller.isSaving
                  ? const AuthProgressIndicator(label: '로그인 중')
                  : const Text('로그인'),
            ),
            const SizedBox(height: 20),
            const _SocialLoginDivider(),
            const SizedBox(height: 12),
            _SocialLoginButton(
              provider: SocialAuthProvider.google,
              busyProvider: _socialProviderInFlight,
              onPressed: controller.isSaving
                  ? null
                  : () => _socialLogin(SocialAuthProvider.google),
            ),
            const SizedBox(height: 8),
            _SocialLoginButton(
              provider: SocialAuthProvider.apple,
              busyProvider: _socialProviderInFlight,
              onPressed: controller.isSaving
                  ? null
                  : () => _socialLogin(SocialAuthProvider.apple),
            ),
            const SizedBox(height: 8),
            _SocialLoginButton(
              provider: SocialAuthProvider.kakao,
              busyProvider: _socialProviderInFlight,
              onPressed: controller.isSaving
                  ? null
                  : () => _socialLogin(SocialAuthProvider.kakao),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.go('/signup'),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('새 계정 만들기'),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.center,
              child: TextButton(
                onPressed: () => context.go('/forgot-password'),
                child: const Text('비밀번호를 잊으셨나요?'),
              ),
            ),
            const SizedBox(height: 12),
            const AuthLegalLinks(),
          ],
        ),
      ),
    );
  }
}

/// A signed-out invite recipient must be able to leave the forced invite
/// flow without seeing or copying the bearer token.  Clearing the controller
/// intent is enough to let ordinary login navigation proceed; the router's
/// pending-invite guard no longer redirects the user back to the preview.
class _PendingInviteLoginNotice extends ConsumerWidget {
  const _PendingInviteLoginNotice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(plannerControllerProvider);
    if (!controller.hasPendingInvite) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '초대 로그인 흐름',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '초대가 준비됐어요.',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '로그인하면 초대받은 그룹을 확인할 수 있어요.',
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                ref.read(plannerControllerProvider).cancelPendingInvite();
              },
              icon: const Icon(Icons.close),
              label: const Text('초대 흐름 취소'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SocialLoginDivider extends StatelessWidget {
  const _SocialLoginDivider();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      children: <Widget>[
        Expanded(child: Divider(color: color)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '또는',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        Expanded(child: Divider(color: color)),
      ],
    );
  }
}

class _SocialLoginButton extends StatelessWidget {
  const _SocialLoginButton({
    required this.provider,
    required this.busyProvider,
    required this.onPressed,
  });

  final SocialAuthProvider provider;
  final SocialAuthProvider? busyProvider;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final isBusy = busyProvider == provider;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: isBusy
          ? const AuthProgressIndicator(label: '로그인 창을 여는 중')
          : Icon(_iconForProvider(provider)),
      label: Text('${provider.displayName}로 계속하기'),
    );
  }
}

IconData _iconForProvider(SocialAuthProvider provider) => switch (provider) {
  SocialAuthProvider.google => Icons.g_mobiledata,
  SocialAuthProvider.apple => Icons.apple,
  SocialAuthProvider.kakao => Icons.chat_bubble_outline,
};

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final controller = ref.read(plannerControllerProvider);
    try {
      final result = await controller.signUp(
        _emailController.text,
        _passwordController.text,
        _nameController.text,
      );
      if (!mounted) return;
      if (result.requiresEmailConfirmation) {
        context.go(
          Uri(
            path: '/verify-email',
            queryParameters: <String, String>{'email': result.email},
          ).toString(),
        );
      } else {
        context.go('/groups');
      }
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(plannerControllerProvider);
    return AuthFrame(
      title: '반가워요,\n처음 뵙겠습니다',
      subtitle: '이름을 알려주면 일정을 더 따뜻하게 보여드릴게요.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextFormField(
              controller: _nameController,
              maxLength: 120,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '이름',
                prefixIcon: Icon(Icons.face_outlined),
              ),
              validator: (value) {
                final name = value?.trim() ?? '';
                if (name.isEmpty) return '이름을 입력해 주세요.';
                if (name.length > 120) {
                  return '이름은 120자 이하로 입력해 주세요.';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '이메일',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: (value) => value == null || !value.contains('@')
                  ? '이메일을 입력해 주세요.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '비밀번호',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (value) =>
                  value == null || value.length < 6 ? '6자 이상 입력해 주세요.' : null,
            ),
            if (controller.errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              ErrorBanner(message: controller.errorMessage!),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: controller.isSaving ? null : _submit,
              child: controller.isSaving
                  ? const AuthProgressIndicator(label: '가입하는 중')
                  : const Text('가입하고 시작하기'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('이미 계정이 있어요'),
            ),
            const SizedBox(height: 4),
            const AuthLegalLinks(),
          ],
        ),
      ),
    );
  }
}

class AuthFrame extends StatelessWidget {
  const AuthFrame({
    required this.title,
    required this.subtitle,
    required this.child,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      color: scheme.onPrimaryContainer,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 인증 전에도 링크를 제공하여 가입이나 로그인 전에 문서를 확인할 수
/// 있게 한다. 검증되지 않은 공개 URL 대신 앱 내부 경로를 의도적으로
/// 가리킨다.
class AuthLegalLinks extends StatelessWidget {
  const AuthLegalLinks({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        Text(
          '서비스를 이용하기 전에 아래 문서를 확인해 주세요.',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.outline),
        ),
        const SizedBox(height: 2),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            TextButton(
              onPressed: () => context.push('/privacy-policy'),
              child: const Text('개인정보처리방침'),
            ),
            Text('·', style: TextStyle(color: scheme.outline)),
            TextButton(
              onPressed: () => context.push('/terms-of-service'),
              child: const Text('이용약관'),
            ),
          ],
        ),
      ],
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({required this.message, super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: '오류: $message',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 콜백 타입을 사용해 인증 화면이 컨트롤러와 독립되도록 한다. 로컬 데모
/// 어댑터와 Supabase 어댑터 모두에 유용하며, 위젯 테스트에서도 화면을
/// 간단하게 실행할 수 있다.
typedef EmailAuthAction = Future<void> Function(String email);
typedef PasswordAuthAction = Future<void> Function(String password);
typedef PasswordResetCompletionAction = Future<void> Function();

enum _AuthActionState { idle, loading, success, error }

/// Supabase가 이메일 확인을 요구하는 가입 직후에 표시한다. 확인 대기
/// 상태를 잃지 않고 이메일을 수정할 수 있다.
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({this.initialEmail, this.onResend, super.key});

  final String? initialEmail;
  final EmailAuthAction? onResend;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  late final TextEditingController _emailController = TextEditingController(
    text: widget.initialEmail ?? '',
  );
  final _formKey = GlobalKey<FormState>();
  _AuthActionState _state = _AuthActionState.idle;
  String? _error;
  bool _editingEmail = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _state = _AuthActionState.loading;
      _error = null;
    });
    try {
      // null 콜백은 로컬 데모에서 의도적으로 성공하는 무동작이다. 운영
      // 경로에서는 저장소/컨트롤러 콜백을 전달한다.
      await widget.onResend?.call(_emailController.text.trim());
      if (!mounted) return;
      setState(() => _state = _AuthActionState.success);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _AuthActionState.error;
        _error = _friendlyAuthError(error);
      });
    }
  }

  String _friendlyAuthError(Object error) {
    if (error is AuthException) {
      final message = error.message.trim();
      if (message == authResendSignupErrorMessage ||
          message == '이메일을 입력해 주세요.') {
        return message;
      }
    }
    // Callbacks can be supplied by a low-level adapter or a test double. Never
    // render its toString(), because provider responses may contain account or
    // server details. Only repository-owned Korean copy is allowed through.
    return authResendSignupErrorMessage;
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return AuthFrame(
      title: '메일함을 확인해 주세요',
      subtitle: '인증 링크를 눌러 계정을 활성화하면 Moduly를 시작할 수 있어요.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.mark_email_read_outlined,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _emailController.text.trim().isEmpty
                          ? '입력한 이메일 주소로 인증 메일을 보냈어요.'
                          : '${_emailController.text.trim()}\n으로 인증 메일을 보냈어요.',
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSecondaryContainer,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (_editingEmail) ...<Widget>[
              TextFormField(
                controller: _emailController,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '이메일',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
                validator: _emailValidator,
                onFieldSubmitted: (_) => _resend(),
              ),
              const SizedBox(height: 12),
            ],
            if (state == _AuthActionState.error && _error != null)
              ErrorBanner(message: _error!),
            if (state == _AuthActionState.success)
              const AuthStatusMessage(
                icon: Icons.check_circle_outline,
                message: '인증 메일을 다시 보냈어요. 메일함을 확인해 주세요.',
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: state == _AuthActionState.loading ? null : _resend,
              child: state == _AuthActionState.loading
                  ? const AuthProgressIndicator(label: '메일 보내는 중')
                  : const Text('인증 메일 다시 보내기'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: state == _AuthActionState.loading
                  ? null
                  : () => setState(() {
                      _editingEmail = !_editingEmail;
                      _state = _AuthActionState.idle;
                      _error = null;
                    }),
              child: Text(_editingEmail ? '이메일 수정 닫기' : '이메일 주소 변경'),
            ),
            const SizedBox(height: 4),
            OutlinedButton(
              onPressed: state == _AuthActionState.loading
                  ? null
                  : () => context.go('/login'),
              child: const Text('로그인으로 돌아가기'),
            ),
          ],
        ),
      ),
    );
  }
}

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({this.onRequest, super.key});

  final EmailAuthAction? onRequest;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  _AuthActionState _state = _AuthActionState.idle;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _state = _AuthActionState.loading;
      _error = null;
    });
    try {
      await widget.onRequest?.call(_emailController.text.trim());
      if (!mounted) return;
      setState(() => _state = _AuthActionState.success);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _AuthActionState.error;
        // 호출자가 컨트롤러 대신 낮은 수준의 인증 어댑터를 직접 전달해도
        // 복구 양식에서 계정 존재 여부가 드러나지 않게 한다.
        _error = passwordResetRequestErrorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return AuthFrame(
      title: '비밀번호를 잊으셨나요?',
      subtitle: '가입한 이메일 주소를 입력하면 비밀번호를 바꿀 수 있는 링크를 보내드려요.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextFormField(
              controller: _emailController,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '이메일',
                hintText: 'you@example.com',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              validator: _emailValidator,
              onFieldSubmitted: (_) => _request(),
            ),
            const SizedBox(height: 16),
            if (state == _AuthActionState.error && _error != null)
              ErrorBanner(message: _error!),
            if (state == _AuthActionState.success)
              const AuthStatusMessage(
                icon: Icons.mark_email_read_outlined,
                message: passwordResetRequestMessage,
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: state == _AuthActionState.loading ? null : _request,
              child: state == _AuthActionState.loading
                  ? const AuthProgressIndicator(label: '메일 보내는 중')
                  : const Text('재설정 메일 보내기'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: state == _AuthActionState.loading
                  ? null
                  : () => context.go('/login'),
              child: const Text('로그인으로 돌아가기'),
            ),
          ],
        ),
      ),
    );
  }
}

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({this.onUpdate, this.onCompleted, super.key});

  final PasswordAuthAction? onUpdate;
  final PasswordResetCompletionAction? onCompleted;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  _AuthActionState _state = _AuthActionState.idle;
  String? _error;
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _state = _AuthActionState.loading;
      _error = null;
    });
    try {
      await widget.onUpdate?.call(_passwordController.text);
      if (!mounted) return;
      setState(() => _state = _AuthActionState.success);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _AuthActionState.error;
        _error = _friendlyAuthError(error);
      });
    }
  }

  String _friendlyAuthError(Object error) {
    if (error is AuthException) {
      final message = error.message.trim();
      if (message == authRecoveredPasswordErrorMessage ||
          message == '8자 이상 입력해 주세요.') {
        return message;
      }
    }
    // Keep raw provider/session responses out of the reset form. The fallback
    // tells the user how to recover without revealing account state.
    return authRecoveredPasswordErrorMessage;
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return AuthFrame(
      title: '새 비밀번호 만들기',
      subtitle: '다른 서비스에서 쓰지 않는 안전한 비밀번호를 설정해 주세요.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextFormField(
              controller: _passwordController,
              autofocus: true,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '새 비밀번호',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? '비밀번호 표시' : '비밀번호 숨기기',
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: (value) =>
                  value == null || value.length < 8 ? '8자 이상 입력해 주세요.' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirmationController,
              obscureText: _obscureConfirmation,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _update(),
              decoration: InputDecoration(
                labelText: '새 비밀번호 확인',
                prefixIcon: const Icon(Icons.lock_reset_outlined),
                suffixIcon: IconButton(
                  tooltip: _obscureConfirmation ? '비밀번호 표시' : '비밀번호 숨기기',
                  onPressed: () => setState(
                    () => _obscureConfirmation = !_obscureConfirmation,
                  ),
                  icon: Icon(
                    _obscureConfirmation
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: (value) =>
                  value != _passwordController.text ? '비밀번호가 일치하지 않아요.' : null,
            ),
            const SizedBox(height: 16),
            if (state == _AuthActionState.error && _error != null)
              ErrorBanner(message: _error!),
            if (state == _AuthActionState.success)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const AuthStatusMessage(
                    icon: Icons.check_circle_outline,
                    message: '비밀번호를 변경했어요. 새 비밀번호로 로그인해 주세요.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      try {
                        await widget.onCompleted?.call();
                      } catch (_) {
                        // Returning to the login screen is still safe when
                        // the short-lived recovery session has expired.
                      }
                      if (!context.mounted) return;
                      context.go('/login');
                    },
                    child: const Text('로그인하러 가기'),
                  ),
                ],
              )
            else
              FilledButton(
                onPressed: state == _AuthActionState.loading ? null : _update,
                child: state == _AuthActionState.loading
                    ? const AuthProgressIndicator(label: '변경하는 중')
                    : const Text('비밀번호 변경하기'),
              ),
          ],
        ),
      ),
    );
  }
}

class AuthProgressIndicator extends StatelessWidget {
  const AuthProgressIndicator({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      liveRegion: true,
      child: const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class AuthStatusMessage extends StatelessWidget {
  const AuthStatusMessage({
    required this.icon,
    required this.message,
    super.key,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: scheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onPrimaryContainer, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Supabase가 모바일 인증 콜백을 세션으로 교환하는 동안 표시하는 중계
/// 화면이다. 타입 지정 인증 이벤트가 도착하면 라우터가 플래너 또는 복구
/// 흐름으로 바꾸며, 콜백 URL만으로 추측하지 않는다.
class AuthCallbackScreen extends StatelessWidget {
  const AuthCallbackScreen({this.error, super.key});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final hasError = error != null && error!.trim().isNotEmpty;
    return AuthFrame(
      title: hasError ? '인증 링크를 확인하지 못했어요' : '인증 링크를 확인하는 중이에요',
      subtitle: hasError
          ? '링크가 만료되었거나 이미 사용되었을 수 있어요. 새 링크를 요청해 주세요.'
          : '잠시만 기다려 주세요. 안전하게 로그인 상태를 확인하고 있어요.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (hasError)
            ErrorBanner(message: error!)
          else
            Semantics(
              label: '인증 링크를 확인하는 중',
              liveRegion: true,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: const CircularProgressIndicator(),
                ),
              ),
            ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => context.go('/login'),
            child: const Text('로그인으로 돌아가기'),
          ),
        ],
      ),
    );
  }
}

String? _emailValidator(String? value) {
  final email = value?.trim() ?? '';
  if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
    return '올바른 이메일 주소를 입력해 주세요.';
  }
  return null;
}
