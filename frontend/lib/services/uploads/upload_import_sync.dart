// The library sync that follows an import (spec §7: "After imported result
// request normal track sync"). It watches the local upload intents, so it
// fires whoever wrote the imported / duplicate state (the status poll, a
// review answer) and whether or not a review page is open. Model code:
// nothing from ui/.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart'
    show uploadIntentStoreProvider;
import 'package:frontend/services/uploads/upload_review_rules.dart'
    show reviewAdvances;

/// Runs the library sync on the shared background runner. A sync that did
/// not run (false) or threw is tried again on the runner's backoff, at most
/// [retryLimit] times; it never touches an upload row.
class UploadImportSync {
  UploadImportSync(
    this._sync, {
    Timer Function(Duration, void Function()) timer = Timer.new,
    BackoffSchedule? backoff,
  }) : _backoff = backoff ?? BackoffSchedule() {
    _runner = SingleFlightRunner(
      name: 'upload-import-sync',
      pass: _pass,
      backoff: _backoff,
      timer: timer,
    );
  }

  /// At most five tries again after a sync that did not happen (waits of 1,
  /// 2, 4, 8 and 16 s on the default ladder). Then it gives up: the next
  /// import asks again, and the sync every reconnect and app resume runs
  /// brings the tracks.
  static const retryLimit = 5;

  final Future<bool> Function() _sync;
  final BackoffSchedule _backoff;
  late final SingleFlightRunner _runner;
  final _lastStates = <String, String>{};

  /// No further syncs; cancels a pending retry; completes once a sync in
  /// flight has finished.
  Future<void> close() => _runner.quiesce();

  /// Requests a library sync when an item went from a known state into
  /// imported / duplicate. Imports that arrive while a sync runs give one
  /// more sync after it; one during a pending retry is covered by that
  /// retry. A sync error is never thrown to the caller.
  void onIntents(List<UploadIntentRecord> list) {
    var imported = false;
    for (final intent in list) {
      final before = _lastStates[intent.itemUuid];
      _lastStates[intent.itemUuid] = intent.lastState;
      if (reviewAdvances(before: before, after: intent.lastState)) {
        imported = true;
      }
    }
    if (imported) _runner.request('import');
  }

  Future<PassOutcome> _pass(Set<String> reasons) async {
    bool ran;
    try {
      ran = await _sync();
    } catch (_) {
      ran = false;
    }
    if (ran || _backoff.attempts >= retryLimit) return const PassDone();
    return const PassFailed(BackoffReason.transient);
  }
}

/// The normal track sync, read only when an import asks for it; a fresh pull
/// (waits out a sync already in flight), so an import is never skipped.
final uploadLibrarySyncProvider = Provider<Future<bool> Function()>(
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
    unawaited(sync.close());
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
