import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/playback/playback_issue_bus.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';

/// Decides what a source failure means (SC-27 §2.9; decide-only, like the
/// target resolver). The plugin's error carries no HTTP status, so:
///  * [SourceFailureKind.missingLocalFile] only after an async stat finds
///    the recorded file absent, [SourceFailureKind.damagedLocalFile] when
///    it is present (it failed to play);
///  * [SourceFailureKind.gone] only after an authoritative check: the
///    track's sync tombstone (no longer in the local catalog) or a 404/410
///    from a bounded `GET /tracks/{uuid}`;
///  * otherwise [SourceFailureKind.transient] (offline, no answer, server
///    error) or [SourceFailureKind.unknown]. Neither auto-skips.
class SourceFailureClassifier {
  SourceFailureClassifier({
    required this.fileExists,
    required this.trackKnownLocally,
    required this.fetchTrackStatus,
    required this.isOffline,
  });
  final Future<bool> Function(String path) fileExists;
  final Future<bool> Function(String trackUuid) trackKnownLocally;

  /// HTTP status of `GET /tracks/{uuid}`; null when there was no answer.
  final Future<int?> Function(String trackUuid) fetchTrackStatus;
  final bool Function() isOffline;

  Future<SourceFailureKind> classify({
    required String trackUuid,
    required String? filePath,
    required bool uncertain,
  }) async {
    // Without a settled identity nothing can be confirmed.
    if (uncertain) return SourceFailureKind.unknown;
    if (filePath != null && filePath.isNotEmpty) {
      // A file on disk that failed to play is a suspected damaged download
      // (decision 6). The plugin gives no portable decode error, so this is
      // only "present but failed": playback marks it damaged only with
      // evidence (review major 1) and never deletes the file, so a
      // misjudged one costs only a stream or a skip.
      return await fileExists(filePath)
          ? SourceFailureKind.damagedLocalFile
          : SourceFailureKind.missingLocalFile;
    }
    if (!await trackKnownLocally(trackUuid)) return SourceFailureKind.gone;
    if (isOffline()) return SourceFailureKind.transient;
    final status = await fetchTrackStatus(trackUuid);
    if (status == 404 || status == 410) return SourceFailureKind.gone;
    if (status == null || status >= 500) return SourceFailureKind.transient;
    return SourceFailureKind.unknown;
  }
}

/// The bounded authoritative check (5 s), through the existing
/// `TracksApi.getTrack` (the take-server path uses the same request).
@visibleForTesting
Future<int?> trackStatusVia(TracksApi api, String trackUuid,
    {Duration timeout = const Duration(seconds: 5)}) async {
  try {
    await api.getTrack(trackUuid).timeout(timeout);
    return 200;
  } on ApiException catch (error) {
    return error.statusCode;
  } catch (_) {
    return null; // timeout, network failure: no answer
  }
}

final sourceFailureClassifierProvider = Provider<SourceFailureClassifier>(
  (ref) => SourceFailureClassifier(
    fileExists: (path) => File(path).exists(),
    trackKnownLocally: (uuid) async =>
        (await ref.read(databaseProvider).getTrackByUuid(uuid)).isNotEmpty,
    fetchTrackStatus: (uuid) => trackStatusVia(ref.read(tracksApiProvider), uuid),
    isOffline: () => ref.read(offlineModeProvider),
  ),
);
