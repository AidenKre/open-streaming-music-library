import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A minimal FIFO async mutex (we only need this one place, and `synchronized`
/// is just a transitive dep). Serializes the outbox **flush** against the
/// `/changes` **pull** so a pull's blind full-row upsert can never clobber an
/// edit that is mid-flush, and vice versa.
class AsyncMutex {
  Future<void> _tail = Future.value();

  /// Runs [action] once all previously-queued actions have finished. The
  /// returned future completes with [action]'s result (or error). The internal
  /// chain never propagates errors, so one failed action can't wedge the lock.
  Future<T> run<T>(Future<T> Function() action) {
    final release = Completer<void>();
    final previous = _tail;
    _tail = release.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        release.complete();
      }
    });
  }
}

/// Shared instance coordinating flush vs pull across the app.
final editSyncMutexProvider = Provider<AsyncMutex>((ref) => AsyncMutex());
