import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Something the playback model found while deciding or playing (SC-27).
/// Resolvers return issues; only appliers (the playback core and
/// PlaybackRequests) publish them. Nothing is shown to the user yet: the
/// typed issues are the seam for later UI (error banner, re-download).
sealed class PlaybackIssue {
  const PlaybackIssue();
}

/// A recorded download whose file is not on disk (SC-06/SC-27). Found by an
/// async stat; playback falls back under the normal offline policy.
final class LocalFileMissing extends PlaybackIssue {
  const LocalFileMissing(this.trackUuid, this.path);
  final String trackUuid;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is LocalFileMissing &&
      other.trackUuid == trackUuid &&
      other.path == path;

  @override
  int get hashCode => Object.hash(trackUuid, path);

  @override
  String toString() => 'LocalFileMissing($trackUuid, $path)';
}

/// How a source failure was classified (SC-27 §2.9). [missingLocalFile],
/// [damagedLocalFile] and [gone] are confirmed and recovered (a stream
/// fallback online, a skip offline; gone always skips). A transient stream
/// failure is skipped only offline (decision 1); unknown never skips.
enum SourceFailureKind {
  missingLocalFile,

  /// The recorded download is on disk but failed to play (decision 6). Not
  /// yet proof of damage (review major 1): online it streams and is marked
  /// damaged only once that stream plays; offline it is skipped, unmarked.
  damagedLocalFile,
  gone,
  transient,
  unknown,
}

/// A source failed to load or play, after classification.
final class PlaybackSourceFailed extends PlaybackIssue {
  const PlaybackSourceFailed(this.trackUuid, this.kind,
      {this.errorCode, this.errorMessage});
  final String? trackUuid;
  final SourceFailureKind kind;
  final int? errorCode;
  final String? errorMessage;

  @override
  String toString() => 'PlaybackSourceFailed($trackUuid, $kind, $errorCode)';
}

/// An internal playback task failed (its error sink, SC-27 invariant 13).
final class PlaybackTaskFailed extends PlaybackIssue {
  const PlaybackTaskFailed(this.task, this.error);
  final String task;
  final Object error;

  @override
  String toString() => 'PlaybackTaskFailed($task, $error)';
}

/// The playback issue stream and log (SC-27 `PlaybackIssueBus`).
class PlaybackIssueBus {
  final StreamController<PlaybackIssue> _controller =
      StreamController<PlaybackIssue>.broadcast();

  Stream<PlaybackIssue> get issues => _controller.stream;

  void publish(PlaybackIssue issue) {
    developer.log('Playback issue: $issue', name: 'PlaybackIssueBus');
    if (!_controller.isClosed) _controller.add(issue);
  }

  void dispose() => unawaited(_controller.close());
}

final playbackIssueBusProvider = Provider<PlaybackIssueBus>((ref) {
  final bus = PlaybackIssueBus();
  ref.onDispose(bus.dispose);
  return bus;
});
