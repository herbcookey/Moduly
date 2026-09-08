/// 초대 라우터가 사용하는 읽기 전용 브라우저 주소 표시줄 접점이다.
///
/// Flutter의 웹 경로 전략은 GoRouter에 앱의 기본 href 아래 경로(예:
/// `/invite/T`)를 제공하지만 실제 브라우저 URL에는 여전히 배포 접두사(예:
/// `/app/invite/T`)가 들어 있다. 이 소스를 주입 가능하게 두면 차이를 명확히 하고,
/// 라우팅 테스트에서 실제 브라우저 없이 정확한 출처 검사를 실행할 수 있다.
abstract interface class BrowserLocationSource {
  Uri? get currentLocation;
}

/// 브라우저 탐색을 소유한 테스트 또는 임베더용 결정론적 소스다.
class StaticBrowserLocationSource implements BrowserLocationSource {
  StaticBrowserLocationSource(this.currentLocation);

  @override
  Uri? currentLocation;
}
