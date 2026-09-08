import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_location_source_contract.dart';
import 'browser_location_source_stub.dart'
    if (dart.library.js_interop) 'browser_location_source_web.dart'
    as platform;

export 'browser_location_source_contract.dart';

BrowserLocationSource createBrowserLocationSource() =>
    platform.createBrowserLocationSource();

/// 프로덕션 구현은 웹에서 `window.location.href`를 읽고 네이티브 플랫폼에서는 null을
/// 반환한다. 테스트에서는 중첩 기본 경로를 결정론적으로 모델링하도록 이 공급자를
/// [StaticBrowserLocationSource]로 재정의할 수 있다.
final browserLocationSourceProvider = Provider<BrowserLocationSource>(
  (ref) => createBrowserLocationSource(),
);
