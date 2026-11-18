import 'dart:async';

import 'package:frontend/services/uploads/upload_source.dart';

/// An [UploadSource] over chunks held in the test. Each [openRead] replays
/// [chunks] (which the test may replace between reads, to model a file that
/// changed) and records how its stream was listened to and cancelled.
class MemoryUploadSource implements UploadSource {
  MemoryUploadSource(
    this.chunks, {
    this.displayName = 'song.flac',
    int? length,
    this.failAfterChunks,
  }) : length = length ?? chunks.fold<int>(0, (n, c) => n + c.length);

  /// What the next [openRead] yields.
  List<List<int>> chunks;

  @override
  final String displayName;

  @override
  final int length;

  /// When set, the stream fails with [UploadSourceUnavailable] after this
  /// many chunks (a file that disappeared mid-read).
  int? failAfterChunks;

  /// Streams opened so far.
  int opens = 0;

  /// Streams whose subscription was cancelled before they finished.
  int cancels = 0;

  /// Chunks handed to a listener, over all opens.
  int chunksEmitted = 0;

  /// Open streams not yet done or cancelled.
  int get openStreams => opens - _closed;
  int _closed = 0;

  @override
  Stream<List<int>> openRead() {
    opens++;
    final snapshot = List<List<int>>.of(chunks);
    final failAt = failAfterChunks;
    late StreamController<List<int>> controller;
    var index = 0;
    var done = false;
    void close() {
      if (done) return;
      done = true;
      _closed++;
    }

    // One chunk per event-loop turn, like a file read: a listener can pause
    // or cancel between chunks.
    var scheduled = false;
    late void Function() schedule;
    void pump() {
      scheduled = false;
      if (controller.isPaused || done) return;
      if (failAt != null && index == failAt) {
        controller.addError(const UploadSourceUnavailable());
        close();
        controller.close();
        return;
      }
      if (index >= snapshot.length) {
        close();
        controller.close();
        return;
      }
      chunksEmitted++;
      controller.add(snapshot[index++]);
      schedule();
    }

    schedule = () {
      if (scheduled) return;
      scheduled = true;
      Future<void>(pump);
    };

    controller = StreamController<List<int>>(
      onListen: schedule,
      onResume: schedule,
      onCancel: () {
        if (!done) cancels++;
        close();
      },
    );
    return controller.stream;
  }
}
