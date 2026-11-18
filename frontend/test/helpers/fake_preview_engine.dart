import 'dart:async';

import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/preview_engine.dart';

/// A preview engine whose loads the test completes, recording commands.
class FakePreviewEngine implements PreviewEngine {
  final loads = <Uri>[];
  final _pending = <Completer<Duration?>>[];
  final _transport = StreamController<EngineTransportState>.broadcast();
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  bool disposed = false;

  /// Completes the oldest pending load.
  void finishLoad(Duration? duration) =>
      _pending.removeAt(0).complete(duration);

  void failLoad() =>
      _pending.removeAt(0).completeError(const PreviewLoadFailed());

  EngineTransportState? _last;

  void emit(EngineTransportState state) {
    _last = state;
    _transport.add(state);
  }

  @override
  Future<Duration?> load(Uri uri) {
    loads.add(uri);
    final load = Completer<Duration?>();
    _pending.add(load);
    return load.future;
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  /// Like just_audio 0.10.5 (U19-A-06): stopping a finished player reports
  /// `(false, completed)` before it goes idle.
  @override
  Future<void> stop() async {
    stops++;
    if (_last?.processingState == EngineProcessingState.completed) {
      emit(const EngineTransportState(false, EngineProcessingState.completed));
    }
  }

  @override
  Stream<EngineTransportState> get transportStates => _transport.stream;

  @override
  void dispose() => disposed = true;
}
