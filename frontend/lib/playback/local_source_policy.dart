import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/quality_presets.dart';

/// Decides whether a queue entry plays from its download (SC-27 §2; Phase 5
/// decision 6 and review major 1). The rule the target resolver decides with
/// (plus its file check). The engine uses it only as the plan for sources
/// nobody landed on and to tell whether a rebuild has new evidence; the queue
/// player no longer computes a seed's source from it. Decide-only.
///
/// An entry's `filePath` is already only a usable download (a download
/// marked damaged reads null). A download in a codec this device cannot
/// decode ([CodecSupport]) is not played from its file either, and an
/// "original" stream of such a codec is streamed transcoded instead (the
/// user, 2026-11-09). On top of that, a download whose file failed
/// to play while online is a suspect: it streams until the stream proves the
/// device can play audio (then playback marks it damaged) or the evidence is
/// lost (then the suspicion is dropped and the file is tried again). Kept in
/// memory only, so a platform failure can never leave a persistent mark.
class LocalSourcePolicy {
  LocalSourcePolicy({this.codecs = const CodecSupport.unknown()});

  final CodecSupport codecs;

  /// Suspected downloads: track uuid -> the path that failed.
  final Map<String, String> _suspects = {};

  /// The local file [entry] plays from, or null when it streams.
  String? localPathFor(QueuePlaybackEntry entry) => localPathOf(
      uuid: entry.uuidId,
      filePath: entry.filePath,
      downloadedCodec: entry.downloadedCodec);

  /// [localPathFor] from the fields it reads.
  String? localPathOf({
    required String uuid,
    required String? filePath,
    required String? downloadedCodec,
  }) {
    if (filePath == null || filePath.isEmpty) return null;
    if (!codecs.canDecode(downloadedCodec)) return null;
    if (_suspects[uuid] == filePath) return null;
    return filePath;
  }

  /// The quality [entry] streams at when [preferred] is the chosen one: an
  /// "original" stream passes the source codec through, so a codec this
  /// device cannot decode is streamed at the best transcoded quality (AAC)
  /// instead. Lossless sources (the only codecs a device may lack) are
  /// always above every preset's bitrate, so the server does transcode.
  String streamQualityFor(QueuePlaybackEntry entry, String preferred) =>
      streamQualityForCodec(entry.sourceCodec, preferred);

  /// The same rule from a source codec alone (a preview has no queue entry).
  /// An unknown codec (null) streams as chosen.
  String streamQualityForCodec(String? sourceCodec, String preferred) {
    if (preferred != originalQuality) return preferred;
    if (codecs.canDecode(sourceCodec)) return preferred;
    if (!codecs.canDecode(AudioCodecFamily.aac.name)) return preferred;
    return transcodedFallbackQuality;
  }

  /// True when [entry] streams transcoded although "original" was chosen.
  bool streamsTranscoded(QueuePlaybackEntry entry, String preferred) =>
      localPathFor(entry) == null &&
      streamQualityFor(entry, preferred) != preferred;

  /// [path] of [trackUuid] failed to play: stream it until it is resolved.
  void suspect(String trackUuid, String path) => _suspects[trackUuid] = path;

  /// Drops the suspicion of [path] (a newer path is left alone).
  void clearSuspect(String trackUuid, String path) {
    if (_suspects[trackUuid] == path) _suspects.remove(trackUuid);
  }

  bool isSuspect(String trackUuid, String path) =>
      _suspects[trackUuid] == path;
}

/// Owned by the playback scope, like the engine.
final localSourcePolicyProvider = Provider<LocalSourcePolicy>(
    (ref) => LocalSourcePolicy(codecs: ref.watch(codecSupportProvider)));
