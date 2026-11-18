import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/ui/library_actions.dart';

/// The collection detail page's input (SC-26, Phase 6 §5): Play and Shuffle
/// for one album or artist, with the busy state that blocks duplicate
/// submits and the short explanation of an action that didn't start.
abstract interface class CollectionDetailControls implements Listenable {
  /// A Play or Shuffle is in flight; further submits are ignored.
  bool get busy;

  /// A short user-facing explanation of the last action that did not start,
  /// or null.
  String? get message;

  /// Whether [retry] would re-run the action [message] explains.
  bool get canRetry;

  Future<void> play();

  Future<void> shuffle();

  /// Re-runs the action that produced [message].
  Future<void> retry();
}

/// Busy state lives in the collection detail page's controller; it prevents
/// accidental duplicate submits, failures clear busy in `finally`, and a
/// message keeps an actionable retry (Phase 6 §5). It only maps outcomes to
/// short text and holds no availability rule (SC-26).
class CollectionDetailController extends ChangeNotifier
    implements CollectionDetailControls {
  CollectionDetailController(Ref ref, this._scope)
      : _actions = ref.read(libraryActionsProvider);

  final LibraryActionControls _actions;
  final LibraryScope _scope;

  bool _busy = false;
  bool _disposed = false;
  String? _message;
  Future<PlaybackOutcome> Function()? _lastAction;

  @override
  bool get busy => _busy;

  @override
  String? get message => _message;

  @override
  bool get canRetry => _message != null;

  @override
  Future<void> play() => _run(() => _actions.play(_scope));

  @override
  Future<void> shuffle() => _run(() => _actions.shuffle(_scope));

  @override
  Future<void> retry() {
    final action = _message == null ? null : _lastAction;
    return action == null ? Future.value() : _run(action);
  }

  Future<void> _run(Future<PlaybackOutcome> Function() action) async {
    if (_busy || _disposed) return;
    _busy = true;
    _message = null;
    notifyListeners();
    String? message;
    try {
      message = messageFor(await action());
    } catch (error, stack) {
      developer.log('Collection playback failed',
          error: error, stackTrace: stack);
      message = messageFor(Failed(error));
    } finally {
      _busy = false;
    }
    _message = message;
    if (message != null) _lastAction = action;
    if (!_disposed) notifyListeners();
  }

  static String? messageFor(PlaybackOutcome outcome) =>
      playbackOutcomeMessage(outcome);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final collectionDetailControllerProvider = Provider.autoDispose
    .family<CollectionDetailControls, LibraryScope>((ref, scope) {
  final controller = CollectionDetailController(ref, scope);
  ref.onDispose(controller.dispose);
  return controller;
});
