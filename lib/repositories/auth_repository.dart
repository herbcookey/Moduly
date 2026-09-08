// 공개 생성자 이름은 의도적으로 비공개 필드와 다르게 둔다.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/demo_identity.dart';
import '../models/app_models.dart';

/// 이메일과 브라우저 기반 OAuth 인증 흐름에서 사용하는 딥링크다.
///
/// 이 값은 Supabase 프로젝트의 허용 리디렉션에도 설정한다. 가입 링크와
/// 복구 링크가 같은 Flutter 딥링크 처리기로 돌아와야 하므로 한곳에서
/// 관리하는 것이 중요하다.
const String authCallbackRedirect = 'moduly://auth-callback';
const String authCallbackPath = '/auth-callback';
const int authPasswordMinimumLength = 6;
const int authDisplayNameMaximumLength = 120;

/// 현재 Flutter 플랫폼이 사용하는 리디렉션 URI를 반환한다.
///
/// 네이티브 대상은 등록된 사용자 정의 스킴을 사용해 Supabase가 플랫폼 딥 링크 처리기를
/// 통해 앱으로 돌아올 수 있게 한다. 브라우저는 현재 HTTPS/HTTP 출처에 머물러야 한다.
/// 웹 페이지에서는 사용자 정의 스킴으로 이동할 수 없어 OAuth나 이메일 흐름이 중단되기
/// 때문이다. 브라우저 없이 플랫폼 정책을 테스트할 수 있도록 [baseUri]와 [isWeb]을
/// 주입할 수 있다.
String resolveAuthCallbackRedirect({bool? isWeb, Uri? baseUri}) {
  if (!(isWeb ?? kIsWeb)) return authCallbackRedirect;

  final base = baseUri ?? Uri.base;
  final scheme = base.scheme.toLowerCase();
  // 브라우저에서 Uri.base는 항상 HTTP(S) 출처다. 테스트 호스트나 특수한 임베딩이
  // 출처를 노출하지 않을 때 네이티브 사용자 정의 스킴을 반환하지 말고 상대 경로를
  // 대체값으로 유지한다.
  if ((scheme != 'http' && scheme != 'https') || base.host.isEmpty) {
    return authCallbackPath;
  }
  return Uri(
    scheme: scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: authCallbackPath,
  ).toString();
}

/// 이를 플랫폼 리디렉션이라고 부르는 호출자를 위한 호환 이름이다.
String authCallbackRedirectForPlatform({bool? isWeb, Uri? baseUri}) =>
    resolveAuthCallbackRedirect(isWeb: isWeb, baseUri: baseUri);

/// 비밀번호 복구용 사용자 문구에는 해당 주소가 계정에 속하는지 의도적으로
/// 표시하지 않는다. 서버는 존재하는 주소와 알 수 없는 주소에 같은 결과를
/// 반환해야 하며, 클라이언트 오류도 같은 중립적인 문구를 사용한다.
const String passwordResetRequestMessage =
    '입력한 이메일 주소가 등록되어 있다면 재설정 메일을 보냈어요. 메일함을 확인해 주세요.';
const String passwordResetRequestErrorMessage =
    '요청을 처리하지 못했어요. 입력한 주소가 등록되어 있다면 잠시 후 다시 시도해 주세요.';

/// 이 값을 URL이라고 부르는 연동을 위해 유지하는 별칭이다.
const String authCallbackUrl = authCallbackRedirect;
const String authRedirectUrl = authCallbackRedirect;

/// 앱에서 제공하는 소셜 제공자 목록이다. 로그인 UI와 함께 제공자 설정을
/// 점검할 수 있도록 목록을 의도적으로 작게 유지하며, 클라이언트 ID나
/// 제공자 비밀 값은 이 열거형에 넣지 않는다.
enum SocialAuthProvider { google, apple, kakao }

/// 짧은 제공자 이름을 사용하는 호출자를 위한 호환 별칭이다.
typedef SocialProvider = SocialAuthProvider;
typedef OAuthSignInProvider = SocialAuthProvider;

extension SocialAuthProviderDetails on SocialAuthProvider {
  OAuthProvider get oauthProvider => switch (this) {
    SocialAuthProvider.google => OAuthProvider.google,
    SocialAuthProvider.apple => OAuthProvider.apple,
    SocialAuthProvider.kakao => OAuthProvider.kakao,
  };

  String get displayName => switch (this) {
    SocialAuthProvider.google => 'Google',
    SocialAuthProvider.apple => 'Apple ID',
    SocialAuthProvider.kakao => 'Kakao',
  };
}

