import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Parses the explicit-offset ISO-8601 timestamp shape used by Supabase
/// event rows and v1 range cursors.  Dart's [DateTime.parse] normalizes
/// impossible calendar/time components (for example February 30), so wire
/// values are validated component-by-component before constructing the UTC
/// instant.  Postgres emits `Z` or `+/-HH:MM` offsets with up to six fractional
/// second digits; those forms remain supported.
DateTime? parseStrictExplicitOffsetTimestamp(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is! String) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
    r'(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4)!);
  final minute = int.tryParse(match.group(5)!);
  final second = int.tryParse(match.group(6)!);
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null ||
      second == null ||
      month < 1 ||
      month > 12 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  final calendar = DateTime.utc(year, month, day);
  if (calendar.year != year || calendar.month != month || calendar.day != day) {
    return null;
  }
  final fraction = match.group(7) ?? '';
  final micros = fraction.isEmpty ? 0 : int.parse(fraction.padRight(6, '0'));
  final base = DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
    micros ~/ 1000,
    micros % 1000,
  );
  final zone = match.group(8)!;
  if (zone == 'Z') return base;
  final offsetHour = int.parse(zone.substring(1, 3));
  final offsetMinute = int.parse(zone.substring(4, 6));
  if (offsetHour > 23 || offsetMinute > 59) return null;
  final sign = zone.codeUnitAt(0) == 45 ? -1 : 1;
  return base.subtract(
    Duration(minutes: sign * (offsetHour * 60 + offsetMinute)),
  );
}

/// Returns a defensive, duplicate-free participant list in one canonical
/// lexicographic order. Repositories perform the authorization check that
/// every id belongs to an active membership in the event's group. Sorting at
/// the model boundary keeps local, RPC, and realtime child projections equal
/// even when a caller or transport returns a different row order.
List<String> canonicalEventMemberIds(Iterable<String> memberIds) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in memberIds) {
    final id = raw.trim();
    if (id.isEmpty) {
      throw const FormatException('일정 멤버를 확인해 주세요.');
    }
    if (seen.add(id)) result.add(id);
  }
  result.sort();
  return List<String>.unmodifiable(result);
}

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

  /// Expiry is inclusive: a token at exactly `now` is no longer usable.
  /// Keeping this boundary equal to the database predicate avoids local
  /// preview/accept races around the expiry instant.
  bool get isExpired => !expiresAt.isAfter(DateTime.now().toUtc());
  bool get isExhausted => usesCount >= maxUses;
}

/// Minimal, sanitized preview returned by `preview_invite(p_token)`.
///
/// The server intentionally omits usage counts, revocation flags, token
/// material, and other invite metadata.  Invalid/expired/revoked/exhausted/
/// archived responses are represented by repository exceptions instead of a
/// partially populated model.
@immutable
class InvitePreview {
  const InvitePreview({
    required this.groupId,
    required this.groupName,
    required this.groupDescription,
    required this.groupTimezone,
    required this.expiresAt,
    required this.alreadyMember,
  });

  final String groupId;
  final String groupName;
  final String groupDescription;
  final String groupTimezone;
  final DateTime expiresAt;
  final bool alreadyMember;

  bool get isExpired => !expiresAt.isAfter(DateTime.now().toUtc());
  bool get isJoinable => !alreadyMember && !isExpired;

