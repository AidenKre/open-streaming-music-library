import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/settings_service.dart';

/// Queue warm (SC-27 observer): asks the backend to pre-encode ahead of the
/// playing position whenever the session, position, queue or stream quality
/// changes. Debounced inside [QueueWarmService]. Never mutates playback.
class QueueWarmListener {
  QueueWarmListener(this._warm);
  final QueueWarmService _warm;
  ({int sessionId, int position, int queueVersion, String quality})? _last;

  void update(AudioState state, String quality) {
    final sessionId = state.queue.sessionId;
    if (sessionId == null) {
      _last = null;
      return;
    }
    final next = (
      sessionId: sessionId,
      position: state.queue.currentPlayPosition,
      queueVersion: state.queue.queueVersion,
      quality: quality,
    );
    if (next == _last) return;
    _last = next;
    _warm.scheduleWarm(
      sessionId: sessionId,
      currentPlayPosition: next.position,
      quality: quality,
    );
  }
}

/// Kept alive by `playbackWiringProvider` once the session is ready.
final queueWarmListenerProvider = Provider<QueueWarmListener>((ref) {
  final listener = QueueWarmListener(ref.read(queueWarmServiceProvider));
  void update() =>
      listener.update(ref.read(queuePlayerProvider), ref.read(streamQualityProvider));
  ref.listen<AudioState>(queuePlayerProvider, (_, _) => update(),
      fireImmediately: true);
  ref.listen<String>(streamQualityProvider, (_, _) => update());
  return listener;
});
