import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/audio_provider.dart';
import 'package:frontend/ui/widgets/mini_player.dart';

class FullPlayer extends ConsumerWidget {
  const FullPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final status = ref.watch(audioStatusProvider);
    final position = ref.watch(audioPositionProvider);
    final duration = ref.watch(audioDurationProvider);
    final volume = ref.watch(audioVolumeProvider);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (track == null) {
      return const SizedBox.shrink();
    }

    final sliderMax =
        duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 32),
            // Album art placeholder
            AspectRatio(
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
                  icon: const Icon(Icons.skip_previous),
                  iconSize: 36,
                  onPressed: null,
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
                  onPressed: null,
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
      ),
    );
  }
}