const String socialAuthDemoMessage =
    '데모 모드에서는 소셜 로그인을 사용할 수 없어요. Supabase 연결 후 이용해 주세요.';
const String socialAuthBusyMessage = '이미 다른 로그인을 처리하고 있어요. 잠시만 기다려 주세요.';
const String socialAuthLaunchFailedMessage = '로그인 창을 열지 못했어요. 잠시 후 다시 시도해 주세요.';
const String socialAuthCancelledMessage = '소셜 로그인을 취소했어요.';

/// OAuth가 브라우저에서 콜백을 돌려주지 않을 때 사용하는 중립적인
/// 만료 문구다. 제공자/서버 응답을 화면에 노출하지 않는다.
const String socialAuthTimeoutMessage = '소셜 로그인 시간이 만료되었어요. 다시 시도해 주세요.';
// 이름을 다르게 부르는 호출자와의 호환 별칭이다.
const String socialAuthTimedOutMessage = socialAuthTimeoutMessage;
const String socialAuthProviderDisabledMessage =
    '이 로그인 제공자는 아직 사용할 수 없어요. 관리자에게 문의해 주세요.';
const String socialAuthUnknownErrorMessage =
    '소셜 로그인에 연결하지 못했어요. 잠시 후 다시 시도해 주세요.';

/// 원격 인증 오류를 화면에 전달할 때 사용하는 작업별 안전한 문구다.
///
/// Supabase/Auth 공급자 응답에는 서버 내부 상태, 계정 존재 여부 또는 공급자 설정
/// 정보가 포함될 수 있다. 저장소 경계를 넘는 오류는 이 목록의
/// 문구로만 변환해 UI가 원시 예외를 표시하지 않도록 한다.
const String authSignInErrorMessage = '로그인 정보를 확인해 주세요.';
const String authSignUpErrorMessage = '가입을 완료하지 못했어요. 입력 내용을 확인하고 다시 시도해 주세요.';
const String authResendSignupErrorMessage =
    '인증 메일을 다시 보내지 못했어요. 잠시 후 다시 시도해 주세요.';
const String authRecoveredPasswordErrorMessage =
    '비밀번호를 변경하지 못했어요. 재설정 링크를 다시 요청해 주세요.';
const String authSessionErrorMessage = '인증 상태를 확인하지 못했어요. 잠시 후 다시 시도해 주세요.';

/// Supabase 소셜 제공자가 사용하는 표시용 메타데이터를 해석한다.
///
/// 이 값은 사용자가 제어하므로 권한 부여에 절대 사용하지 않는다.
String? displayNameFromAuthMetadata(
  Map<String, dynamic>? metadata, {
  String? fallback,
}) {
  for (final key in <String>[
    'display_name',
    'full_name',
    'name',
    'preferred_username',
    'nickname',
  ]) {
    final value = metadata?[key];
    if (value is String && value.trim().isNotEmpty) {
      final normalized = value.trim();
      return normalized.length <= authDisplayNameMaximumLength
          ? normalized
          : normalized.substring(0, authDisplayNameMaximumLength);
    }
  }
  final normalizedFallback = fallback?.trim();
  return normalizedFallback == null || normalizedFallback.isEmpty
      ? null
      : normalizedFallback;
}

/// 플래너가 반응해야 하는 Supabase 인증 이벤트의 부분집합이다.
///
/// 토큰 갱신과 MFA 도전 이벤트는 의도적으로 Supabase 어댑터 안에 둔다.
/// 이 이벤트들은 플래너의 인증 사용자 변경을 뜻하지 않으며, 외부에
/// 노출하면 컨트롤러가 불필요하게 앱 데이터를 다시 불러오게 된다.
enum AuthEventType { signedIn, signedOut, userUpdated, passwordRecovery }

/// 저장소 용어를 선호하는 호출자를 위한 이전 버전 호환 이름이다.
typedef AuthRepositoryEventType = AuthEventType;

/// 앱 수준에서 사용하는 타입이 지정된 인증 상태 변경이다.
///
/// 권한 부여는 항상 [PlannerUser.id]와 서버의 멤버십 데이터를 사용해야
/// 한다. 선택적인 표시 이름은 화면용 메타데이터일 뿐이며, 일정방 접근
/// 가능 여부를 결정하는 데 사용해서는 안 된다.
class AuthRepositoryEvent {
  const AuthRepositoryEvent({required this.type, this.user});

  final AuthEventType type;
  final PlannerUser? user;

