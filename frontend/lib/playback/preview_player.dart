import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/preview_engine.dart';

import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/playback/track_cache_manager.dart';
import 'package:frontend/providers/track_codec_lookup_provider.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// What the preview player plays: one source, never a queue row.
sealed class PreviewSource {
  const PreviewSource();
}

/// A staged upload's original audio (its preview route).
final class StagedUploadPreview extends PreviewSource {
  const StagedUploadPreview(this.itemUuid);
  final String itemUuid;

  @override
  bool operator ==(Object other) =>
      other is StagedUploadPreview && other.itemUuid == itemUuid;

  @override
  int get hashCode => Object.hash(StagedUploadPreview, itemUuid);
}

/// A library track through its normal stream URL (duplicate audition).
final class LibraryTrackPreview extends PreviewSource {
  const LibraryTrackPreview(this.trackUuid);
  final String trackUuid;

  @override
  bool operator ==(Object other) =>
      other is LibraryTrackPreview && other.trackUuid == trackUuid;

  @override
  int get hashCode => Object.hash(LibraryTrackPreview, trackUuid);
}

/// The preview player's state. [needsConnection]: offline (O11, no cache);
/// [unavailable]: the token may not go to this server, or there is none.
enum PreviewStatus {
  idle,
  loading,
  playing,
  paused,
  completed,
  needsConnection,
  unavailable,
  failed,
}

/// Whether a preview is active: playing, or still loading (it can be stopped).
bool previewIsActive(PreviewStatus s) =>
    s == PreviewStatus.playing || s == PreviewStatus.loading;

/// Where a preview source can be heard ([uri]), or why not ([refusal]).
class PreviewUriResolution {
  const PreviewUriResolution.playable(Uri this.uri) : refusal = null;
  const PreviewUriResolution.refused(PreviewStatus this.refusal) : uri = null;
  final Uri? uri;
  final PreviewStatus? refusal;
}

/// Builds the media-token URI of a preview source, only when the binding
/// gate allows the token to go to this server (OPEN-M-11). Never logs it.
/// A library preview prefers original but follows the device codec rule
/// (`LocalSourcePolicy.streamQualityForCodec`); a staged one never looks up a codec.
class PreviewSourceUris {
  PreviewSourceUris({
    required String baseUrl,
    required String? mediaToken,
    required Future<bool> Function() mayAttachToken,
    required bool Function() isOffline,
    LocalSourcePolicy? localSources,
    Future<String?> Function(String trackUuid)? sourceCodecOf,
  })  : _baseUrl = baseUrl,
        _mediaToken = mediaToken,
        _mayAttachToken = mayAttachToken,
        _isOffline = isOffline,
        _localSources = localSources ?? LocalSourcePolicy(),
        _sourceCodecOf = sourceCodecOf ?? ((_) async => null);

  final LocalSourcePolicy _localSources;
  final Future<String?> Function(String trackUuid) _sourceCodecOf;
  final String _baseUrl;
  final String? _mediaToken;
  final Future<bool> Function() _mayAttachToken;
  final bool Function() _isOffline;

  Future<PreviewUriResolution> resolve(PreviewSource source) async {
    if (_isOffline()) {
      return const PreviewUriResolution.refused(PreviewStatus.needsConnection);
    }
    final token = _mediaToken;
    if (token == null || token.isEmpty) {
      return const PreviewUriResolution.refused(PreviewStatus.unavailable);
    }
    if (!await _mayAttachToken()) {
      return const PreviewUriResolution.refused(PreviewStatus.unavailable);
    }
    return PreviewUriResolution.playable(switch (source) {
      StagedUploadPreview(:final itemUuid) =>
        buildStagedPreviewUri(_baseUrl, itemUuid, mediaToken: token),
      LibraryTrackPreview(:final trackUuid) => buildTrackStreamUri(
          _baseUrl, trackUuid,
          mediaToken: token,
          quality: _localSources.streamQualityForCodec(
              await _codecOf(trackUuid), originalQuality)),
    });
  }

  /// The track's source codec; a failed lookup is an unknown codec (the
  /// original plays), never a failed preview.
  Future<String?> _codecOf(String trackUuid) async {
    try {
      return await _sourceCodecOf(trackUuid);
    } catch (error) {
      developer.log('Codec lookup failed: $error', name: 'PreviewSourceUris');
      return null;
    }
  }
}

