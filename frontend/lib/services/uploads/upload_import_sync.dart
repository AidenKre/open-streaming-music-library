// The library sync that follows an import (spec §7: "After imported result
// request normal track sync"). It watches the local upload intents, so it
// fires whoever wrote the imported / duplicate state (the status poll, a
// review answer) and whether or not a review page is open. Model code:
// nothing from ui/.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart'
    show uploadIntentStoreProvider;
import 'package:frontend/services/uploads/upload_review_rules.dart'
    show reviewAdvances;

class UploadImportSync {
  UploadImportSync(this._sync);

  final Future<void> Function() _sync;
  final _lastStates = <String, String>{};
  bool _running = false;
  bool _again = false;

  /// Requests a library sync when an item went from a known state into
  /// imported / duplicate. Imports that arrive while a sync runs give one
  /// more sync after it. A sync error is not thrown.
  void onIntents(List<UploadIntentRecord> list) {
    var imported = false;
    for (final intent in list) {
      final before = _lastStates[intent.itemUuid];
      _lastStates[intent.itemUuid] = intent.lastState;
      if (reviewAdvances(before: before, after: intent.lastState)) {
        imported = true;
      }
    }
    if (!imported) return;
    if (_running) {
      _again = true;
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    _running = true;
    try {
      do {
        _again = false;
        try {
          await _sync();
        } catch (_) {
          // The next import asks again.
        }
      } while (_again);
    } finally {
      _running = false;
    }
  }
}

/// The normal track sync, read only when an import asks for it; a fresh pull
/// (waits out a sync already in flight), so an import is never skipped.
final uploadLibrarySyncProvider = Provider<Future<void> Function()>(
  (ref) => () => ref.read(trackSyncProvider.notifier).syncFresh(),
);

/// Fed by a plain store subscription, not by Riverpod listeners: Riverpod
/// pauses a provider nobody listens to, and the manager is listened only
/// while an Uploads page is shown. Imports must sync regardless.
final uploadImportSyncProvider = Provider<UploadImportSync>((ref) {
  final sync = UploadImportSync(ref.read(uploadLibrarySyncProvider));
  // Read while building: the work below runs later, possibly after dispose.
  final store = ref.read(uploadIntentStoreProvider);
  final binding = ref.read(serverBindingRepositoryProvider);
  StreamSubscription<List<UploadIntentRecord>>? sub;
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    unawaited(sub?.cancel());
  });
  unawaited(() async {
    final String? token;
    try {
      token = (await binding.current())?.localBindingId;
    } catch (_) {
      return; // no binding to read (scope closing): nothing to watch
    }
    if (disposed || token == null) return;
    sub = store.watch(token).listen(sync.onIntents);
  }());
  return sync;
});
