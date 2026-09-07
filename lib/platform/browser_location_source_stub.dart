import 'browser_location_source_contract.dart';

final class _StubBrowserLocationSource implements BrowserLocationSource {
  const _StubBrowserLocationSource();

  @override
  Uri? get currentLocation => null;
}

BrowserLocationSource createBrowserLocationSource() =>
    const _StubBrowserLocationSource();