  /// 이 객체를 인증 상태 전환으로 처리할 때 유용한 별칭이다.
  AuthEventType get event => type;

  bool get isSignedIn => type == AuthEventType.signedIn;
  bool get isSignedOut => type == AuthEventType.signedOut;
  bool get isUserUpdated => type == AuthEventType.userUpdated;
  bool get isPasswordRecovery => type == AuthEventType.passwordRecovery;

  @override
  String toString() => 'AuthRepositoryEvent(type: $type, user: $user)';
}

/// 이 이벤트를 인증 상태 변경이라고 부르는 코드용 별칭이다.
typedef AuthStateChange = AuthRepositoryEvent;
typedef AuthEvent = AuthRepositoryEvent;

/// 이메일/비밀번호 가입 결과다.
///
/// 이메일 확인을 켜면 Supabase는 세션 없이 사용자를 반환한다. 이는 인증
/// 실패가 아니라 후속 조치를 할 수 있는 성공 결과이므로, 호출자는 확인
/// 화면과 재전송 작업을 제공할 수 있다.
abstract class AuthSignUpResult {
  const AuthSignUpResult({required this.email, this.user});

  final String email;

  /// Supabase가 반환한 사용자다. 대기 중인 결과는 인증 세션을 의미하지
  /// 않으므로 데이터 접근 권한 부여에 사용해서는 안 된다.
  final PlannerUser? user;

  bool get requiresEmailConfirmation;
  bool get isPendingEmailConfirmation => requiresEmailConfirmation;
  bool get isPending => requiresEmailConfirmation;
  bool get isAuthenticated => !requiresEmailConfirmation && user != null;
}

/// 인증 세션이 생성된 가입 완료 결과다.
class AuthenticatedSignUp extends AuthSignUpResult {
  AuthenticatedSignUp({required PlannerUser user})
    : super(email: user.email, user: user);

  @override
  bool get requiresEmailConfirmation => false;

  PlannerUser get authenticatedUser => user!;
}

/// 확인 이메일은 보냈지만 아직 세션을 만들지 않은 가입 결과다.
class PendingEmailConfirmation extends AuthSignUpResult {
  const PendingEmailConfirmation({required super.email, super.user});

  @override
  bool get requiresEmailConfirmation => true;
}

/// `Result` 접미사를 선호하는 사용자를 위한 더 명확한 별칭이다.
typedef AuthenticatedSignUpResult = AuthenticatedSignUp;
typedef PendingEmailConfirmationResult = PendingEmailConfirmation;
typedef SignUpResult = AuthSignUpResult;
typedef SignupResult = AuthSignUpResult;

/// Supabase Auth를 감싼 작은 어댑터다. 설정되지 않은 빌드에서는 전체 UI를
/// 실행할 수 있도록 로컬 데모 신원으로 동작한다.
class AuthRepository {
  // 비공개 필드는 이 어댑터 밖에서 Supabase 클라이언트를 읽기 전용으로
  // 유지한다. 초기화 형식 매개변수를 사용하면 비공개 이름 인수가 노출된다.
  AuthRepository({
    SupabaseClient? client,
    Duration oauthTimeout = const Duration(minutes: 2),
  }) : _client = client,
       _oauthTimeout = oauthTimeout {
    final remote = _client;
    if (remote != null) {
      // supabase_flutter 2.17은 AuthState 값 스트림을 제공한다. 최근 gotrue
      // 버전에서는 `onError` 콜백이 필요하며, 스트림 오류가 처리되지 않은
      // 비동기 예외가 되는 것을 막는다.
      _authSubscription = remote.auth.onAuthStateChange.listen(
        _handleSupabaseAuthState,
        onError: _handleSupabaseAuthError,
      );
    }
  }

  final SupabaseClient? _client;
  final Duration _oauthTimeout;
  final StreamController<AuthRepositoryEvent> _events =
      StreamController<AuthRepositoryEvent>.broadcast();
  StreamSubscription<AuthState>? _authSubscription;
  PlannerUser? _localUser;
  String? _pendingLocalConfirmationEmail;
  bool _oauthInFlight = false;
  SocialAuthProvider? _oauthProviderInFlight;
  Timer? _oauthTimer;
  int _oauthGeneration = 0;
  int _authOperationGeneration = 0;
  bool _disposed = false;

  bool get isRemote => _client != null;

  /// OAuth 인증 URL을 실행하는 동안에만 참이다. 실행 성공 결과는 제공자
  /// 콜백이 오기 전에 반환되며, 콜백은 [onAuthStateChange]에서 별도로
  /// 관찰한다.
  bool get isOAuthInFlight => _oauthInFlight;

