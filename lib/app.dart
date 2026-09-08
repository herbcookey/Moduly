import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config/app_config.dart';
import 'core/invite_link.dart';
import 'repositories/auth_repository.dart';
import 'screens/auth_screens.dart';
import 'screens/event_editor_screen.dart';
import 'screens/event_search_screen.dart';
import 'screens/group_picker_screen.dart';
import 'screens/home_screen.dart';
import 'screens/invite_preview_screen.dart';
import 'screens/legal_screens.dart';
import 'screens/members_screen.dart';
import 'screens/settings_screen.dart';
import 'platform/browser_location_source.dart';
import 'platform/notification_bindings.dart';
import 'state/app_state.dart';

class ModulyApp extends ConsumerWidget {
  const ModulyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(plannerControllerProvider);
    final router = ref.watch(routerProvider);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff477b76),
      brightness: Brightness.light,
    );
    final darkColorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff8ed5c7),
      brightness: Brightness.dark,
    );
    return MaterialApp.router(
      title: 'Moduly',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        fontFamily: 'Pretendard',
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      ),
      darkTheme: ThemeData(
        colorScheme: darkColorScheme,
        useMaterial3: true,
        fontFamily: 'Pretendard',
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      ),
      themeMode: controller.darkMode ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return NotificationLifecycleBinding(
          router: router,
          child: MediaQuery(
            data: media.copyWith(
              textScaler: _AppTextScaler(
                media.textScaler,
                controller.textScale,
              ),
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      routerConfig: router,
    );
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  // GoRouter가 변경 감지를 관리하므로 여기서는 읽기만 하여
  // 일정 이벤트가 올 때마다 라우터 전체가 다시 빌드되지 않게 한다.
  final controller = ref.read(plannerControllerProvider);
  final config = ref.read(appConfigProvider);
  final browserLocationSource = ref.read(browserLocationSourceProvider);
  // 비밀번호 복구 화면은 비밀번호 업데이트가 완료되면 성공 상태를
  // 잠시 보여줘야 한다. 컨트롤러가 세션을 로그인 상태로 바꾸는 알림과
  // 화면이 성공 상태를 그리는 사이에 라우터가 /groups로 이동하지 않도록
  // 현재 복구 화면의 한 번성 허용 플래그를 둔다.
  var allowPasswordResetSuccess = false;
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: controller,
    // GoRouter의 기본 오류 페이지에는 일치하지 않은 위치가 포함된다. 따라서 잘못된
    // 초대 경로가 Bearer 토큰을 위젯 트리에 다시 노출할 수 있다. 모든 라우팅 실패는
    // 토큰을 포함하지 않으며 사용자가 조치할 수 있게 유지한다.
    errorBuilder: (context, state) => const _SafeRouteErrorScreen(),
    redirect: (context, state) {
      final location = state.uri.path;
      // 브라우저 경로 전략은 GoRouter에 전달하기 전에 앱의 배포 접두사를 제거한다.
      // 아래 소스는 주소 표시줄의 전체 URI를 보존해 엄격한 파서가 설정된 출처와
      // *전체* 기본 경로를 확인할 수 있게 한다. 파싱이 실패해도 초대 형태의 후보는
      // 모두 이 분기에서 제거하므로 불투명한 값이 GoRouter 오류 페이지나 위젯 트리에
      // 도달할 수 없다.
      final inviteCandidate = _inviteRouteCandidate(
        route: state.uri,
        browserLocation: browserLocationSource.currentLocation,
        config: config,
      );
      if (inviteCandidate.isCandidate) {
        final captured =
            inviteCandidate.uri != null &&
            controller.captureInviteUri(
              inviteCandidate.uri!,
              config: config,
              currentOrigin: inviteCandidate.currentOrigin,
              isRelease: kReleaseMode,
            );
        if (captured) {
          return controller.isAuthenticated ? '/invite' : '/login';
        }
        // 잘못되었거나 설정되지 않은 초대 경로, 출처가 다르거나 인코딩된 경로,
        // 쿼리가 있거나 기본 경로가 반복되거나 끝에 슬래시가 있는 경로는 모두 토큰이
        // 없는 경로로 빠져나간다. 대기 중인 토큰이 없으므로 로그인 상태의 목적지는
        // 의도적으로 미리보기가 아닌 그룹 화면이다.
        return controller.isAuthenticated ? '/groups' : '/login';
      }
      final isAuthCallback =
          location == '/auth-callback' || state.uri.host == 'auth-callback';
      // 네이티브 Supabase 어댑터가 콜백 URI를 처리한 뒤 인증 이벤트를
      // 비동기로 보낸다. 이벤트가 흐름을 식별할 때까지 이 경로를 공개
      // 중계 경로로 유지한다. 여기서 비밀번호 재설정으로 추측하면
      // 이메일 확인 링크가 잘못된 화면으로 이동할 수 있다.
      if (isAuthCallback) {
        if (controller.isInPasswordRecovery) return '/reset-password';
        if (controller.isAuthenticated) return '/groups';
        if (location == '/auth-callback') return null;
        final query = state.uri.hasQuery ? '?${state.uri.query}' : '';
        return '/auth-callback$query';
      }
      final isInviteRoute = location == '/invite';
      final publicAuthRoute =
          location == '/login' ||
          location == '/signup' ||
          location == '/verify-email' ||
          location == '/forgot-password' ||
          location == '/reset-password' ||
          location == '/privacy-policy' ||
          location == '/terms-of-service' ||
          location == '/auth-callback' ||
          isInviteRoute;
      // 로그아웃 사용자가 인증하는 동안 대기 초대를 컨트롤러에 유지한다. 로그인/
      // 가입 제출자는 일반적으로 /groups로 이동하지만, 세션이 설정되면 대기 초대가
      // 그 중간 목적지보다 우선한다. 웜 링크도 이미 로그인한 사용자를 토큰이 없는
      // 미리보기 경로로 이동시킨다.
      if (!controller.isAuthenticated && isInviteRoute) return '/login';
      if (!controller.isAuthenticated && !publicAuthRoute) return '/login';
      if (location != '/reset-password' && !controller.isInPasswordRecovery) {
        allowPasswordResetSuccess = false;
      }
      // Supabase가 복구 인증 세션을 이미 노출했더라도 복구 링크는
      // 의도적으로 /reset-password에 남겨 둔다.
      if (controller.isInPasswordRecovery && location != '/reset-password') {
        return '/reset-password';
      }
      if (controller.isAuthenticated &&
          controller.hasPendingInvite &&
          location != '/invite') {
        return '/invite';
      }
      // 확인 링크는 일반 로그인 이벤트를 만들지만, 복구 링크는
      // 비밀번호를 바꿀 때까지 재설정 화면에 남겨 둔다.
      if (controller.isAuthenticated &&
          location == '/reset-password' &&
          !controller.isInPasswordRecovery &&
          !allowPasswordResetSuccess) {
        return '/groups';
      }
      final loginRoute = location == '/login' || location == '/signup';
      if (controller.isAuthenticated &&
          (loginRoute || location == '/verify-email')) {
        return '/groups';
      }
      final requiresGroup =
          location.startsWith('/home') ||
          location.startsWith('/members') ||
          location.startsWith('/search') ||
          location.startsWith('/event');
      if (controller.isAuthenticated &&
          controller.selectedGroup == null &&
          requiresGroup) {
        return '/groups';
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(path: '/', redirect: (context, state) => '/login'),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/signup',
        builder: (context, state) => const SignUpScreen(),
      ),
      GoRoute(
        path: '/verify-email',
        builder: (context, state) => Consumer(
          builder: (context, ref, child) {
            final controller = ref.read(plannerControllerProvider);
            return VerifyEmailScreen(
              initialEmail:
                  _emailFromRouteState(state) ??
                  controller.pendingConfirmationEmail,
              onResend: (email) => controller.resendConfirmationEmail(email),
            );
          },
        ),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => Consumer(
          builder: (context, ref, child) {
            final controller = ref.read(plannerControllerProvider);
            return ForgotPasswordScreen(
              onRequest: controller.requestPasswordReset,
            );
          },
        ),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) => Consumer(
          builder: (context, ref, child) {
            final controller = ref.read(plannerControllerProvider);
            return ResetPasswordScreen(
              onUpdate: (password) async {
                allowPasswordResetSuccess = true;
                try {
                  await controller.updateRecoveredPassword(password);
                } catch (_) {
                  allowPasswordResetSuccess = false;
                  rethrow;
                }
              },
              onCompleted: () async {
                allowPasswordResetSuccess = false;
                try {
                  await controller.signOut();
                } catch (_) {
                  // 복구 세션이 이미 만료되었을 수 있지만 성공 화면에서는 그래도
                  // 로그인으로 돌아가야 한다.
                }
              },
            );
          },
        ),
      ),
      GoRoute(
        path: '/auth-callback',
        builder: (context, state) => Consumer(
          builder: (context, ref, child) {
            final controller = ref.watch(plannerControllerProvider);
            return AuthCallbackScreen(
              error: _oauthCallbackError(state) ?? controller.errorMessage,
            );
          },
        ),
      ),
      GoRoute(
        path: '/privacy-policy',
        builder: (context, state) => const PrivacyPolicyScreen(),
      ),
      GoRoute(
        path: '/terms-of-service',
        builder: (context, state) => const TermsOfServiceScreen(),
      ),
      GoRoute(
        path: '/invite',
        builder: (context, state) => const InvitePreviewScreen(),
      ),
      GoRoute(
        path: '/groups',
        builder: (context, state) => const GroupPickerScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/search',
            builder: (context, state) => const EventSearchScreen(),
          ),
          GoRoute(
            path: '/members',
            builder: (context, state) => const MembersScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/settings/notifications',
            builder: (context, state) => const NotificationSettingsRoute(),
          ),
        ],
      ),
      GoRoute(
        path: '/event/new',
        builder: (context, state) => const EventEditorScreen(),
      ),
      GoRoute(
        path: '/event/:id',
        builder: (context, state) => EventEditorScreen(
          eventId: state.pathParameters['id'],
          occurrenceKey:
              state.uri.queryParameters['occurrence'] ??
              state.uri.queryParameters['occurrence_key'],
        ),
      ),
    ],
  );
}, dependencies: <ProviderOrFamily>[plannerControllerProvider]);

