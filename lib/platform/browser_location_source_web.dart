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
      // Sandboxed iframes and privacy extensions can make location access
      // unavailable.  The strict parser then fails closed and the router
      // scrubs any invite-shaped route to a token-free destination.
      return null;
    }
  }
}

BrowserLocationSource createBrowserLocationSource() =>
    const _WebBrowserLocationSource();
