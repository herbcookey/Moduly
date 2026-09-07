/// Read-only browser address-bar seam used by the invite router.
///
/// Flutter's web path strategy gives GoRouter the path below the app's base
/// href (for example `/invite/T`), while the actual browser URL still
/// contains the deployment prefix (for example `/app/invite/T`).  Keeping
/// this source injectable makes that distinction explicit and lets routing
/// tests exercise the exact-origin check without relying on a real browser.
abstract interface class BrowserLocationSource {
  Uri? get currentLocation;
}

/// Deterministic source for tests or embedders that own browser navigation.
class StaticBrowserLocationSource implements BrowserLocationSource {
  StaticBrowserLocationSource(this.currentLocation);

  @override
  Uri? currentLocation;
}
