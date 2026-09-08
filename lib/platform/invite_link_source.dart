import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../state/app_state.dart';

/// 초대 흐름에서 사용하는 작은 네이티브/웹 입력 어댑터다.
///
/// Supabase도 인증 콜백용 [AppLinks] 리스너를 소유한다. 이 클래스는 의도적으로
/// 같은 브로드캐스트 소스를 수신해 모든 URI를 컨트롤러로 전달한다. 컨트롤러의
/// 엄격한 파서가 초대 URI인지 인증/복구 URI인지 판단한다. 소스를 단순하게 유지하면
/// 토큰 검증을 중복하지 않고, 특히 토큰을 기록하거나 표시하지 않을 수 있다.
///
/// [main]은 `Supabase.initialize`가 완료된 뒤에만 소스를 연결하므로 인증 관찰자가
/// 콜백 설정을 먼저 소유한다. 이후 소스는 콜드 스타트 초대를 위해 자체
/// `getInitialLink` 탐색을 수행한다. 공급자 트리가 만들어지기 전에 콜드 스타트 URI가
/// 올 수도 있으며, 이런 URI는 [InviteLinkBinding]이 컨트롤러를 연결할 때까지 짧은
/// 메모리 대기열에 둔다. 대기열에는 URI 객체만 들어 있으며 절대 저장하지 않는다.
class InviteLinkSource {
  factory InviteLinkSource({
    AppLinks? appLinks,
    Stream<Uri>? linkStream,
    Future<Uri?> Function()? initialLink,
  }) => InviteLinkSource._(appLinks ?? AppLinks(), linkStream, initialLink);

  InviteLinkSource._(this._appLinks, this._linkStream, this._initialLink);

  final AppLinks _appLinks;
  final Stream<Uri>? _linkStream;
  final Future<Uri?> Function()? _initialLink;
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  final List<Uri> _buffer = <Uri>[];
  final Map<String, DateTime> _seen = <String, DateTime>{};
  StreamSubscription<Uri>? _subscription;
  bool _started = false;
  bool _disposed = false;

  Stream<Uri> get stream => _controller.stream;

  /// 수신을 한 번 시작한다. 테스트와 앱 부트스트랩에서 여러 번 호출해도 안전하다.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    final source = _linkStream ?? _appLinks.uriLinkStream;
    _subscription = source.listen(_publish, onError: _ignoreError);
    unawaited(_readInitialLink());
  }

  /// 컨트롤러 리스너를 연결하기 전에 도착한 콜드 스타트 값을 제거한다. 새 웜 스타트
  /// 이벤트를 초기 이벤트로 잘못 판단하지 않도록 `bindInviteLinkStream` 직후 호출한다.
  List<Uri> takeBuffered() {
    if (_buffer.isEmpty) return const <Uri>[];
    final result = List<Uri>.unmodifiable(_buffer);
    _buffer.clear();
    return result;
  }

  Future<void> _readInitialLink() async {
    try {
      final link = await (_initialLink ?? _appLinks.getInitialLink)();
      if (link != null) _publish(link);
    } catch (_) {
      // 일반 실행에서는 초기 링크가 없는 것이 정상이다. URI가 있으면 인증 및 초대
      // 오류는 각 컨트롤러가 처리한다. 가능한 범위에서 수행하는 이 탐색에서는 플러그인/공급자
      // 세부 정보를 절대 노출하지 않는다.
    }
  }

  void _publish(Uri link) {
    if (_disposed) return;
    // AppLinks가 초기 탐색과 스트림 양쪽으로 같은 URI를 보고할 수 있다. 크기가 제한된
    // 메모리 중복 제거 집합을 유지한다. URI 문자열은 프로세스 밖으로 나가지 않으며 로그나
    // 분석에 기록하지 않는다.
    final key = link.toString();
    final now = DateTime.now();
    final previous = _seen[key];
    // 초기 링크와 스트림 전달은 보통 연이어 일어난다. 사용자가 취소한 뒤 같은 프로세스에서
    // 같은 초대를 다시 여는 동작이 유효하도록 억제 구간을 짧게 유지한다.
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 2)) {
      return;
    }
    _seen[key] = now;
    if (_seen.length > 32) {
      final oldest = _seen.entries.reduce(
        (left, right) => left.value.isBefore(right.value) ? left : right,
      );
      _seen.remove(oldest.key);
    }
    if (_controller.hasListener) {
      _controller.add(link);
    } else {
      _buffer.add(link);
      if (_buffer.length > 8) _buffer.removeAt(0);
    }
  }

  void _ignoreError(Object error, StackTrace stackTrace) {
    // 앱 종료 중 플랫폼 링크 스트림이 닫힐 수 있다. 플러그인/공급자 오류를 사용자에게
    // 노출하거나 실수로 URI 데이터를 포함하지 않는다. 두 값을 의도적으로 버리면서
    // 콜백 형식은 Stream.listen과 일치시킨다. 여기서 의도적으로 사용하지 않은
    // 콜백 매개변수는 분석기가 경고하지 않는다.
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    // 위젯 해제까지 의도적으로 바인딩을 유지할 수 있는 소비자를 기다리지
    // 않는다. 브로드캐스트 스트림을 닫아도 소비자가 나중에 취소할 때 완료 이벤트를 보낸다.
    unawaited(_controller.close());
    _buffer.clear();
    _seen.clear();
  }
}

/// 수동 초대 소스를 연결하기 전에 Supabase/인증 콜백 관찰자를 설정한다.
/// 소스는 `finally`에서 시작하므로 원격 초기화가 실패해도 네이티브 콜드 링크를
/// 잃지 않는다. 고정되고 토큰이 없는 오류를 보고하는 것은 호출자의 [initialize]
/// 책임으로 남는다.
///
/// 이 작은 수명 주기 접점을 주입 가능하게 두면 테스트에서 프로세스 전역 Supabase
/// 초기화 함수를 호출하지 않고 순서를 검증할 수 있다.
Future<void> initializeBeforeInviteSource({
  required Future<void> Function() initialize,
  required void Function() startInviteSource,
}) async {
  try {
    await initialize();
  } finally {
    startInviteSource();
  }
}

/// 위젯 트리가 컨트롤러를 만든 뒤 초기 소스를 Riverpod 컨트롤러에 연결한다. 이를
/// 위젯으로 유지하면 인증/저장소 API를 바꾸지 않고 테스트에 부트스트랩 의존성을
/// 주입할 수 있다.
class InviteLinkBinding extends ConsumerStatefulWidget {
  const InviteLinkBinding({
    required this.source,
    required this.child,
    this.config,
    this.isRelease = kReleaseMode,
    super.key,
  });

  final InviteLinkSource source;
  final Widget child;
  final AppConfig? config;
  final bool isRelease;

  @override
  ConsumerState<InviteLinkBinding> createState() => _InviteLinkBindingState();
}

class _InviteLinkBindingState extends ConsumerState<InviteLinkBinding> {
  @override
  void initState() {
    super.initState();
    final controller = ref.read(plannerControllerProvider);
    controller.bindInviteLinkStream(
      widget.source.stream,
      config: widget.config,
      isRelease: widget.isRelease,
    );
    for (final uri in widget.source.takeBuffered()) {
      controller.captureInviteUri(
        uri,
        config: widget.config ?? AppConfig.fromEnvironment(),
        isRelease: widget.isRelease,
      );
    }
  }

  @override
  void dispose() {
    // 소스는 수명이 짧은 이 바인딩 위젯이 아니라 앱 부트스트랩에 속한다.
    // 프로세스가 종료될 때 `main`이 해제한다.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
