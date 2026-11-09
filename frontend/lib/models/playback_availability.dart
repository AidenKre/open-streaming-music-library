import 'package:flutter/foundation.dart';

/// How much of a scope is downloaded locally.
enum LocalCoverage {
  /// Nothing downloaded (or an empty scope).
  remote,

  /// Some, not all, tracks downloaded.
  partial,

  /// Every track downloaded.
  downloaded,
}

/// Whether a library scope can be played or queued right now, and what its
/// download actions should offer (SC-06). The single enablement predicate
/// for every surface: views read it to enable or dim, never decide it.
///
/// [coverage] is null while the download counts are still loading. Unknown
/// is not zero: offline, an unknown scope is not yet enabled, but it never
/// claims "nothing downloaded".
@immutable
final class PlaybackAvailability {
  /// The counts are not known yet.
  const PlaybackAvailability.unknown({required this.offline})
      : coverage = null,
        hasUndecodable = false;

  const PlaybackAvailability._(this.offline, this.coverage,
      {this.hasUndecodable = false});

  /// [undecodable]: how many of the [downloaded] tracks are in a codec this
  /// device can't decode (review major 1): still downloads (Delete applies),
  /// but they don't play offline.
  factory PlaybackAvailability.of({
    required bool offline,
    required int downloaded,
    required int total,
    int undecodable = 0,
  }) {
    assert(
      downloaded >= 0 && total >= 0 && downloaded <= total,
      'invalid counts $downloaded/$total',
    );
    assert(undecodable >= 0 && undecodable <= downloaded,
        'invalid undecodable count $undecodable/$downloaded');
    final LocalCoverage coverage;
    if (total == 0 || downloaded == 0) {
      coverage = LocalCoverage.remote;
    } else if (downloaded == total) {
      coverage = LocalCoverage.downloaded;
    } else {
      coverage = LocalCoverage.partial;
    }
    return PlaybackAvailability._(offline, coverage,
        hasUndecodable: undecodable > 0);
  }

  final bool offline;

  /// Some downloads are in a codec this device can't decode.
  final bool hasUndecodable;

  /// Null while unknown.
  final LocalCoverage? coverage;

  bool get isUnknown => coverage == null;

  bool get isFullyDownloaded => coverage == LocalCoverage.downloaded;

  bool get hasAnyDownloaded =>
      coverage == LocalCoverage.partial || coverage == LocalCoverage.downloaded;

  /// Play / Play next / Add to queue. Online everything streams. Offline only
  /// a fully downloaded scope may play, so a queue action never enqueues
  /// streaming-only tracks (Phase 6 deliberately makes `partial` playable).
  /// A download this device can't decode doesn't play offline either.
  bool get canPlay => !offline || (isFullyDownloaded && !hasUndecodable);

  /// Download (the missing tracks) needs the server and something missing.
  bool get canDownload => !offline && !isFullyDownloaded;

  @override
  bool operator ==(Object other) =>
      other is PlaybackAvailability &&
      other.offline == offline &&
      other.coverage == coverage &&
      other.hasUndecodable == hasUndecodable;

  @override
  int get hashCode => Object.hash(offline, coverage, hasUndecodable);

  @override
  String toString() =>
      'PlaybackAvailability(offline: $offline, coverage: ${coverage?.name ?? 'unknown'}'
      '${hasUndecodable ? ', undecodable downloads' : ''})';
}