  SocialAuthProvider? get oauthProviderInFlight => _oauthProviderInFlight;

  /// [PlannerController]가 소비하는 앱 수준 인증 이벤트다.
  ///
  /// `onAuthStateChange`는 Supabase 스트림과 익숙한 같은 이름으로 노출하되,
  /// 이벤트 타입은 앱이 소유하여 컨트롤러가 Supabase 내부 구현에 의존하지
  /// 않도록 한다.
  Stream<AuthRepositoryEvent> get onAuthStateChange => _events.stream;

  /// 스트림을 나타내는 명사를 선호하는 호출자를 위한 별칭이다.
  Stream<AuthRepositoryEvent> get authStateChanges => _events.stream;

  /// 이 스트림을 `authEvents`라고 부르는 컨트롤러 연동용 별칭이다.
  Stream<AuthRepositoryEvent> get authEvents => _events.stream;

  /// 단순한 저장소 가짜와 테스트를 위해 유지하는 별칭이다.
  Stream<AuthRepositoryEvent> get events => _events.stream;

  PlannerUser? get currentUser {
    final user = _client?.auth.currentUser;
    if (user != null) return _plannerUser(user);
    return _localUser;
  }

  Future<PlannerUser> signIn(String email, String password) async {
    final generation = ++_authOperationGeneration;
    final normalizedEmail = email.trim();
    if (_client != null) {
      try {
        final response = await _client.auth.signInWithPassword(
          email: normalizedEmail,
          password: password,
        );
        final user = response.user;
        if (user == null) {
          throw const AuthException(authSignInErrorMessage);
        }
        return _plannerUser(user, fallbackEmail: normalizedEmail);
      } catch (_) {
        // 이메일의 존재 여부나 상태 코드, 엔드포인트 이름, 응답 본문 같은
        // 공급자/서버 세부 정보를 노출하지 않는다.
        throw const AuthException(authSignInErrorMessage);
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (normalizedEmail.isEmpty ||
        password.length < authPasswordMinimumLength) {
      throw const AuthException('이메일과 6자 이상 비밀번호를 확인해 주세요.');
    }
    final authenticated = PlannerUser(
      id: demoUserId,
      email: normalizedEmail,
      displayName: demoUserName,
    );
    if (!_isCurrentAuthGeneration(generation)) return authenticated;
    _localUser = authenticated;
    _pendingLocalConfirmationEmail = null;
    _emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn),
      user: _localUser,
    );
    return authenticated;
  }

  /// 지원하는 제공자에 대해 Supabase OAuth 흐름을 시작한다.
  ///
  /// [GoTrueClient.signInWithOAuth]는 브라우저 실행 요청이 수락되었는지만
  /// 반환하며 인증 완료 여부는 반환하지 않는다. 최종 로그인 사용자는
  /// 컨트롤러가 관리하는 [onAuthStateChange]를 통해 전달된다. 따라서 이
  /// 메서드는 로컬 사용자를 만들어 내거나 데모 모드에서 성공을 보고하지 않는다.
  Future<bool> signInWithOAuth(
    SocialAuthProvider provider, {
    String? redirectTo,
  }) async {
    final remote = _client;
    if (remote == null) {
      throw const AuthException(socialAuthDemoMessage);
    }
    if (_oauthInFlight) {
      throw const AuthException(socialAuthBusyMessage);
    }
    final generation = ++_oauthGeneration;
    _oauthInFlight = true;
    _oauthProviderInFlight = provider;
    _oauthTimer?.cancel();
    _oauthTimer = Timer(_oauthTimeout, () {
      if (!_isCurrentOAuthGeneration(generation)) return;
      _finishOAuthFlow(generation);
    });
    try {
      final launched = await remote.auth
          .signInWithOAuth(
            provider.oauthProvider,
            redirectTo: redirectTo ?? resolveAuthCallbackRedirect(),
            authScreenLaunchMode: kIsWeb
                ? LaunchMode.platformDefault
                : LaunchMode.externalApplication,
          )
          .timeout(
            _oauthTimeout,
            onTimeout: () => Future<bool>.error(
              const AuthException(socialAuthTimeoutMessage),
            ),
          );
      if (!launched) {
        throw const AuthException(socialAuthLaunchFailedMessage);
      }
      if (!_isCurrentOAuthGeneration(generation)) return false;
      return launched;
    } catch (error) {
      final friendly = _friendlySocialAuthError(error);
      if (_isCurrentOAuthGeneration(generation)) {
        _finishOAuthFlow(generation);
      }
      throw friendly;
    }
  }

