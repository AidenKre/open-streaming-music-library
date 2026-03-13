import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_coordinator.dart';
import 'package:frontend/providers/audio/audio_state.dart';

final audioProvider = NotifierProvider<AudioCoordinator, AudioState>(
  AudioCoordinator.new,
);

final currentTrackProvider = Provider<TrackUI?>(
  (ref) => ref.watch(audioProvider.select((s) => s.playback.currentTrack)),
);

final audioPositionProvider = Provider<Duration>(
  (ref) => ref.watch(audioProvider.select((s) => s.playback.position)),
);

final audioDurationProvider = Provider<Duration>(
  (ref) => ref.watch(audioProvider.select((s) => s.playback.duration)),
);

final audioStatusProvider = Provider<PlayerStatus>(
  (ref) => ref.watch(audioProvider.select((s) => s.playback.status)),
);

final audioVolumeProvider = Provider<double>(
  (ref) => ref.watch(audioProvider.select((s) => s.playback.volume)),
);

final shuffleProvider = Provider<bool>(
  (ref) => ref.watch(audioProvider.select((s) => s.shuffle.shuffleOn)),
);

final repeatModeProvider = Provider<QueueRepeatMode>(
  (ref) => ref.watch(audioProvider.select((s) => s.queue.repeatMode)),
);

final upcomingTracksProvider = Provider<List<TrackUI>>(
  (ref) => ref.watch(audioProvider.select((s) => s.queue.upcomingTracks)),
);
