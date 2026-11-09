import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_state.dart';

final queuePlayerProvider = NotifierProvider<QueuePlayer, AudioState>(
  QueuePlayer.new,
);

final currentTrackProvider = Provider<TrackUI?>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.playback.currentTrack)),
);

final audioPositionProvider = Provider<Duration>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.playback.position)),
);

/// Best known duration; null = unknown (never zero).
final audioDurationProvider = Provider<Duration?>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.playback.duration)),
);

final audioStatusProvider = Provider<PlayerStatus>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.playback.status)),
);

/// Desired transport: what the play/pause control shows and toggles.
final audioPlayWhenReadyProvider = Provider<bool>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.playback.playWhenReady)),
);

final audioVolumeProvider = Provider<double>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.playback.volume)),
);

final shuffleProvider = Provider<bool>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.shuffle.shuffleOn)),
);

final repeatModeProvider = Provider<QueueRepeatMode>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.queue.repeatMode)),
);

final queueCurrentPlayPositionProvider = Provider<int>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.queue.currentPlayPosition)),
);

final queueCurrentItemIdProvider = Provider<int?>(
  (ref) => ref.watch(queuePlayerProvider.select((s) => s.queue.currentItemId)),
);