  /// 작업을 제공자 이름으로 부르는 연동을 위해 유지하는 별칭이다.
  Future<bool> signInWithProvider(
    SocialAuthProvider provider, {
    String? redirectTo,
  }) => signInWithOAuth(provider, redirectTo: redirectTo);

  /// 일부 플랫폼별 로그인 화면에서 사용하는 별칭이다.
  Future<bool> oauthSignIn(SocialAuthProvider provider, {String? redirectTo}) =>
      signInWithOAuth(provider, redirectTo: redirectTo);

  /// 계정을 만들고 이메일 확인이 대기 중인지 보고한다.
  ///
  /// PKCE와 이메일 링크가 모두 앱에 등록된 딥링크 경로로 돌아오도록
  /// 리디렉션을 Supabase에 명시적으로 전달한다.
  Future<AuthSignUpResult> signUp(
    String email,
    String password,
    String name,
  ) async {
    final generation = ++_authOperationGeneration;
    final normalizedEmail = email.trim();
    final normalizedName = name.trim();
    if (_client != null) {
      try {
        final response = await _client.auth.signUp(
          email: normalizedEmail,
          password: password,
          emailRedirectTo: resolveAuthCallbackRedirect(),
          data: <String, dynamic>{'display_name': normalizedName},
        );
        final user = response.user;
        if (user == null) {
          throw const AuthException(authSignUpErrorMessage);
        }
        final plannerUser = _plannerUser(
          user,
          fallbackEmail: normalizedEmail,
          fallbackDisplayName: normalizedName,
        );
        if (response.session == null) {
          return PendingEmailConfirmation(
            email: normalizedEmail,
            user: plannerUser,
          );
        }
        return AuthenticatedSignUp(user: plannerUser);
      } catch (_) {
        // 중복 계정, 약한 비밀번호, 인프라 실패를 호출자가 구분할 수 없게 하고
        // 원시 공급자 세부 정보를 포함하지 않는다.
        throw const AuthException(authSignUpErrorMessage);
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (normalizedEmail.isEmpty ||
        password.length < authPasswordMinimumLength ||
        normalizedName.isEmpty ||
        normalizedName.length > authDisplayNameMaximumLength) {
      throw const AuthException('이름, 이메일과 6자 이상 비밀번호를 입력해 주세요.');
    }
    final authenticated = PlannerUser(
      id: demoUserId,
      email: normalizedEmail,
      displayName: normalizedName,
    );
    if (!_isCurrentAuthGeneration(generation)) {
      return AuthenticatedSignUp(user: authenticated);
    }
    _localUser = authenticated;
    _pendingLocalConfirmationEmail = null;
    _emit(
      const AuthRepositoryEvent(type: AuthEventType.signedIn),
      user: _localUser,
    );
    return AuthenticatedSignUp(user: authenticated);
  }

  /// 이메일/비밀번호 가입 확인 메시지를 다시 보낸다.
  Future<void> resendSignupConfirmation(String email) async {
    final generation = ++_authOperationGeneration;
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) {
      throw const AuthException('이메일을 입력해 주세요.');
    }
    final remote = _client;
    if (remote != null) {
      try {
        await remote.auth.resend(
          type: OtpType.signup,
          email: normalizedEmail,
          emailRedirectTo: resolveAuthCallbackRedirect(),
        );
      } catch (_) {
        // 이 주소가 계정에 속하는지 호출자에게 알리지 않는다.
        throw const AuthException(authResendSignupErrorMessage);
      }
      return;
    }

    // 데모 모드에는 메일 서버가 없다. 작업을 빠르고 결정적으로 처리하되,
    // 가짜 구현이 재전송 대상 이메일을 확인할 수 있도록 이메일은 보존한다.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!_isCurrentAuthGeneration(generation)) return;
    _pendingLocalConfirmationEmail = normalizedEmail;
  }

  /// 일부 UI 연동에서 사용하는 별칭이다.
  Future<void> resendConfirmationEmail(String email) =>
      resendSignupConfirmation(email);

  /// 비밀번호 복구 메시지를 요청한다.
  Future<void> requestPasswordReset(String email) async {
    final generation = ++_authOperationGeneration;
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) {
      throw const AuthException('이메일을 입력해 주세요.');
    }
    final remote = _client;
    if (remote != null) {
      try {
        await remote.auth.resetPasswordForEmail(
          normalizedEmail,
          redirectTo: resolveAuthCallbackRedirect(),
        );
      } catch (_) {
        // "사용자를 찾을 수 없음"과 같은 제공자 오류를 UI에 전달하지 않는다.
        // 그러면 복구 양식이 계정 존재 여부를 확인하는 도구가 될 수 있다.
        throw const AuthException(passwordResetRequestErrorMessage);
      }
      if (!_isCurrentAuthGeneration(generation)) return;
      return;
    }

    // 데모 모드에는 외부 메일 서비스가 없다. 입력을 검증하고 잠시 기다려
    // 로컬 UI와 테스트에서 이 흐름을 예측 가능하게 유지한다.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!_isCurrentAuthGeneration(generation)) return;
  }