@immutable
class _InviteRouteCandidate {
  const _InviteRouteCandidate({
    required this.isCandidate,
    this.uri,
    this.currentOrigin,
  });

  const _InviteRouteCandidate.none() : this(isCandidate: false);

  final bool isCandidate;
  final Uri? uri;
  final Uri? currentOrigin;
}

/// 엄격한 초대 파서에 전달할 정확한 URI를 선택한다.
///
/// 웹에서는 [browserLocation]을 기준으로 삼는다. PathUrlStrategy 배포가
/// `<base href="/app/">`를 사용하면 이 값에는 `/app`이 포함되지만 [route]에는
/// `/invite/<token>`만 있다. 네이티브와 테스트 라우터는 여전히 절대 경로를 직접
/// 제공할 수 있다. 경로 전용 [route]는 루트로 설정된 기본 경로에만 합성할 수 있다.
/// 브라우저 접점 없이 중첩 기본 경로를 합성하면 잘못된 배포 루트까지 암묵적으로 허용한다.
_InviteRouteCandidate _inviteRouteCandidate({
  required Uri route,
  required Uri? browserLocation,
  required AppConfig config,
}) {
  final routeHasCandidate = _hasInviteCandidate(route);
  if (!routeHasCandidate) return const _InviteRouteCandidate.none();

  if (browserLocation != null && _hasInviteCandidate(browserLocation)) {
    return _InviteRouteCandidate(
      isCandidate: true,
      uri: browserLocation,
      currentOrigin: _originOf(browserLocation),
    );
  }

  final routeUri = _inviteUriForRoute(route, config);
  return _InviteRouteCandidate(
    isCandidate: true,
    uri: routeUri,
    currentOrigin:
        routeUri != null &&
            (routeUri.scheme.isNotEmpty || routeUri.host.isNotEmpty)
        ? _originOf(routeUri)
        : null,
  );
}

