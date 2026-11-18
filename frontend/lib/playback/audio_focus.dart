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

/// An audio output that can own focus: the library queue and (7B.2a) the
/// preview player.
enum AudioOutput { queue, preview }

/// An owner that can be asked to give up the output (7B.2a). The returned
/// future completes once its output is silent (the acknowledgement).
abstract interface class FocusRelinquisher {
  Future<void> relinquishFocus();
}

/// An owner that is told when the output it was asked to give up comes back
/// unused ([AudioFocus.handBack]): it may play again what its relinquish
/// paused.
abstract interface class FocusReturnListener {
  void onFocusReturned();
}

/// The owner's command path for session events (SC-27 invariant 5/10).
abstract interface class AudioFocusOwner {
  /// Pause if playing, remembering to resume when the interruption ends.
  void onInterruptionBegan();

  /// [shouldResume]: the OS says playback may resume.
  void onInterruptionEnded({required bool shouldResume});

  /// Output became noisy (headphones unplugged): pause.
  void onBecameNoisy();
}

/// A transfer of the output from [from] to [to], waiting for [from]'s
/// acknowledgement that it is silent.
class _Transfer {
  _Transfer(this.from, this.to);
  final AudioOutput from;
  final AudioOutput to;
  final Completer<bool> result = Completer<bool>();
  Timer? timer;
}

/// Exclusive audio output ownership (SC-27 invariant 5). Audible output
/// requires current ownership: the engine's single play() asks [beforePlay].
/// OS interruption and noisy-device events are routed into the owner's
/// commands (the plugin's own interruption handling stays off). Events that
/// arrive with no owner bound are dropped, never buffered.
///
/// Two outputs exist: the library queue and the preview player. Focus is
/// transferred, not just requested: [acquire] asks the current holder's owner
/// to relinquish ([FocusRelinquisher]) and grants the output only once the
/// holder acknowledged that it is silent, waiting at most [relinquishBound].
/// No lock is held while waiting: the wait is an identity check of the
/// pending transfer after an await, so the newest request wins (an older
/// pending acquire answers false at once) and a late acknowledgement changes
/// nothing. A refused or failed relinquish leaves the output with its holder.
class AudioFocus {
  AudioFocus(this._port, {Timer Function(Duration, void Function())? timer})
      : _timer = timer ?? Timer.new;
  final AudioSessionPort _port;
  final Timer Function(Duration, void Function()) _timer;

  /// How long a transfer waits for the holder's acknowledgement.
  static const relinquishBound = Duration(seconds: 3);

  AudioOutput? _holder;
  _Transfer? _pending;
  final Set<AudioOutput> _yielded = {};
  bool _disposed = false;

  /// The output allowed to produce audio now (null: nobody).
  AudioOutput? get holder => _holder;

  /// Takes the output for [output], after the holder acknowledged that it
  /// stopped. Answers false when refused, superseded or without an owner.
  Future<bool> acquire(AudioOutput output) {
    if (_disposed || !_owners.containsKey(output)) return Future.value(false);
    final pending = _pending;
    if (pending != null && pending.to == output) return pending.result.future;
    if (_holder == output) {
      _supersedePending();
      _grant(output);
      return Future.value(true);
    }
    final from = output == AudioOutput.queue
        ? AudioOutput.preview
        : AudioOutput.queue;
    _supersedePending();
    if (!_owners.containsKey(from)) {
      _grant(output);
      return Future.value(true);
    }
    final transfer = _Transfer(from, output);
    _pending = transfer;
    _yielded.add(from);
    transfer.timer = _timer(relinquishBound, () => _refuse(transfer));
    final owner = _owners[from];
    Future<void> ack;
    try {
      ack = owner is FocusRelinquisher
          ? (owner as FocusRelinquisher).relinquishFocus()
          : Future<void>.value();
    } catch (_) {
      _refuse(transfer);
      return transfer.result.future;
    }
    ack.then((_) => _complete(transfer), onError: (_) => _refuse(transfer));
    return transfer.result.future;
  }