  /// 클라이언트를 노출하지 않으면서 Supabase 작업 이름과 맞춘 별칭이다.
  Future<void> resetPasswordForEmail(String email) =>
      requestPasswordReset(email);

  Future<void> sendPasswordReset(String email) => requestPasswordReset(email);

  /// Supabase가 복구 세션을 만든 뒤 비밀번호를 변경한다.
  Future<PlannerUser> updateRecoveredPassword(String password) async {
    final generation = ++_authOperationGeneration;
    if (password.length < 8) {
      throw const AuthException('8자 이상 입력해 주세요.');
    }
    final remote = _client;
    if (remote != null) {
      try {
        final response = await remote.auth.updateUser(
          UserAttributes(password: password),
        );
        final user = response.user;
        if (user == null) {
          throw const AuthException(authRecoveredPasswordErrorMessage);
        }
        return _plannerUser(user);
      } catch (_) {
        // 복구 링크는 수명이 짧고 공급자 응답에 세션/계정 세부 정보가 있을 수 있다.
        // 사용자가 할 수 있는 동작만 노출한다.
        throw const AuthException(authRecoveredPasswordErrorMessage);
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 50));
    final local = _localUser;
    if (local == null) {
      throw const AuthException('비밀번호를 변경할 계정이 없습니다.');
    }
    if (!_isCurrentAuthGeneration(generation)) return local;
    _emit(
      const AuthRepositoryEvent(type: AuthEventType.userUpdated),
      user: local,
    );
    return local;
  }

  /// 이 작업을 단순히 `updatePassword`라고 부르는 복구 화면용 별칭이다.
  Future<PlannerUser> updatePassword(String password) =>
      updateRecoveredPassword(password);

  Future<PlannerUser> changePassword(String password) =>
      updateRecoveredPassword(password);

  Future<PlannerUser> updateDisplayName(String displayName) async {
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty ||
        normalizedName.length > authDisplayNameMaximumLength) {
      throw const AuthException('이름은 1자 이상 120자 이하로 입력해 주세요.');
    }

    final remote = _client;
    if (remote == null) {
      final local = _localUser;
      if (local == null) {
        throw const AuthException('이름을 변경할 계정이 없습니다.');
      }
      _localUser = PlannerUser(
        id: local.id,
        email: local.email,
        displayName: normalizedName,
      );
      _emit(
        const AuthRepositoryEvent(type: AuthEventType.userUpdated),
        user: _localUser,
      );
      return _localUser!;
    }

