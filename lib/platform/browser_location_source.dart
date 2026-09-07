import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_location_source_contract.dart';
import 'browser_location_source_stub.dart'
    if (dart.library.js_interop) 'browser_location_source_web.dart'
    as platform;

export 'browser_location_source_contract.dart';

BrowserLocationSource createBrowserLocationSource() =>
    platform.createBrowserLocationSource();

/// The production implementation reads `window.location.href` on web and
/// returns null on native platforms.  Tests may override this provider with a
/// [StaticBrowserLocationSource] to model nested base paths deterministically.
final browserLocationSourceProvider = Provider<BrowserLocationSource>(
  (ref) => createBrowserLocationSource(),
);