/// [uri]에 초대 표시와 그 뒤의 원시 후보가 있으면 `true`를 반환한다. 잘못되었거나
/// 인코딩된 값과 끝의 슬래시도 포함한다. 토큰이 없는 순수 `/invite` 경로는
/// 미리보기 화면에서 계속 사용할 수 있다.
bool _hasInviteCandidate(Uri uri) {
  if (uri.scheme.toLowerCase() == 'moduly' &&
      uri.host.toLowerCase() == 'invite') {
    return uri.pathSegments.isNotEmpty || uri.path.endsWith('/');
  }

  final decodedSegments = uri.pathSegments;
  for (var index = 0; index < decodedSegments.length; index++) {
    if (decodedSegments[index].toLowerCase() != 'invite') continue;
    if (index + 1 < decodedSegments.length ||
        uri.path.endsWith('/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return true;
    }
  }

  // `Uri.pathSegments`는 보통 퍼센트 이스케이프를 디코딩하지만 Dart가 리터럴 표시로
  // 디코딩할 수 없는 잘못되었거나 부분적으로 인코딩된 형식을 위해 원시 경로 탐색을
  // 유지한다. 다른 초대 형태의 값처럼 제거해야 하며 대체 경로로 넘겨서는 안 된다.
  final rawSegments = uri.path.split('/');
  for (var index = 0; index < rawSegments.length; index++) {
    final raw = rawSegments[index].toLowerCase();
    String decoded;
    try {
      decoded = Uri.decodeComponent(raw).toLowerCase();
    } catch (_) {
      decoded = raw;
    }
    if (decoded == 'invite') {
      if (index + 1 < rawSegments.length || uri.hasQuery || uri.hasFragment) {
        return true;
      }
    } else if (decoded.startsWith('invite') &&
        decoded.length > 'invite'.length) {
      return true;
    }
  }
  return false;
}

/// 경로 전용 GoRouter 위치를 엄격한 초대 파서가 기대하는 절대 URI로 변환한다.
/// 브라우저 라우팅은 중첩 배포를 위한 절대 접점을 제공한다. 이 대체 방식은
/// 의도적으로 루트로 설정된 기본 경로와 설정된 접두사가 이미 있는 경로로 제한한다.
/// 네이티브 사용자 정의 스킴 URI가 직접 제공되면 그대로 둔다.
Uri? _inviteUriForRoute(Uri route, AppConfig config) {
  if (route.scheme.isNotEmpty || route.host.isNotEmpty) return route;
  // 경로 조각에서 Uri를 다시 만들 때 퍼센트 이스케이프가 디코딩될 수 있다.
  // 파서의 실패 시 차단 인코딩 형식 정책을 유지한다.
  if (route.toString().contains('%')) return null;
  final base = validateInviteBaseUrl(
    config.inviteBaseUrl,
    isRelease: kReleaseMode,
  ).uri;
  if (base == null) return null;

  final baseSegments = base.pathSegments;
  final routeSegments = route.pathSegments;
  if (baseSegments.isNotEmpty &&
      _matchingInviteBaseOffset(routeSegments, baseSegments) == null) {
    return null;
  }
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: route.path,
    query: route.hasQuery ? route.query : null,
    fragment: route.hasFragment ? route.fragment : null,
  );
}