    final current = remote.auth.currentUser;
    if (current == null) {
      throw const AuthException('로그인 세션을 다시 확인해 주세요.');
    }
    final previousDisplayName = current.userMetadata?['display_name'];
    try {
      final response = await remote.auth.updateUser(
        UserAttributes(data: <String, dynamic>{'display_name': normalizedName}),
      );
      final updatedUser = response.user;
      if (updatedUser == null) {
        throw const AuthException('이름을 변경하지 못했어요. 다시 시도해 주세요.');
      }

      final updatedProfiles = await remote
          .from('profiles')
          .update(<String, dynamic>{'display_name': normalizedName})
          .eq('id', current.id)
          .select('id');
      if (updatedProfiles.isEmpty) {
        throw const AuthException('프로필 이름을 변경할 권한이 없습니다.');
      }
      return _plannerUser(updatedUser, fallbackDisplayName: normalizedName);
    } catch (_) {
      // Auth가 변경을 수락한 뒤 RLS가 적용된 공개 프로필 갱신이 예기치 않게
      // 실패해도 Auth 메타데이터와 공개 프로필이 일치하도록 유지한다.
      try {
        await remote.auth.updateUser(
          UserAttributes(
            data: <String, dynamic>{'display_name': previousDisplayName},
          ),
        );
      } catch (_) {
        // 롤백 실패보다 처음 발생한 안전한 오류가 더 유용하다.
      }
      throw const AuthException('이름을 변경하지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
  }

  Future<void> signOut() async {
    final generation = ++_authOperationGeneration;
    // 로그아웃은 OAuth 실행에서도 최종 작업이다. 느린 브라우저 실행 때문에 새 로그인이
    // 계속 차단되지 않도록 이를 동기적으로 지운다.
    _finishOAuthFlow();
    final remote = _client;
    if (remote != null) {
      try {
        await remote.auth.signOut();
      } catch (_) {
        // 공급자/서버 응답에는 내부 세부 정보가 있을 수 있다. 명시적인 로그아웃 실패에는
        // 컨트롤러와 같은 고정된 사용자 안전 메시지를 사용한다. Supabase가 SIGNED_OUT
        // 이벤트를 보냈다면 로컬 세션은 앞선 이벤트에 의해 지워진 상태로 유지된다.
        throw const AuthException(authSessionErrorMessage);
      }
    }
    if (!_isCurrentAuthGeneration(generation)) return;
    _localUser = null;
    _pendingLocalConfirmationEmail = null;
    // Supabase는 자체적으로 SIGNED_OUT를 보낸다. 로컬 데모 모드에는 그
    // 작업을 수행할 클라이언트가 없으므로 여기서 대응하는 앱 이벤트를 보낸다.
    if (remote == null) {
      _emit(const AuthRepositoryEvent(type: AuthEventType.signedOut));
    }
  }

  /// 로컬 확인 재전송 가짜 구현에 마지막으로 전달된 이메일이다.
  /// 진단용일 뿐이며 인증에는 절대 사용하지 않는다.
  String? get pendingLocalConfirmationEmail => _pendingLocalConfirmationEmail;

  /// Supabase 구독과 앱 이벤트 스트림을 해제한다.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_authOperationGeneration;
    ++_oauthGeneration;
    _finishOAuthFlow();
    final subscription = _authSubscription;
    _authSubscription = null;
    // Provider/Riverpod 해제를 위해 `dispose`는 의도적으로 동기식이다. 취소 전에
    // 저장소를 해제된 것으로 표시하면 구독의 비동기 취소가 끝나는 동안 이미 대기열에
    // 들어간 콜백이 무해해진다. 오류 콜백에도 같은 가드를 적용한다.
    if (subscription != null) unawaited(_cancelAuthSubscription(subscription));
    unawaited(_events.close());
  }

  Future<void> _cancelAuthSubscription(
    StreamSubscription<AuthState> subscription,
  ) async {
    try {
      await subscription.cancel();
    } catch (_) {
      // 사용자 지정 스트림 구현은 취소 시 동기 또는 비동기로 실패할 수 있다. 해제는
      // 가능한 범위에서 수행한다.
    }
  }

  void _handleSupabaseAuthState(AuthState state) {
    if (_disposed || _events.isClosed) return;
    final mappedType = switch (state.event) {
      AuthChangeEvent.signedIn => AuthEventType.signedIn,
      AuthChangeEvent.signedOut => AuthEventType.signedOut,
      AuthChangeEvent.userUpdated => AuthEventType.userUpdated,
      AuthChangeEvent.passwordRecovery => AuthEventType.passwordRecovery,
      _ => null,
    };
    if (mappedType == null) return;
    if (mappedType == AuthEventType.signedIn ||
        mappedType == AuthEventType.signedOut ||
        mappedType == AuthEventType.passwordRecovery) {
      // 공급자 이벤트를 기준으로 삼으며 이전 로컬 인증 요청보다 우선한다. 컨트롤러도
      // 사용자/플래너 상태를 커밋하기 전에 같은 소유권 검사를 수행한다.
      ++_authOperationGeneration;
      if (mappedType == AuthEventType.signedIn ||
          mappedType == AuthEventType.passwordRecovery) {
        _finishOAuthFlow();
      } else {
        _finishOAuthFlow();
      }
    }
    final supabaseUser = state.session?.user;
    _emit(
      AuthRepositoryEvent(
        type: mappedType,
        user: supabaseUser == null ? null : _plannerUser(supabaseUser),
      ),
    );
  }

