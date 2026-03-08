import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/audio_provider.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

class FullPlayer extends ConsumerStatefulWidget {
  const FullPlayer({super.key});

  @override
  ConsumerState<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends ConsumerState<FullPlayer> {
  bool _showQueue = false;

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(currentTrackProvider);
    final colors = Theme.of(context).colorScheme;

    if (track == null) {
      return const SizedBox.shrink();
    }

    // On iOS, add extra top spacing beyond the safe area for visual balance
    final extraTop = Platform.isIOS ? 12.0 : 0.0;

    return SafeArea(
      child: Column(
        children: [
          // Drag handle
          Padding(
            padding: EdgeInsets.only(top: 16 + extraTop),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Tab row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Row(
              children: [
                _TabButton(
                  label: 'Now Playing',
                  selected: !_showQueue,
                  onTap: () => setState(() => _showQueue = false),
                ),
                const SizedBox(width: 16),
                _TabButton(
                  label: 'Queue',
                  selected: _showQueue,
                  onTap: () => setState(() => _showQueue = true),
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: _showQueue
                ? const _QueueView()
                : const _NowPlayingView(),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: textTheme.titleSmall?.copyWith(
          color: selected ? colors.primary : colors.onSurfaceVariant,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

class _NowPlayingView extends ConsumerWidget {
  const _NowPlayingView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final status = ref.watch(audioStatusProvider);
    final position = ref.watch(audioPositionProvider);
    final duration = ref.watch(audioDurationProvider);
    final volume = ref.watch(audioVolumeProvider);
    final shuffleOn = ref.watch(shuffleProvider);
    final repeatMode = ref.watch(repeatModeProvider);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (track == null) return const SizedBox.shrink();

    final sliderMax =
        duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Cap album art so it never exceeds 45% of available height or 360px
        final maxArtSize = (constraints.maxHeight * 0.45).clamp(0.0, 360.0);

        return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // Album art placeholder
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxArtSize, maxHeight: maxArtSize),
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.music_note,
                  size: 96,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Track info
          Text(
            track.title ?? 'Unknown Title',
            style: textTheme.headlineSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            [track.artist ?? 'Unknown Artist', track.album]
                .where((s) => s != null)
                .join(' — '),
            style: textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 24),
          // Seek slider
          Slider(
            value: position.inMilliseconds.toDouble().clamp(0, sliderMax),
            max: sliderMax,
            onChanged: (v) {
              ref
                  .read(audioProvider.notifier)
                  .seek(Duration(milliseconds: v.toInt()));
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatDuration(position), style: textTheme.bodySmall),
                Text(formatDuration(duration), style: textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Transport controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(
                  Icons.shuffle,
                  color: shuffleOn ? colors.primary : null,
                ),
                iconSize: 24,
                onPressed: () => ref.read(audioProvider.notifier).toggleShuffle(),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 36,
                onPressed: () => ref.read(audioProvider.notifier).skipPrevious(),
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: Icon(
                  status == PlayerStatus.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                ),
                iconSize: 48,
                onPressed: () {
                  final notifier = ref.read(audioProvider.notifier);
                  if (status == PlayerStatus.playing) {
                    notifier.pause();
                  } else {
                    notifier.resume();
                  }
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 36,
                onPressed: () => ref.read(audioProvider.notifier).skipNext(),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                  repeatMode == QueueRepeatMode.one ? Icons.repeat_one : Icons.repeat,
                  color: repeatMode != QueueRepeatMode.off ? colors.primary : null,
                ),
                iconSize: 24,
                onPressed: () => ref.read(audioProvider.notifier).cycleQueueRepeatMode(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Volume slider
          Row(
            children: [
              Icon(Icons.volume_down,
                  size: 20, color: colors.onSurfaceVariant),
              Expanded(
                child: Slider(
                  value: volume,
                  onChanged: (v) {
                    ref.read(audioProvider.notifier).setVolume(v);
                  },
                ),
              ),
              Icon(Icons.volume_up,
                  size: 20, color: colors.onSurfaceVariant),
            ],
          ),
        ],
      ),
    );
      },
    );
  }
}

class _QueueView extends ConsumerWidget {
  const _QueueView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(upcomingTracksProvider);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (upcoming.isEmpty) {
      return Center(
        child: Text(
          'No upcoming tracks',
          style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: upcoming.length,
      itemBuilder: (context, index) {
        final t = upcoming[index];
        return TrackTile(
          track: t,
          onTap: () => ref.read(audioProvider.notifier).skipToTrack(t),
        );
      },
    );
  }
}