  /// [output] drops the output if it holds it.
  void giveUp(AudioOutput output) {
    if (_pending?.to == output) _supersedePending();
    if (_holder != output) return;
    _holder = null;
  }

  /// [output] returns the output it took, or was still waiting for, without
  /// having used it: the other output holds it again as if the transfer had
  /// never been asked, and its owner is told ([FocusReturnListener]) so that
  /// it can play again what its relinquish paused (an owner that was not
  /// playing holds the output afterwards all the same). Nothing happens when
  /// [output] neither holds nor waits for the output, or is already being
  /// asked to give it up.
  void handBack(AudioOutput output) {
    final other = output == AudioOutput.queue
        ? AudioOutput.preview
        : AudioOutput.queue;
    final pending = _pending;
    if (pending != null && pending.to == output) {
      _supersedePending();
    } else if (pending == null && _holder == output) {
      _holder = _owners.containsKey(other) ? other : null;
      _yielded.remove(other);
    } else {
      return;
    }
    final owner = _owners[other];
    if (owner is FocusReturnListener) {
      (owner as FocusReturnListener).onFocusReturned();
    }
  }

  /// Whether [output] gave the output away and has not held it since.
  bool yieldedBy(AudioOutput output) => _yielded.contains(output);

  final Map<AudioOutput, AudioFocusOwner> _owners = {};
  StreamSubscription<AudioSessionEvent>? _subscription;
  void bind(AudioOutput output, AudioFocusOwner owner) {
    _owners[output] = owner;
    _subscription ??= _port.events.listen(_route);
  }

  /// Releases [output] only if [owner] still holds it. A holder that leaves
  /// frees the output; a transfer waiting on it is granted at once.
  void release(AudioOutput output, AudioFocusOwner owner) {
    if (!identical(_owners[output], owner)) return;
    _owners.remove(output);
    final pending = _pending;
    if (pending != null && pending.to == output) _supersedePending();
    if (_holder == output) {
      _holder = null;
    }
    if (pending != null && identical(_pending, pending) && pending.from == output) {
      _complete(pending);
    }
  }

  /// Whether [output] may produce audio now. False while a transfer away from
  /// it is pending (it is being relinquished); a play while another output
  /// holds takes the output back, that holder stopping first.
  Future<bool> beforePlay(AudioOutput output) async {
    if (!_owners.containsKey(output)) return false;
    if (_pending?.from == output) return false;
    if (_holder == output) return true;
    return acquire(output);
  }

  void dispose() {
    _disposed = true;
    _supersedePending();
    unawaited(_subscription?.cancel());
    _subscription = null;
    _owners.clear();
  }

  void _grant(AudioOutput output) {
    _holder = output;
    _yielded.remove(output);
  }

  void _supersedePending() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    pending.timer?.cancel();
    // The source still holds: it gave nothing away (7-R1-23).
    if (_holder == pending.from) _yielded.remove(pending.from);
    if (!pending.result.isCompleted) pending.result.complete(false);
  }

  void _complete(_Transfer transfer) {
    if (!identical(_pending, transfer)) return;
    _pending = null;
    transfer.timer?.cancel();
    _grant(transfer.to);
    transfer.result.complete(true);
  }

  void _refuse(_Transfer transfer) {
    if (!identical(_pending, transfer)) return;
    _pending = null;
    transfer.timer?.cancel();
    if (_holder == transfer.from) _yielded.remove(transfer.from);
    transfer.result.complete(false);
  }

  void _route(AudioSessionEvent event) {
    // The holder's owner (the queue when nobody holds), plus the pending
    // transfer target's owner; each is called at most once.
    final owners = <AudioFocusOwner>[];
    final primary = _owners[_holder ?? AudioOutput.queue];
    if (primary != null) owners.add(primary);
    final target = _pending == null ? null : _owners[_pending!.to];
    if (target != null && !owners.contains(target)) owners.add(target);
    for (final owner in owners) {
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
}