  void _handleSupabaseAuthError(Object error, StackTrace stackTrace) {
    if (_disposed || _events.isClosed) return;
    // 앱 소유 스트림으로 공급자/서버 세부 정보를 절대 전달하지 않는다. 컨트롤러가
    // 스트림 오류를 배너에 표시할 수 있으므로 고정되고 작업 중립적인 메시지만
    // 노출한다. 스택은 의도적으로 생략한다.
    _events.addError(
      const AuthException(authSessionErrorMessage),
      StackTrace.empty,
    );
  }

  PlannerUser _plannerUser(
    User user, {
    String? fallbackEmail,
    String? fallbackDisplayName,
  }) {
    final metadata = user.userMetadata;
    // 메타데이터는 사용자가 제어하는 표시용 데이터다. 특히 역할/소유자
    // 플래그를 여기서 읽지 않는다. 서버 멤버십과 RLS만이 권한의 근거다.
    final displayName = displayNameFromAuthMetadata(
      metadata,
      fallback: fallbackDisplayName,
    );
    return PlannerUser(
      id: user.id,
      email: user.email ?? fallbackEmail ?? '',
      displayName: displayName,
    );
  }

  AuthException _friendlySocialAuthError(Object error) {
    if (error is AuthException) {
      final message = error.message.toLowerCase();
      if (_looksCancelled(message)) {
        return const AuthException(socialAuthCancelledMessage);
      }
      if (_looksProviderDisabled(message)) {
        return const AuthException(socialAuthProviderDisabledMessage);
      }
      if (error.message == socialAuthLaunchFailedMessage ||
          error.message == socialAuthBusyMessage ||
          error.message == socialAuthDemoMessage) {
        return error;
      }
      return const AuthException(socialAuthUnknownErrorMessage);
    }
    final message = error.toString().toLowerCase();
    if (_looksCancelled(message)) {
      return const AuthException(socialAuthCancelledMessage);
    }
    if (_looksProviderDisabled(message)) {
      return const AuthException(socialAuthProviderDisabledMessage);
    }
    return const AuthException(socialAuthUnknownErrorMessage);
  }

  bool _looksCancelled(String message) {
    return message.contains('cancel') ||
        message.contains('canceled') ||
        message.contains('취소');
  }

  bool _looksProviderDisabled(String message) {
    return message.contains('unsupported provider') ||
        message.contains('provider is disabled') ||
        message.contains('provider disabled') ||
        message.contains('provider not enabled') ||
        message.contains('not enabled') ||
        message.contains('provider configuration');
  }

  void _emit(AuthRepositoryEvent event, {PlannerUser? user}) {
    if (_disposed || _events.isClosed) return;
    if (user == null) {
      _events.add(event);
    } else {
      _events.add(AuthRepositoryEvent(type: event.type, user: user));
    }
  }

  bool _isCurrentAuthGeneration(int generation) {
    return !_disposed && generation == _authOperationGeneration;
  }

  bool _isCurrentOAuthGeneration(int generation) {
    return !_disposed && generation == _oauthGeneration && _oauthInFlight;
  }

  void _finishOAuthFlow([int? generation]) {
    if (generation != null && generation != _oauthGeneration) return;
    _oauthTimer?.cancel();
    _oauthTimer = null;
    _oauthInFlight = false;
    _oauthProviderInFlight = null;
    if (generation != null) {
      ++_oauthGeneration;
    }
  }
}

/// 릴리스 빌드에 원격 설정이 없을 때만 사용하는 Auth 어댑터다. 로컬 데모
/// 동작을 상속하지 않으므로 제공자 사용 실수로 운영 빌드가 가짜 데이터로
/// 전환되지 않는다.
class ConfigurationBlockedAuthRepository extends AuthRepository {
  ConfigurationBlockedAuthRepository(this.message) : super();

  final String message;

  AuthException get _error => AuthException(message);

  @override
  PlannerUser? get currentUser => null;

  @override
  Future<PlannerUser> signIn(String email, String password) =>
      Future<PlannerUser>.error(_error);

  @override
  Future<bool> signInWithOAuth(
    SocialAuthProvider provider, {
    String? redirectTo,
  }) => Future<bool>.error(_error);

  @override
  Future<AuthSignUpResult> signUp(String email, String password, String name) =>
      Future<AuthSignUpResult>.error(_error);

  @override
  Future<void> resendSignupConfirmation(String email) =>
      Future<void>.error(_error);

  @override
  Future<void> requestPasswordReset(String email) => Future<void>.error(_error);

  @override
  Future<PlannerUser> updateRecoveredPassword(String password) =>
      Future<PlannerUser>.error(_error);

  @override
  Future<PlannerUser> updateDisplayName(String displayName) =>
      Future<PlannerUser>.error(_error);
}
