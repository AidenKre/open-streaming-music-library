import 'dart:async';

/// What the OS audio session reported, free of plugin types.
enum AudioInterruptionKind { pause, duck, unknown }

sealed class AudioSessionEvent {
  const AudioSessionEvent();
}

class AudioInterruptionBegan extends AudioSessionEvent {
  const AudioInterruptionBegan(this.kind);
  final AudioInterruptionKind kind;
}

class AudioInterruptionEnded extends AudioSessionEvent {
  const AudioInterruptionEnded(this.kind);
  final AudioInterruptionKind kind;
}

/// Headphones unplugged / output became noisy.
class AudioBecameNoisy extends AudioSessionEvent {
  const AudioBecameNoisy();
}

/// The OS audio session as the model sees it.
abstract interface class AudioSessionPort {
  Stream<AudioSessionEvent> get events;
}

/// An audio output that can own focus. 5B.0c has one; the first of
/// Phases 7/8 adds the preview player with acknowledged transfer.
enum AudioOutput { queue }

/// The owner's command path for session events (SC-27 invariant 5/10).
abstract interface class AudioFocusOwner {
  /// Pause if playing, remembering to resume when the interruption ends.
  void onInterruptionBegan();

  /// [shouldResume]: the OS says playback may resume.
  void onInterruptionEnded({required bool shouldResume});

  /// Output became noisy (headphones unplugged): pause.
  void onBecameNoisy();
}

/// Exclusive audio output ownership (SC-27 invariant 5). Audible output
/// requires current ownership: the engine's single play() asks [beforePlay].
/// OS interruption and noisy-device events are routed into the owner's
/// commands (the plugin's own interruption handling stays off). No lock is
/// held: routing only enqueues owner commands, never awaits a lane. Events
/// that arrive with no owner bound are dropped, never buffered. Transfer
/// between owners (with acknowledged relinquishment) arrives with the
/// second owner in Phase 7/8.
class AudioFocus {
  AudioFocus(this._port);
  final AudioSessionPort _port;
  final Map<AudioOutput, AudioFocusOwner> _owners = {};
  StreamSubscription<AudioSessionEvent>? _subscription;
  int _ownershipRevision = 0;

  /// Bumped whenever ownership changes.
  int get ownershipRevision => _ownershipRevision;

  void bind(AudioOutput output, AudioFocusOwner owner) {
    _owners[output] = owner;
    _ownershipRevision++;
    _subscription ??= _port.events.listen(_route);
  }

  /// Releases [output] only if [owner] still holds it.
  void release(AudioOutput output, AudioFocusOwner owner) {
    if (!identical(_owners[output], owner)) return;
    _owners.remove(output);
    _ownershipRevision++;
  }

  /// Whether [output] may produce audio now. With one output, that is
  /// whether it has an owner; transfer between outputs arrives with the
  /// second owner.
  Future<bool> beforePlay(AudioOutput output) async =>
      _owners.containsKey(output);

  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _owners.clear();
  }

  void _route(AudioSessionEvent event) {
    final owner = _owners[AudioOutput.queue];
    if (owner == null) return;
    switch (event) {
      case AudioInterruptionBegan(kind: AudioInterruptionKind.duck):
      case AudioInterruptionEnded(kind: AudioInterruptionKind.duck):
        return; // D27: ducking is handled by the OS for media
      case AudioInterruptionBegan():
        owner.onInterruptionBegan();
      case AudioInterruptionEnded(:final kind):
        owner.onInterruptionEnded(
            shouldResume: kind == AudioInterruptionKind.pause);
      case AudioBecameNoisy():
        owner.onBecameNoisy();
    }
  }
}
