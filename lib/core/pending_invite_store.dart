import 'pending_invite_store_contract.dart';
import 'pending_invite_store_platform_stub.dart'
    if (dart.library.html) 'pending_invite_store_platform_web.dart'
    as platform;

export 'pending_invite_store_contract.dart';

PendingInviteStore createDefaultPendingInviteStore() =>
    platform.createPlatformPendingInviteStore();
