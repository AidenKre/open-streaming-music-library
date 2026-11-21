// Last.fm wire shapes (spec §7.4). Unknown is not zero: a scalar of the
// wrong type is null, never coerced; `fromJson` never throws.
import 'package:frontend/models/lastfm_authorization_url.dart';

enum LastfmServerState { off, running, stopped, unknown }

enum LastfmAccountState {
  notConnected,
  awaitingAuthorization,
  connectedDisabled,
  enabled,
  unknown,
}

LastfmServerState _service(Object? v) => switch (v) {
  'off' => LastfmServerState.off,
  'running' => LastfmServerState.running,
  'stopped' => LastfmServerState.stopped,
  _ => LastfmServerState.unknown,
};

LastfmAccountState _state(Object? v) => switch (v) {
  'not_connected' => LastfmAccountState.notConnected,
  'awaiting_authorization' => LastfmAccountState.awaitingAuthorization,
  'connected_disabled' => LastfmAccountState.connectedDisabled,
  'enabled' => LastfmAccountState.enabled,
  _ => LastfmAccountState.unknown,
};

int? _int(Object? v) => v is int ? v : null;
String? _string(Object? v) => v is String ? v : null;
int? _count(Object? v) => v is int && v >= 0 ? v : null;

final _badAccountChars = RegExp(
  r'[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]',
  unicode: true,
);

/// The account name when plausible: 1-64 characters (runes) with no control, format, surrogate or separator
/// characters, and not `.` or `..`; otherwise null.
String? plausibleLastfmAccountName(Object? v) {
  if (v is! String) return null;
  final n = v.runes.length;
  if (n < 1 || n > 64 || _badAccountChars.hasMatch(v)) return null;
  if (v == '.' || v == '..') return null;
  return v;
}

/// The operator's registered application name when plausible: a trimmed string of 1-100 characters
/// (runes) with no control, format, surrogate or line/paragraph separator characters; otherwise null.
String? plausibleLastfmAppName(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  final n = t.runes.length;
  if (n < 1 || n > 100 || _badAccountChars.hasMatch(t)) return null;
  return t;
}

class LastfmCounts {
  const LastfmCounts({
    this.pending,
    this.sent,
    this.ignored,
    this.failed,
    this.dropped,
  });

  factory LastfmCounts._fromJson(Object? json) {
    if (json is! Map) return const LastfmCounts();
    return LastfmCounts(
      pending: _count(json['pending']),
      sent: _count(json['sent']),
      ignored: _count(json['ignored']),
      failed: _count(json['failed']),
      dropped: _count(json['dropped']),
    );
  }

  final int? pending;
  final int? sent;
  final int? ignored;
  final int? failed;
  final int? dropped;
}

class LastfmProblemRow {
  const LastfmProblemRow({
    required this.artist,
    required this.track,
    required this.listenedAt,
    required this.status,
    this.code,
  });
  /// Null when unknown: the server lists a damaged listen without names.
  final String? artist;

  /// Null when unknown, like [artist].
  final String? track;
  final int listenedAt;
  final String status;
  final String? code;

  static LastfmProblemRow? _fromJson(Object? row) {
    if (row is! Map) return null;
    final artist = row['artist'];
    final track = row['track'];
    final listenedAt = row['listened_at'];
    final status = row['status'];
    if (artist is! String? ||
        track is! String? ||
        listenedAt is! int ||
        status is! String) {
      return null;
    }
    return LastfmProblemRow(
      artist: artist,
      track: track,
      listenedAt: listenedAt,
      status: status,
      code: _string(row['code']),
    );
  }
}

class LastfmStatus {
  const LastfmStatus({
    required this.service,
    required this.state,
    this.needsReconnect,
    this.accountName,
    this.appName,
    this.connectionId,
    this.approvalExpiresAt,
    this.counts = const LastfmCounts(),
    this.recentProblems = const [],
    this.lastSuccessAt,
  });
  final LastfmServerState service;
  final LastfmAccountState state;
  final bool? needsReconnect;
  final String? accountName;
  final String? appName;
  final String? connectionId;
  final int? approvalExpiresAt;
  final LastfmCounts counts;
  final List<LastfmProblemRow> recentProblems;
  final int? lastSuccessAt;

  bool get isConnected =>
      state == LastfmAccountState.connectedDisabled ||
      state == LastfmAccountState.enabled;

  static LastfmStatus fromJson(Map<String, dynamic> json) {
    final problems = <LastfmProblemRow>[];
    final raw = json['recent_problems'];
    if (raw is List) {
      for (final row in raw) {
        final parsed = LastfmProblemRow._fromJson(row);
        if (parsed == null) continue;
        problems.add(parsed);
        if (problems.length == 20) break;
      }
    }
    final needsReconnect = json['needs_reconnect'];
    return LastfmStatus(
      service: _service(json['service']),
      state: _state(json['state']),
      needsReconnect: needsReconnect is bool ? needsReconnect : null,
      accountName: plausibleLastfmAccountName(json['account_name']),
      appName: plausibleLastfmAppName(json['app_name']),
      connectionId: _string(json['connection_id']),
      approvalExpiresAt: _int(json['approval_expires_at']),
      counts: LastfmCounts._fromJson(json['counts']),
      recentProblems: problems,
      lastSuccessAt: _int(json['last_success_at']),
    );
  }
}

class LastfmAuthorization {
  const LastfmAuthorization({required this.url, this.expiresAt});
  final LastfmAuthorizationUrl url;
  final int? expiresAt;

  static LastfmAuthorization? fromJson(Map<String, dynamic> json) {
    final raw = json['authorization_url'];
    if (raw is! String) return null;
    final url = LastfmAuthorizationUrl.tryParse(raw);
    if (url == null) return null;
    return LastfmAuthorization(url: url, expiresAt: _int(json['expires_at']));
  }
}

class LastfmCompleted {
  const LastfmCompleted({
    required this.connectionId,
    required this.accountName,
    required this.state,
  });
  final String connectionId;
  final String accountName;
  final LastfmAccountState state;

  static LastfmCompleted? fromJson(Map<String, dynamic> json) {
    final id = json['connection_id'];
    final name = plausibleLastfmAccountName(json['account_name']);
    final state = _state(json['state']);
    if (id is! String || id.isEmpty || name == null) return null;
    if (state != LastfmAccountState.connectedDisabled &&
        state != LastfmAccountState.enabled) {
      return null;
    }
    return LastfmCompleted(connectionId: id, accountName: name, state: state);
  }
}
