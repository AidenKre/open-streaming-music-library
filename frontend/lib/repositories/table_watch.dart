import 'dart:async';

import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';

/// A stream of [read]'s result: [read] runs in one transaction on listen and
/// again whenever a table in [tables] changes.
///
/// The table updates are subscribed before the first read, so a change during
/// it reads again. At most one read is in flight: changes that arrive
/// meanwhile, or while the subscription is paused, only mark the stream dirty
/// and fold into one follow-up read, so the latest state always wins and a
/// burst of writes costs a bounded number of reads. A failed read, or an error
/// of the update stream, reaches the stream as an error; a change that arrived
/// during a failed read reads again at once. Nothing is shared between calls;
/// after cancel no read starts and nothing is emitted.
Stream<T> watchTables<T>(
  AppDatabase db,
  Iterable<ResultSetImplementation> tables,
  Future<T> Function() read,
) {
  late final StreamController<T> controller;
  StreamSubscription<Set<TableUpdate>>? updates;
  var cancelled = false;
  var dirty = false;
  var reading = false;

  Future<void> readOnce() async {
    reading = true;
    dirty = false;
    try {
      final result = await db.transaction(read);
      if (!cancelled) controller.add(result);
    } catch (e, st) {
      if (!cancelled) controller.addError(e, st);
    } finally {
      reading = false;
    }
    if (dirty && !cancelled && !controller.isPaused) unawaited(readOnce());
  }

  void markDirty() {
    dirty = true;
    if (!reading && !cancelled && !controller.isPaused) unawaited(readOnce());
  }

  controller = StreamController<T>(
    onListen: () {
      updates = db
          .tableUpdates(TableUpdateQuery.onAllTables(tables))
          .listen(
            (_) => markDirty(),
            onError: (Object e, StackTrace st) {
              if (!cancelled) controller.addError(e, st);
            },
          );
      markDirty();
    },
    onResume: () {
      if (dirty && !reading && !cancelled) unawaited(readOnce());
    },
    onCancel: () async {
      cancelled = true;
      await updates?.cancel();
      updates = null;
    },
  );
  return controller.stream;
}