  InvitePreview copyWith({
    String? groupId,
    String? groupName,
    String? groupDescription,
    String? groupTimezone,
    DateTime? expiresAt,
    bool? alreadyMember,
  }) {
    return InvitePreview(
      groupId: groupId ?? this.groupId,
      groupName: groupName ?? this.groupName,
      groupDescription: groupDescription ?? this.groupDescription,
      groupTimezone: groupTimezone ?? this.groupTimezone,
      expiresAt: expiresAt ?? this.expiresAt,
      alreadyMember: alreadyMember ?? this.alreadyMember,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is InvitePreview &&
        other.groupId == groupId &&
        other.groupName == groupName &&
        other.groupDescription == groupDescription &&
        other.groupTimezone == groupTimezone &&
        other.expiresAt == expiresAt &&
        other.alreadyMember == alreadyMember;
  }

  @override
  int get hashCode => Object.hash(
    groupId,
    groupName,
    groupDescription,
    groupTimezone,
    expiresAt,
    alreadyMember,
  );
}

/// UI-facing lifecycle for one pending invite intent.  The bearer token is
/// never exposed by this enum/snapshot; it remains private to the controller.
enum PendingInviteState {
  none,
  captured,
  loading,
  ready,
  accepting,
  succeeded,
  error,
}

@immutable
class PendingInviteSnapshot {
  const PendingInviteSnapshot({
    required this.state,
    required this.preview,
    required this.error,
    required this.generation,
    required this.returnRoute,
    required this.expiresAt,
  });

  final PendingInviteState state;
  final InvitePreview? preview;
  final String? error;
  final int generation;
  final String? returnRoute;
  final DateTime? expiresAt;

  bool get hasPendingIntent =>
      state != PendingInviteState.none && expiresAt != null;
  bool get canRetry => state == PendingInviteState.error && hasPendingIntent;

  @override
  bool operator ==(Object other) {
    return other is PendingInviteSnapshot &&
        other.state == state &&
        other.preview == preview &&
        other.error == error &&
        other.generation == generation &&
        other.returnRoute == returnRoute &&
        other.expiresAt == expiresAt;
  }

  @override
  int get hashCode =>
      Object.hash(state, preview, error, generation, returnRoute, expiresAt);
}

@immutable
class PlannerEvent {
  PlannerEvent({
    required this.id,
    required this.groupId,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.ownerId,
    this.note = '',
    this.allDay = false,
    List<String> memberIds = const <String>[],
    this.colorValue = 0xff476a6f,
    this.timezone = 'UTC',
    this.allDayStartDate,
    this.allDayEndDate,
    this.version = 1,
    DateTime? updatedAt,
    this.deletedAt,
  }) : _memberIds = canonicalEventMemberIds(memberIds),
       updatedAt = updatedAt ?? startAt;

  final String id;
  final String groupId;
  final String title;
  final String note;
  final DateTime startAt; // UTC로 저장하고 화면에 표시할 때 현지 시간으로 변환한다.
  final DateTime endAt; // 종일 일정에서는 UTC 날짜 범위의 끝(미포함) 경계다.
  final bool allDay;
  final String ownerId;
  // Keep a private immutable snapshot; callers cannot mutate event state by
  // retaining and changing the list passed to the constructor.
  final List<String> _memberIds;

  /// Assigned users in deterministic application order.
  ///
  /// The returned view is intentionally unmodifiable.  This getter rather
  /// than a mutable public field preserves the old constructor shape without
  /// allowing event state to be changed behind ChangeNotifier guards.
  List<String> get memberIds => List<String>.unmodifiable(_memberIds);
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

  @override
  bool operator ==(Object other) {
    return other is PlannerEvent &&
        other.id == id &&
        other.groupId == groupId &&
        other.title == title &&
        other.note == note &&
        other.startAt == startAt &&
        other.endAt == endAt &&
        other.allDay == allDay &&
        other.ownerId == ownerId &&
        listEquals(other.memberIds, memberIds) &&
        other.colorValue == colorValue &&
        other.timezone == timezone &&
        other.allDayStartDate == allDayStartDate &&
        other.allDayEndDate == allDayEndDate &&
        other.version == version &&
        other.updatedAt == updatedAt &&
        other.deletedAt == deletedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    groupId,
    title,
    note,
    startAt,
    endAt,
    allDay,
    ownerId,
    Object.hashAll(memberIds),
    colorValue,
    timezone,
    allDayStartDate,
    allDayEndDate,
    version,
    updatedAt,
    deletedAt,
  );
}

@immutable
class EventDraft {
  EventDraft({
    required this.title,
    required this.startAt,
    required this.endAt,
    this.note = '',
    this.allDay = false,
    List<String>? memberIds,
    this.colorValue = 0xff476a6f,
    this.timezone = 'UTC',
    this.allDayStartDate,
    this.allDayEndDate,
  }) : hasExplicitMemberIds = memberIds != null,
       _memberIds = canonicalEventMemberIds(memberIds ?? const <String>[]);

