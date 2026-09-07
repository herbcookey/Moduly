import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config/app_config.dart';
import 'core/invite_link.dart';
import 'repositories/auth_repository.dart';
import 'screens/auth_screens.dart';
import 'screens/event_editor_screen.dart';
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
  // 잠시 보여줘야 한다. 컨트롤러가 세션을 signed-in으로 바꾸는 알림과
  // 화면이 성공 상태를 그리는 사이에 라우터가 /groups로 이동하지 않도록
  // 현재 복구 화면의 한 번성 허용 플래그를 둔다.
  var allowPasswordResetSuccess = false;
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: controller,
    // GoRouter's default error page includes the unmatched location.  A
    // malformed invite path could therefore echo a bearer token back into the
    // widget tree. Keep all routing failures token-free and actionable.
    errorBuilder: (context, state) => const _SafeRouteErrorScreen(),
    redirect: (context, state) {
      final location = state.uri.path;
      // A browser path strategy strips an application's deployment prefix
      // before GoRouter sees it.  The source below preserves the complete
      // address-bar URI so the strict parser can check the configured origin
      // and *full* base path.  Every invite-shaped candidate is scrubbed in
      // this same branch, even when parsing fails, so an opaque value cannot
      // reach GoRouter's error page or widget tree.
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
        // Invalid, unconfigured, wrong-origin, encoded, query-bearing,
        // repeated-base, and trailing-slash invite paths all leave through a
        // token-free route.  The signed-in destination is deliberately
        // groups rather than the preview, because no pending token exists.
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
      // Keep the pending invite in the controller while a signed-out user
      // authenticates. Login/signup submitters traditionally navigate to
      // /groups; the pending invite wins that intermediate destination once
      // the session is established. A warm link also moves an already signed
      // in user to the token-free preview route.
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
                  // The recovery session may already have expired; the
                  // success screen should still return to login.
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
});

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

/// Chooses the exact URI to hand to the strict invite parser.
///
/// On web, [browserLocation] is authoritative: it includes `/app` when a
/// PathUrlStrategy deployment uses `<base href="/app/">`, while [route] is
/// only `/invite/<token>`.  Native and test routers can still provide an
/// absolute route directly.  A path-only route can be synthesized only for a
/// root configured base; synthesizing a nested base without the browser seam
/// would silently broaden acceptance of a wrong deployment root.
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

/// Returns true when [uri] contains an invite marker followed by any raw
/// candidate, including malformed/encoded values and a trailing slash.  A
/// bare token-free `/invite` route remains available for the preview screen.
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

  // `Uri.pathSegments` usually decodes percent escapes, but retain a raw-path
  // scan for malformed or partially encoded forms that Dart cannot decode
  // into the literal marker.  They must be scrubbed just like any other
  // invite-shaped value, never passed through a fallback route.
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

/// Converts a path-only GoRouter location into the absolute URI expected by
/// the strict invite parser.  Browser routing supplies an absolute seam for
/// nested deployments; this fallback is intentionally limited to a root
/// configured base and to routes that already carry the configured prefix.
/// Native custom-scheme URIs are left untouched when supplied directly.
Uri? _inviteUriForRoute(Uri route, AppConfig config) {
  if (route.scheme.isNotEmpty || route.host.isNotEmpty) return route;
  // A percent escape may be decoded when rebuilding a Uri from path
  // segments.  Preserve the parser's fail-closed encoded-form policy.
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

/// Applies the in-app text-size preference on top of the platform text
/// scaler. A user preference below 100% must never reduce an OS large-text
/// setting; at the default platform scale it can still make the app a little
/// smaller as intended by the settings slider.
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
  @Deprecated(
    'Use of textScaleFactor was deprecated in preparation for nonlinear text scaling.',
  )
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

/// Chooses a foreground that remains legible over [background]. This is used
/// for initials and other small labels drawn on user-selected colors.
Color contrastingForeground(Color background) {
  final luminance = background.computeLuminance();
  final whiteContrast = 1.05 / (luminance + 0.05);
  final blackContrast = (luminance + 0.05) / 0.05;
  if (whiteContrast >= 4.5) return Colors.white;
  if (blackContrast >= 4.5) return const Color(0xff1b1b1b);
  return blackContrast > whiteContrast ? const Color(0xff1b1b1b) : Colors.white;
}

/// Returns [foreground] when it is readable on [background], otherwise uses
/// an accessible neutral while the original color can remain as a visual
/// category marker elsewhere (for example the event color rail).
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
