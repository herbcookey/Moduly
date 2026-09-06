import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'repositories/auth_repository.dart';
import 'screens/auth_screens.dart';
import 'screens/event_editor_screen.dart';
import 'screens/group_picker_screen.dart';
import 'screens/home_screen.dart';
import 'screens/legal_screens.dart';
import 'screens/members_screen.dart';
import 'screens/settings_screen.dart';
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
        return MediaQuery(
          data: media.copyWith(
            textScaler: _AppTextScaler(media.textScaler, controller.textScale),
          ),
          child: child ?? const SizedBox.shrink(),
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
  // 비밀번호 복구 화면은 비밀번호 업데이트가 완료되면 성공 상태를
  // 잠시 보여줘야 한다. 컨트롤러가 세션을 signed-in으로 바꾸는 알림과
  // 화면이 성공 상태를 그리는 사이에 라우터가 /groups로 이동하지 않도록
  // 현재 복구 화면의 한 번성 허용 플래그를 둔다.
  var allowPasswordResetSuccess = false;
  return GoRouter(
    initialLocation: '/login',
    refreshListenable: controller,
    redirect: (context, state) {
      final location = state.uri.path;
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
      final publicAuthRoute =
          location == '/login' ||
          location == '/signup' ||
          location == '/verify-email' ||
          location == '/forgot-password' ||
          location == '/reset-password' ||
          location == '/privacy-policy' ||
          location == '/terms-of-service' ||
          location == '/auth-callback';
      if (!controller.isAuthenticated && !publicAuthRoute) return '/login';
      if (location != '/reset-password' && !controller.isInPasswordRecovery) {
        allowPasswordResetSuccess = false;
      }
      // Supabase가 복구 인증 세션을 이미 노출했더라도 복구 링크는
      // 의도적으로 /reset-password에 남겨 둔다.
      if (controller.isInPasswordRecovery && location != '/reset-password') {
        return '/reset-password';
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
        ],
      ),
      GoRoute(
        path: '/event/new',
        builder: (context, state) => const EventEditorScreen(),
      ),
      GoRoute(
        path: '/event/:id',
        builder: (context, state) =>
            EventEditorScreen(eventId: state.pathParameters['id']),
      ),
    ],
  );
});

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