final previewSourceUrisProvider = Provider<PreviewSourceUris>((ref) {
  final baseUrl = ref.read(apiClientProvider).baseUrl;
  return PreviewSourceUris(
    baseUrl: baseUrl,
    mediaToken: ref.read(credentialsProvider)?.mediaToken,
    mayAttachToken: () =>
        ref.read(serverBindingGateProvider).whenMaySendTokenTo(baseUrl),
    // Offline, or the server check failed (sign-off OPEN-M-11: as playback).
    isOffline: () => ref.read(streamsUnavailableProvider)(),
    localSources: ref.read(localSourcePolicyProvider),
    sourceCodecOf: ref.read(trackSourceCodecLookupProvider),
  );
});

/// What the preview player is doing. [duration]: null = unknown.
class PreviewState {
  const PreviewState({this.source, this.status = PreviewStatus.idle,
      this.duration});
  final PreviewSource? source;
  final PreviewStatus status;
  final Duration? duration;
}

/// Builds the preview player's own engine, on demand.
final previewEngineFactoryProvider = Provider<PreviewEngine Function()>(
    (ref) => JustAudioPreviewEngine.create);

final previewPlayerProvider =
    NotifierProvider<PreviewPlayer, PreviewState>(PreviewPlayer.new);

/// The preview/audition player (SC-27, spec §5 Preview). Model: it loads and
/// plays one source on its own engine, never a queue row, history click or
/// listen. Every load is generation-cancelled (a new play, a relinquish,
/// close or dispose makes older work a no-op), and output happens only while
/// it holds focus: it acquires from the library first, which pauses and
/// acknowledges, and it stops and acknowledges when the library takes the
/// output back. Closing leaves the library paused for the user to resume.
class PreviewPlayer extends Notifier<PreviewState>
    implements AudioFocusOwner, FocusRelinquisher {
  late AudioFocus _focus;
  late PreviewSourceUris _uris;
  late PreviewEngine Function() _newEngine;
  PreviewEngine? _engine;
  StreamSubscription<EngineTransportState>? _engineSub;
  int _generation = 0;
  bool _disposed = false;
  bool _quiesced = false;
  bool _wantPlaying = false;
  bool _loaded = false;
  bool _engineReportsPlaying = false;

  /// Set when an OS interruption paused playing preview; any later command
  /// clears it, so the user's choice is never undone.
  bool _resumeAfterInterruption = false;

  @override
  PreviewState build() {
    _focus = ref.read(audioFocusProvider);
    _uris = ref.read(previewSourceUrisProvider);
    _newEngine = ref.read(previewEngineFactoryProvider);
    _focus.bind(AudioOutput.preview, this);
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _wantPlaying = false;
      _disposeEngine();
      _focus.release(AudioOutput.preview, this);
    });
    return const PreviewState();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _set(PreviewSource? source, PreviewStatus status, [Duration? duration]) =>
      state = PreviewState(source: source, status: status, duration: duration);

  void _disposeEngine() {
    unawaited(_engineSub?.cancel());
    _engineSub = null;
    final engine = _engine;
    _engine = null;
    _loaded = false;
    _engineReportsPlaying = false;
    if (engine != null) {
      unawaited(engine.stop());
      engine.dispose();
    }
  }

  PreviewEngine _ensureEngine() {
    final existing = _engine;
    if (existing != null) return existing;
    final engine = _engine = _newEngine();
    _engineSub = engine.transportStates.listen((report) {
      if (_disposed) return;
      _engineReportsPlaying = report.playing;
      // A stale completed report (an earlier track's end) is ignored unless
      // this preview is playing.
      if (report.processingState == EngineProcessingState.completed &&
          state.status == PreviewStatus.playing) {
        _wantPlaying = false;
        _set(state.source, PreviewStatus.completed, state.duration);
      }
    });
    return engine;
  }

  Future<void> play(PreviewSource source) async {
    if (_quiesced) return;
    _resumeAfterInterruption = false;
    final generation = ++_generation;
    _wantPlaying = true;
    _loaded = false;
    unawaited(_engine?.stop());
    _set(source, PreviewStatus.loading);
    final resolution = await _uris.resolve(source);
    if (!_current(generation)) return;
    final refusal = resolution.refusal;
    if (refusal != null) {
      _set(source, refusal);
      return;
    }
    final granted = await _focus.acquire(AudioOutput.preview);
    if (!_current(generation)) return;
    if (!granted) {
      _set(source, PreviewStatus.failed);
      return;
    }
    final engine = _ensureEngine();
    Duration? duration;
    try {
      duration = await engine.load(resolution.uri!);
    } catch (_) {
      if (_current(generation)) _set(source, PreviewStatus.failed);
      return;
    }
    if (!_current(generation)) return;
    _loaded = true;
    if (!_wantPlaying || _focus.holder != AudioOutput.preview) {
      _set(source, state.status, duration);
      return;
    }
    unawaited(engine.play());
    _set(source, PreviewStatus.playing, duration);
  }

  Future<void> pause() async {
    if (_quiesced) return;
    _resumeAfterInterruption = false;
    _wantPlaying = false;
    unawaited(_engine?.pause());
    final status = state.status;
    if (status == PreviewStatus.playing || status == PreviewStatus.loading) {
      _set(state.source, PreviewStatus.paused, state.duration);
    }
  }

  Future<void> resume() async {
    if (_quiesced) return;
    _resumeAfterInterruption = false;
    final engine = _engine;
    final status = state.status;
    if (engine != null &&
        _loaded &&
        status == PreviewStatus.paused &&
        _focus.holder == AudioOutput.preview) {
      _wantPlaying = true;
      unawaited(engine.play());
      _set(state.source, PreviewStatus.playing, state.duration);
      return;
    }
    final source = state.source;
    if (source != null) await play(source);
  }

  /// SC-15 reset participant: closes admission synchronously, cancels
  /// pending loads, stops and disposes the engine and releases the output.
  /// Terminal and idempotent.
  Future<void> quiesce() async {
    _quiesced = true;
    _generation++;
    _wantPlaying = false;
    _resumeAfterInterruption = false;
    _disposeEngine();
    _focus.giveUp(AudioOutput.preview);
    if (!_disposed) state = const PreviewState();
  }

  /// Stops, disposes the engine and gives the output up. The library is left
  /// paused for the user to resume. The stop and the focus hand-back are
  /// immediate; only the state write is deferred a microtask, because a
  /// widget's dispose may call this and Riverpod forbids provider writes
  /// during the build/finalize pass. A play started meanwhile owns the state.
  Future<void> close() async {
    if (_quiesced) return;
    _resumeAfterInterruption = false;
    final generation = ++_generation;
    _wantPlaying = false;
    _disposeEngine();
    _focus.giveUp(AudioOutput.preview);
    await Future<void>.microtask(() {});
    if (_current(generation)) state = const PreviewState();
  }

  @override
  Future<void> relinquishFocus() async {
    if (_quiesced) return;
    _resumeAfterInterruption = false;
    _generation++;
    _wantPlaying = false;
    final status = state.status;
    if (!_disposed &&
        (status == PreviewStatus.loading ||
            status == PreviewStatus.playing ||
            status == PreviewStatus.paused)) {
      _set(state.source, PreviewStatus.idle, state.duration);
    }
    _loaded = false;
    final engine = _engine;
    if (engine == null) return;
    unawaited(engine.stop());
    if (!_engineReportsPlaying) return;
    await engine.transportStates.firstWhere((report) => !report.playing,
        orElse: () => const EngineTransportState(
            false, EngineProcessingState.idle));
  }

  @override
  void onInterruptionBegan() {
    if (_quiesced) return;
    if (!_wantPlaying) return;
    unawaited(pause());
    _resumeAfterInterruption = true;
  }

  @override
  void onInterruptionEnded({required bool shouldResume}) {
    if (_quiesced) return;
    final resume = _resumeAfterInterruption && shouldResume;
    _resumeAfterInterruption = false;
    if (resume) unawaited(this.resume());
  }

  @override
  void onBecameNoisy() {
    if (_quiesced) return;
    if (_wantPlaying) unawaited(pause());
    _resumeAfterInterruption = false;
  }
}
