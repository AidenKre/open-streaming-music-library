import 'package:frontend/playback/playback_engine.dart';

/// A preview load failed (or a stop interrupted it). Carries no message:
/// a plugin error can quote the URL and its media token.
class PreviewLoadFailed implements Exception {
  const PreviewLoadFailed();

  @override
  String toString() => 'PreviewLoadFailed';
}

/// The preview player's own engine (7B.2a, SC-27): one source at a time,
/// no queue, no observations, no history. Its just_audio adapter is built
/// with `handleInterruptions: false`; interruptions reach the preview player
/// through `AudioFocus`. No plugin types cross this boundary.
abstract interface class PreviewEngine {
  /// Loads [uri]; completes with its duration (null = unknown) once ready.
  /// Throws [PreviewLoadFailed] on failure or when a stop interrupts it.
  Future<Duration?> load(Uri uri);

  /// Returns once issued, never awaiting playback.
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// Desired transport and processing state, as the plugin reports them.
  Stream<EngineTransportState> get transportStates;

  void dispose();
}
