/// 대기 중인 초대 의도를 위한 임시 영속성 경계다.
///
/// 저장소에는 Bearer 토큰과 만료 타임스탬프만 담는다. 쿼리 매개변수, 로그, 분석에는
/// 절대 사용하지 않는다. 네이티브 호출자는 메모리 구현을 사용하고 웹 호출자는
/// `pending_invite_store.dart`의 조건부 팩터리를 통해 sessionStorage를 사용한다.
class PendingInviteRecord {
  const PendingInviteRecord({required this.token, this.expiresAt});

  final String token;
  final DateTime? expiresAt;
}

abstract class PendingInviteStore {
  Future<String?> read();

  Future<void> write(String token, DateTime expiresAt);

  Future<void> clear();

  /// 최신 저장소는 컨트롤러를 다시 불러와도 원래 기한을 유지한다. [read]만
  /// 구현한 레거시 테스트 대역은 `null` 기한으로 계속 동작하며, 컨트롤러가
  /// 상한이 있는 대체 TTL을 적용한다.
  Future<PendingInviteRecord?> readRecord() async {
    final token = await read();
    return token == null ? null : PendingInviteRecord(token: token);
  }
}

/// 네이티브 플랫폼과 테스트를 위한 결정론적 대체 구현이다. 값은 이 저장소
/// 인스턴스에서만 유지되며 컨트롤러가 해제될 때 폐기된다.
class MemoryPendingInviteStore implements PendingInviteStore {
  String? _token;
  DateTime? _expiresAt;

  @override
  Future<String?> read() async {
    return (await readRecord())?.token;
  }

  @override
  Future<PendingInviteRecord?> readRecord() async {
    final token = _token;
    final expiresAt = _expiresAt;
    if (token == null || expiresAt == null) return null;
    if (!expiresAt.isAfter(DateTime.now().toUtc())) {
      await clear();
      return null;
    }
    return PendingInviteRecord(token: token, expiresAt: expiresAt);
  }

  @override
  Future<void> write(String token, DateTime expiresAt) async {
    _token = token;
    _expiresAt = expiresAt.toUtc();
  }

  @override
  Future<void> clear() async {
    _token = null;
    _expiresAt = null;
  }
}