int? _matchingInviteBaseOffset(
  List<String> routeSegments,
  List<String> baseSegments,
) {
  if (routeSegments.length < baseSegments.length) return null;
  for (var index = 0; index < baseSegments.length; index++) {
    if (routeSegments[index] != baseSegments[index]) return null;
  }
  return baseSegments.length;
}

Uri? _originOf(Uri uri) {
  if (uri.scheme.isEmpty || uri.host.isEmpty) return null;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

String? _emailFromRouteState(GoRouterState state) {
  final queryEmail = state.uri.queryParameters['email'];
  if (queryEmail != null && queryEmail.trim().isNotEmpty) {
    return queryEmail.trim();
  }
  final extra = state.extra;
  if (extra is String && extra.trim().isNotEmpty) return extra.trim();
  if (extra is Map<String, dynamic>) {
    final email = extra['email'];
    if (email is String && email.trim().isNotEmpty) return email.trim();
  }
  return null;
}

/// 제공자 콜백 오류를 일관된 한국어 문구로 변환한다.
///
/// OAuth 제공자는 콜백 쿼리에 불투명한 설명(때로는 계정 정보)을 포함할 수
/// 있다. 콜백은 사용자에게 보이고 신뢰할 수 없는 브라우저에서도 접근할 수
/// 있으므로 해당 값을 직접 화면에 표시하지 않는다.
String? _oauthCallbackError(GoRouterState state) {
  final error = state.uri.queryParameters['error']?.trim().toLowerCase();
  final description =
      state.uri.queryParameters['error_description']?.trim().toLowerCase() ??
      '';
  if ((error == null || error.isEmpty) && description.isEmpty) return null;
  if (error == 'access_denied' ||
      (error?.contains('cancel') ?? false) ||
      description.contains('cancel') ||
      description.contains('canceled') ||
      description.contains('취소')) {
    return socialAuthCancelledMessage;
  }
  return socialAuthUnknownErrorMessage;
}

class AppShell extends StatelessWidget {
  const AppShell({required this.child, super.key});
  final Widget child;

  int _indexForLocation(String location) {
    if (location.startsWith('/members')) return 1;
    if (location.startsWith('/settings')) return 2;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    return Scaffold(
      body: SafeArea(child: child),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _indexForLocation(location),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '캘린더',
          ),
          NavigationDestination(
            icon: Icon(Icons.group_outlined),
            selectedIcon: Icon(Icons.group),
            label: '멤버',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: '설정',
          ),
        ],
        onDestinationSelected: (index) {
          switch (index) {
            case 1:
              context.go('/members');
            case 2:
              context.go('/settings');
            default:
              context.go('/home');
          }
        },
      ),
    );
  }
}

