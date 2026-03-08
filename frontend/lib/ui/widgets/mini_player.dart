import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/audio_provider.dart';
import 'package:frontend/ui/widgets/full_player.dart';

String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) return const SizedBox.shrink();

    final status = ref.watch(audioStatusProvider);
    final position = ref.watch(audioPositionProvider);
    final duration = ref.watch(audioDurationProvider);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return GestureDetector(
      onTap: () {
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => const FullPlayer(),
        );
      },
      child: Container(
        color: colors.surfaceContainerHigh,
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(Icons.music_note, color: colors.onPrimaryContainer),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title ?? 'Unknown Title',
                    style: textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [track.artist ?? 'Unknown Artist', track.album]
                        .where((s) => s != null)
                        .join(' — '),
                    style: textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 2,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        formatDuration(position),
                        style: textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: null,
            ),
            IconButton(
              icon: Icon(
                status == PlayerStatus.playing
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
              onPressed: () {
                final notifier = ref.read(audioProvider.notifier);
                if (status == PlayerStatus.playing) {
                  notifier.pause();
                } else {
                  notifier.resume();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: null,
            ),
          ],
        ),
      ),
    );
  }
}
