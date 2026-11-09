import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';

/// The audio codecs the server can serve (`media_types.py`: mp3, aac, alac,
/// flac and wav/pcm). Downloads and "original" streams pass the source codec
/// through; every transcoded quality is AAC.
enum AudioCodecFamily {
  mp3('MP3'),
  aac('AAC'),
  alac('ALAC'),
  flac('FLAC'),
  pcm('WAV');

  const AudioCodecFamily(this.label);

  /// How the codec is named to the user.
  final String label;

  /// The family of a codec name as the server reports it (ffprobe's
  /// `codec_name`), or null for a codec outside the five (unknown, never
  /// assumed unsupported).
  static AudioCodecFamily? of(String? codec) {
    final name = codec?.trim().toLowerCase();
    if (name == null || name.isEmpty) return null;
    if (name == 'wav' || name.startsWith('pcm_')) return AudioCodecFamily.pcm;
    for (final family in values) {
      if (family.name == name) return family;
    }
    return null;
  }
}

/// Which codecs this device's playback engine can decode (review major 1,
/// user 2026-11-09). just_audio bundles no decoders: it plays through the
/// OS (AVPlayer on Apple, ExoPlayer with the device's decoders on Android),
/// and Windows/Linux have no engine in this app yet. Asked once at startup,
/// so playback never loads a source it knows cannot play: an unsupported
/// codec is a known state ("Unsupported codec"), never a failure, and never
/// marks a download damaged.
///
/// Unknown is not unsupported: a codec outside the five, an unknown codec
/// (null), or a platform that could not be asked all count as decodable.
@immutable
class CodecSupport {
  /// Could not be determined: everything counts as decodable.
  const CodecSupport.unknown()
      : _decodable = null,
        hasEngine = true;

  /// No playback engine on this platform (Windows/Linux today).
  const CodecSupport.noEngine()
      : _decodable = const {},
        hasEngine = false;

  const CodecSupport(Set<AudioCodecFamily> decodable)
      : _decodable = decodable,
        hasEngine = true;

  /// Every family (Apple: AVFoundation decodes all five on iOS 13+ and
  /// macOS 10.13+).
  static const all = CodecSupport({...AudioCodecFamily.values});

  final Set<AudioCodecFamily>? _decodable;

  /// False when this platform has no playback engine at all.
  final bool hasEngine;

  bool canDecode(String? codec) {
    final decodable = _decodable;
    if (decodable == null) return true;
    final family = AudioCodecFamily.of(codec);
    if (family == null) return hasEngine;
    return decodable.contains(family);
  }

  /// The user-facing name of [codec] when this device cannot decode it, else
  /// null.
  String? unsupportedLabel(String? codec) {
    if (canDecode(codec)) return null;
    return AudioCodecFamily.of(codec)?.label ?? codec?.toUpperCase();
  }

  /// The codec of [track] this device can't decode, by its user-facing
  /// name, or null: its download's codec when it has a usable download (it
  /// can't play from the file; offline it is skipped), else its source's
  /// (an "original" stream plays transcoded instead).
  String? unsupportedCodecOf(TrackUI track) => unsupportedLabel(
      track.isDownloaded ? track.downloadedCodec : track.codec);

  /// Whether [track] can play from its download on this device.
  bool playsDownload(TrackUI track) =>
      track.isDownloaded && canDecode(track.downloadedCodec);

  @visibleForTesting
  static const channel = MethodChannel('osml/codecs');

  /// Asks the platform once. Never throws: a failed question is unknown.
  static Future<CodecSupport> probe({
    bool isWeb = kIsWeb,
    TargetPlatform? platform,
    MethodChannel methodChannel = channel,
  }) async {
    if (isWeb) return const CodecSupport.unknown();
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return all;
      case TargetPlatform.android:
        try {
          final names = await methodChannel
              .invokeListMethod<String>('decodableAudioCodecs');
          if (names == null) return const CodecSupport.unknown();
          return CodecSupport({
            for (final name in names) ?AudioCodecFamily.of(name),
          });
        } catch (error) {
          developer.log('Codec probe failed; treating codecs as unknown',
              name: 'CodecSupport', error: error);
          return const CodecSupport.unknown();
        }
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        // No just_audio implementation is bundled for these (desktop
        // playback is a later task).
        return const CodecSupport.noEngine();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CodecSupport &&
      other.hasEngine == hasEngine &&
      setEquals(other._decodable, _decodable);

  @override
  int get hashCode => Object.hash(
      hasEngine, _decodable == null ? null : Object.hashAllUnordered(_decodable));

  @override
  String toString() => _decodable == null
      ? 'CodecSupport.unknown'
      : 'CodecSupport(${_decodable.map((f) => f.name).join(', ')}'
          '${hasEngine ? '' : ', no engine'})';
}

/// Probed in `main` before the app starts and overridden there; unknown
/// (everything decodable) until then and in tests.
final codecSupportProvider =
    Provider<CodecSupport>((ref) => const CodecSupport.unknown());