  final String title;
  final String note;
  final DateTime startAt;
  final DateTime endAt;
  final bool allDay;

  /// Whether the caller supplied a participant field at all.  The public
  /// [memberIds] getter intentionally remains non-null and immutable; this
  /// bit preserves the distinction between an omitted create field (the
  /// repository defaults it to the creator) and an explicit empty assignment.
  final bool hasExplicitMemberIds;
  final List<String> _memberIds;
  List<String> get memberIds => List<String>.unmodifiable(_memberIds);
  final int colorValue;
  final String timezone;
  final DateTime? allDayStartDate;
  final DateTime? allDayEndDate;

  EventDraft copyWith({
    String? title,
    String? note,
    DateTime? startAt,
    DateTime? endAt,
    bool? allDay,
    List<String>? memberIds,
    int? colorValue,
    String? timezone,
    DateTime? allDayStartDate,
    DateTime? allDayEndDate,
    bool clearAllDayDates = false,
  }) {
    final nextHasExplicitMemberIds = memberIds != null || hasExplicitMemberIds;
    return EventDraft(
      title: title ?? this.title,
      note: note ?? this.note,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      allDay: allDay ?? this.allDay,
      memberIds: nextHasExplicitMemberIds
          ? (memberIds ?? this.memberIds)
          : null,
      colorValue: colorValue ?? this.colorValue,
      timezone: timezone ?? this.timezone,
      allDayStartDate: clearAllDayDates
          ? null
          : (allDayStartDate ?? this.allDayStartDate),
      allDayEndDate: clearAllDayDates
          ? null
          : (allDayEndDate ?? this.allDayEndDate),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is EventDraft &&
        other.title == title &&
        other.note == note &&
        other.startAt == startAt &&
        other.endAt == endAt &&
        other.allDay == allDay &&
        other.hasExplicitMemberIds == hasExplicitMemberIds &&
        listEquals(other.memberIds, memberIds) &&
        other.colorValue == colorValue &&
        other.timezone == timezone &&
        other.allDayStartDate == allDayStartDate &&
        other.allDayEndDate == allDayEndDate;
  }

  @override
  int get hashCode => Object.hash(
    title,
    note,
    startAt,
    endAt,
    allDay,
    hasExplicitMemberIds,
    Object.hashAll(memberIds),
    colorValue,
    timezone,
    allDayStartDate,
    allDayEndDate,
  );
}

/// Calendar projections supported by the planner.  The model lives outside
/// the widget layer so repository/state contracts can share the same mode
/// vocabulary without importing Flutter screens.
enum CalendarViewMode { day, month, agenda }

/// An inclusive-start, exclusive-end UTC interval used by bounded event
/// reads.  Calendar callers construct it from local-midnight wall times and
/// repositories validate the timezone against the IANA database before use.
@immutable
class EventRange {
  EventRange({
    required DateTime startUtc,
    required DateTime endUtc,
    required String viewTimezone,
  }) : startUtc = startUtc.toUtc(),
       endUtc = endUtc.toUtc(),
       viewTimezone = viewTimezone {
    if (viewTimezone.isEmpty || viewTimezone.trim() != viewTimezone) {
      throw const FormatException('시간대를 확인해 주세요.');
    }
    if (!this.endUtc.isAfter(this.startUtc)) {
      throw const FormatException('일정 범위를 확인해 주세요.');
    }
  }

  final DateTime startUtc;
  final DateTime endUtc;
  final String viewTimezone;

  Duration get duration => endUtc.difference(startUtc);

  @override
  bool operator ==(Object other) {
    return other is EventRange &&
        other.startUtc == startUtc &&
        other.endUtc == endUtc &&
        other.viewTimezone == viewTimezone;
  }

