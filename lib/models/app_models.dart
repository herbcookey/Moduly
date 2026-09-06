import 'package:flutter/foundation.dart';

@immutable
class PlannerUser {
  const PlannerUser({required this.id, required this.email, this.displayName});

  final String id;
  final String email;
  final String? displayName;
}

@immutable
class PlannerGroup {
  const PlannerGroup({
    required this.id,
    required this.name,
    this.description = '',
    this.timezone = 'UTC',
    this.version = 1,
    this.colorValue = 0xff476a6f,
    this.ownerId,
    this.archivedAt,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String description;
  final String timezone;
  final int version;
  final int colorValue;

  /// The immutable owner recorded by the database. Older/local fixtures may
  /// omit this field and derive ownership from the active member list.
  final String? ownerId;

  /// Optional lifecycle markers. The production schema currently uses
  /// `deleted_at` for an archived group, while some clients expose that state
  /// as `archivedAt`; retaining both keeps the model additive and tolerant of
  /// either payload shape.
  final DateTime? archivedAt;
  final DateTime? deletedAt;

  bool get isArchived => archivedAt != null || deletedAt != null;
  bool get isDeleted => deletedAt != null;

  PlannerGroup copyWith({
    String? id,
    String? name,
    String? description,
    String? timezone,
    int? version,
    int? colorValue,
    String? ownerId,
    DateTime? archivedAt,
    DateTime? deletedAt,
    bool clearOwnerId = false,
    bool clearArchivedAt = false,
    bool clearDeletedAt = false,
  }) {
    return PlannerGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      timezone: timezone ?? this.timezone,
      version: version ?? this.version,
      colorValue: colorValue ?? this.colorValue,
      ownerId: clearOwnerId ? null : (ownerId ?? this.ownerId),
      archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlannerGroup &&
        other.id == id &&
        other.name == name &&
        other.description == description &&
        other.timezone == timezone &&
        other.version == version &&
        other.colorValue == colorValue &&
        other.ownerId == ownerId &&
        other.archivedAt == archivedAt &&
        other.deletedAt == deletedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    timezone,
    version,
    colorValue,
    ownerId,
    archivedAt,
    deletedAt,
  );
}

@immutable
class PlannerMember {
  const PlannerMember({
    required this.id,
    required this.name,
    required this.email,
    this.isOwner = false,
    this.isActive = true,
    this.removedAt,
    this.avatarColor = 0xff476a6f,
  });

  final String id;
  final String name;
  final String email;
  final bool isOwner;
  final bool isActive;
  final DateTime? removedAt;
  final int avatarColor;

  PlannerMember copyWith({
    String? id,
    String? name,
    String? email,
    bool? isOwner,
    bool? isActive,
    DateTime? removedAt,
    int? avatarColor,
    bool clearRemovedAt = false,
  }) {
    return PlannerMember(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      isOwner: isOwner ?? this.isOwner,
      isActive: isActive ?? this.isActive,
      removedAt: clearRemovedAt ? null : (removedAt ?? this.removedAt),
      avatarColor: avatarColor ?? this.avatarColor,
    );
  }
}

@immutable
class InviteCode {
  const InviteCode({
    required this.id,
    required this.groupId,
    required this.expiresAt,
    required this.maxUses,
    required this.usesCount,
    required this.version,
    this.token,
    this.revokedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? expiresAt,
       updatedAt = updatedAt ?? expiresAt;

  final String id;
  final String groupId;
  final DateTime expiresAt;
  final int maxUses;
  final int usesCount;
  final int version;

  /// 평문은 생성 RPC에서 한 번만 반환하며 행에는 저장하지 않는다.
  final String? token;
  final DateTime? revokedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isRevoked => revokedAt != null;
  bool get isExpired => expiresAt.isBefore(DateTime.now().toUtc());
  bool get isExhausted => usesCount >= maxUses;
}

@immutable
class PlannerEvent {
  const PlannerEvent({
    required this.id,
    required this.groupId,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.ownerId,
    this.note = '',
    this.allDay = false,
    this.memberIds = const <String>[],
    this.colorValue = 0xff476a6f,
    this.timezone = 'UTC',
    this.allDayStartDate,
    this.allDayEndDate,
    this.version = 1,
    DateTime? updatedAt,
    this.deletedAt,
  }) : updatedAt = updatedAt ?? startAt;

  final String id;
  final String groupId;
  final String title;
  final String note;
  final DateTime startAt; // UTC로 저장하고 화면에 표시할 때 현지 시간으로 변환한다.
  final DateTime endAt; // 종일 일정에서는 UTC 날짜 범위의 끝(미포함) 경계다.
  final bool allDay;
  final String ownerId;
  final List<String> memberIds;
  final int colorValue;
  final String timezone;
  final DateTime? allDayStartDate;
  final DateTime? allDayEndDate;
  final int version;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  PlannerEvent copyWith({
    String? id,
    String? groupId,
    String? title,
    String? note,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    String? ownerId,
    List<String>? memberIds,
    int? colorValue,
    String? timezone,
    DateTime? allDayStartDate,
    DateTime? allDayEndDate,
    int? version,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    bool clearAllDayDates = false,
  }) {
    return PlannerEvent(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      title: title ?? this.title,
      note: note ?? this.note,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      allDay: allDay ?? this.allDay,
      ownerId: ownerId ?? this.ownerId,
      memberIds: memberIds ?? this.memberIds,
      colorValue: colorValue ?? this.colorValue,
      timezone: timezone ?? this.timezone,
      allDayStartDate: clearAllDayDates
          ? null
          : (allDayStartDate ?? this.allDayStartDate),
      allDayEndDate: clearAllDayDates
          ? null
          : (allDayEndDate ?? this.allDayEndDate),
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}

@immutable
class EventDraft {
  const EventDraft({
    required this.title,
    required this.startAt,
    required this.endAt,
    this.note = '',
    this.allDay = false,
    this.memberIds = const <String>[],
    this.colorValue = 0xff476a6f,
    this.timezone = 'UTC',
    this.allDayStartDate,
    this.allDayEndDate,
  });

  final String title;
  final String note;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;
  final List<String> memberIds;
  final int colorValue;
  final String timezone;
  final DateTime? allDayStartDate;
  final DateTime? allDayEndDate;
}
