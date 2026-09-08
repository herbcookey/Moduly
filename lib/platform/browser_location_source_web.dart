import 'package:web/web.dart' as web;

import 'browser_location_source_contract.dart';

final class _WebBrowserLocationSource implements BrowserLocationSource {
  const _WebBrowserLocationSource();

  @override
  Uri? get currentLocation {
    try {
      final href = web.window.location.href;
      if (href.isEmpty) return null;
      return Uri.tryParse(href);
    } catch (_) {
      // 샌드박스 아이프레임과 개인정보 보호 확장 프로그램 때문에 위치에 접근하지 못할 수 있다.
      // 이때 엄격한 파서는 실패 시 차단하고 라우터는 초대 형태의 경로를 모두 지워
      // 토큰이 없는 목적지로 보낸다.
      return null;
    }
  }
}

BrowserLocationSource createBrowserLocationSource() =>
    const _WebBrowserLocationSource();