  @override
  int get hashCode => Object.hash(startUtc, endUtc, viewTimezone);

  @override
  String toString() =>
      'EventRange($startUtc, $endUtc, timezone: $viewTimezone)';
}

/// The v1 keyset tuple returned by the bounded range RPC.  The wire token is
/// intentionally opaque to callers; this class only exists so local paging
/// can apply the same strict tuple ordering as the server.  Future recurrence
/// support can populate [occurrenceKey] in a versioned cursor without
/// changing the current v1 payload shape.
@immutable
class EventRangeCursor {
  EventRangeCursor({
    required DateTime startsAtUtc,
    required String eventId,
    this.occurrenceKey = '',
  }) : startsAtUtc = startsAtUtc.toUtc(),
       eventId = eventId {
    if (eventId.isEmpty || eventId.trim() != eventId) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
    if (occurrenceKey.trim() != occurrenceKey) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
  }

  final DateTime startsAtUtc;
  final String eventId;
  final String occurrenceKey;

  /// Encodes the current v1 token expected by `events_for_range`.  Recurrence
  /// keys are reserved for a future cursor version and therefore cannot be
  /// silently dropped from a v1 request.
  String encode() {
    if (occurrenceKey.isNotEmpty) {
      throw const FormatException('지원하지 않는 페이지 커서 버전입니다.');
    }
    final payload = <String, Object>{
      'v': 1,
      'starts_at': startsAtUtc.toIso8601String(),
      'event_id': eventId,
    };
    return base64Url
        .encode(utf8.encode(jsonEncode(payload)))
        .replaceAll('=', '');
  }

  String toToken() => encode();

  static EventRangeCursor decode(String token) {
    if (token.isEmpty ||
        token.trim() != token ||
        token.length > 4096 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(token)));
      final raw = jsonDecode(decoded);
      if (raw is! Map || raw.keys.any((key) => key is! String)) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      final payload = raw.cast<String, dynamic>();
      const expectedKeys = <String>{'v', 'starts_at', 'event_id'};
      final startsAtRaw = payload['starts_at'];
      if (payload.length != expectedKeys.length ||
          !payload.keys.toSet().containsAll(expectedKeys) ||
          payload['v'] != 1 ||
          startsAtRaw is! String ||
          payload['event_id'] is! String) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      final startsAt = parseStrictExplicitOffsetTimestamp(startsAtRaw);
      if (startsAt == null) {
        throw const FormatException('페이지 커서를 확인해 주세요.');
      }
      final eventId = payload['event_id'] as String;
      return EventRangeCursor(startsAtUtc: startsAt, eventId: eventId);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('페이지 커서를 확인해 주세요.');
    }
  }

  static EventRangeCursor fromToken(String token) => decode(token);

  @override
  bool operator ==(Object other) {
    return other is EventRangeCursor &&
        other.startsAtUtc == startsAtUtc &&
        other.eventId == eventId &&
        other.occurrenceKey == occurrenceKey;
  }

  @override
  int get hashCode => Object.hash(startsAtUtc, eventId, occurrenceKey);

  @override
  String toString() => 'EventRangeCursor($startsAtUtc, $eventId)';
}

/// Immutable page returned by a bounded event range read.
@immutable
class EventRangePage {
  EventRangePage({
    required Iterable<PlannerEvent> events,
    required this.nextCursor,
    required this.hasMore,
  }) : events = List<PlannerEvent>.unmodifiable(events) {
    if (hasMore != (nextCursor != null)) {
      throw const FormatException('일정 페이지 응답을 확인해 주세요.');
    }
  }

  final List<PlannerEvent> events;
  final EventRangeCursor? nextCursor;
  final bool hasMore;

  static EventRangePage empty() => EventRangePage(
    events: const <PlannerEvent>[],
    nextCursor: null,
    hasMore: false,
  );

  @override
  bool operator ==(Object other) {
    return other is EventRangePage &&
        listEquals(other.events, events) &&
        other.nextCursor == nextCursor &&
        other.hasMore == hasMore;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(events), nextCursor, hasMore);
}