class _SafeRouteErrorScreen extends StatelessWidget {
  const _SafeRouteErrorScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('페이지를 찾을 수 없어요')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.link_off_outlined, size: 48),
              const SizedBox(height: 16),
              const Text(
                '요청한 페이지를 열 수 없어요. 링크를 다시 확인해 주세요.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => context.go('/login'),
                child: const Text('로그인 화면으로 이동'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String initials(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return '?';
  }
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length > 1) {
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
  return trimmed.substring(0, 1);
}

Color colorFromValue(int value) => Color(value);

/// 플랫폼 텍스트 크기 조절기에 앱 내 글자 크기 설정을 더해 적용한다. 사용자 설정이 100%
/// 미만이어도 OS 큰 글자 설정을 줄여서는 안 된다. 플랫폼 기본 크기에서는 설정
/// 슬라이더의 의도대로 앱을 조금 작게 만들 수 있다.
final class _AppTextScaler extends TextScaler {
  const _AppTextScaler(this.platformScaler, this.appScale);

  final TextScaler platformScaler;
  final double appScale;

  bool get _platformUsesLargeText => platformScaler.scale(1) > 1;

  @override
  double scale(double fontSize) {
    if (appScale < 1 && _platformUsesLargeText) {
      return platformScaler.scale(fontSize);
    }
    return platformScaler.scale(fontSize) * appScale;
  }

  @override
  @Deprecated('비선형 텍스트 크기 조정을 준비하면서 textScaleFactor가 지원 중단되었습니다.')
  double get textScaleFactor {
    final platformScale = platformScaler.scale(1);
    if (appScale < 1 && platformScale > 1) return platformScale;
    return platformScale * appScale;
  }

  @override
  bool operator ==(Object other) =>
      other is _AppTextScaler &&
      other.platformScaler == platformScaler &&
      other.appScale == appScale;

  @override
  int get hashCode => Object.hash(platformScaler, appScale);
}

/// [background] 위에서도 읽기 쉬운 전경색을 선택한다. 사용자가 고른 색상 위에
/// 표시하는 이니셜과 기타 작은 레이블에 사용한다.
Color contrastingForeground(Color background) {
  final luminance = background.computeLuminance();
  final whiteContrast = 1.05 / (luminance + 0.05);
  final blackContrast = (luminance + 0.05) / 0.05;
  if (whiteContrast >= 4.5) return Colors.white;
  if (blackContrast >= 4.5) return const Color(0xff1b1b1b);
  return blackContrast > whiteContrast ? const Color(0xff1b1b1b) : Colors.white;
}

/// [foreground]가 [background] 위에서 읽기 쉬우면 그대로 반환하고, 그렇지 않으면
/// 접근성 있는 중립색을 사용한다. 원래 색은 다른 곳에서 시각적 범주 표시
/// (예: 일정 색상 막대)로 유지할 수 있다.
Color readableForegroundOn(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  final contrast = (lighter + 0.05) / (darker + 0.05);
  return contrast >= 4.5 ? foreground : contrastingForeground(background);
}

String formatTime(DateTime value, {bool allDay = false}) {
  if (allDay) return '종일';
  final local = value.toLocal();
  final hour = local.hour == 0
      ? 12
      : (local.hour > 12 ? local.hour - 12 : local.hour);
  final period = local.hour < 12 ? '오전' : '오후';
  return '$period $hour:${local.minute.toString().padLeft(2, '0')}';
}

String formatMonthDay(DateTime value) => '${value.month}월 ${value.day}일';
