import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:frontend/ui/widgets/queue_list_controller.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
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

    return SafeArea(
      child: Column(
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 16),
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
            child: _showQueue ? const _QueueView() : const _NowPlayingView(),
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

class _NowPlayingView extends ConsumerStatefulWidget {
  const _NowPlayingView();

  @override
  ConsumerState<_NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends ConsumerState<_NowPlayingView> {
  bool _isScrubbing = false;
  Duration? _scrubPosition;
  Duration? _pendingSeekPosition;

  @override
  Widget build(BuildContext context) {
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

    _clearPendingSeekIfApplied(position);

    final displayedPosition = _clampPosition(
      _isScrubbing
          ? (_scrubPosition ?? position)
          : (_pendingSeekPosition ?? position),
      duration,
    );
    final sliderMax = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final sliderValue = duration.inMilliseconds > 0
        ? displayedPosition.inMilliseconds
              .toDouble()
              .clamp(0.0, sliderMax)
              .toDouble()
        : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Cap album art so it never exceeds 45% of available height or 360px
        final maxArtSize = (constraints.maxHeight * 0.45).clamp(0.0, 360.0);

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxArtSize,
                  maxHeight: maxArtSize,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: CoverArtImage(
                    hasAlbumArt: track.hasAlbumArt,
                    coverArtId: track.coverArtId,
                    borderRadius: BorderRadius.circular(12),
                    fallback: Container(
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
                [
                  track.artist ?? 'Unknown Artist',
                  track.album,
                ].where((s) => s != null).join(' — '),
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              // Seek slider
              Slider(
                key: const Key('now_playing_seek_slider'),
                value: sliderValue,
                max: sliderMax,
                onChangeStart: duration.inMilliseconds > 0
                    ? _handleSeekStart
                    : null,
                onChanged: duration.inMilliseconds > 0
                    ? _handleSeekChanged
                    : null,
                onChangeEnd: duration.inMilliseconds > 0
                    ? _handleSeekEnd
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      formatDuration(displayedPosition),
                      key: const Key('now_playing_elapsed'),
                      style: textTheme.bodySmall,
                    ),
                    Text(
                      formatDuration(duration),
                      key: const Key('now_playing_duration'),
                      style: textTheme.bodySmall,
                    ),
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
                    onPressed: () =>
                        ref.read(playerControlsProvider).toggleShuffle(),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    iconSize: 36,
                    onPressed: () =>
                        ref.read(playerControlsProvider).skipPrevious(),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: Icon(
                      status == PlayerStatus.playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                    ),
                    iconSize: 48,
                    // The model decides play vs pause when it runs.
                    onPressed: () =>
                        ref.read(playerControlsProvider).togglePlayPause(),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    iconSize: 36,
                    onPressed: () =>
                        ref.read(playerControlsProvider).skipNext(),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(
                      repeatMode == QueueRepeatMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                      color: repeatMode != QueueRepeatMode.off
                          ? colors.primary
                          : null,
                    ),
                    iconSize: 24,
                    onPressed: () =>
                        ref.read(playerControlsProvider).cycleRepeat(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Volume slider
              Row(
                children: [
                  Icon(
                    Icons.volume_down,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                  Expanded(
                    child: Slider(
                      value: volume,
                      onChanged: (v) {
                        ref.read(playerControlsProvider).setVolume(v);
                      },
                    ),
                  ),
                  Icon(
                    Icons.volume_up,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleSeekStart(double value) {
    setState(() {
      _isScrubbing = true;
      _scrubPosition = Duration(milliseconds: value.round());
      _pendingSeekPosition = null;
    });
  }

  void _handleSeekChanged(double value) {
    setState(() {
      _isScrubbing = true;
      _scrubPosition = Duration(milliseconds: value.round());
    });
  }

  void _handleSeekEnd(double value) {
    // The model clamps the seek; the view only keeps the drag position.
    final target = Duration(milliseconds: value.round());

    setState(() {
      _isScrubbing = false;
      _scrubPosition = target;
      _pendingSeekPosition = target;
    });

    unawaited(ref.read(playerControlsProvider).seek(target));
  }

  /// Display bound only (the seek command is clamped by the model). An
  /// unknown duration (zero today) bounds nothing: show the real position.
  Duration _clampPosition(Duration position, Duration duration) {
    if (position.isNegative) return Duration.zero;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  void _clearPendingSeekIfApplied(Duration livePosition) {
    final pendingSeekPosition = _pendingSeekPosition;
    if (_isScrubbing || pendingSeekPosition == null) {
      return;
    }
    if ((livePosition - pendingSeekPosition).inMilliseconds.abs() > 1500) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingSeekPosition != pendingSeekPosition) {
        return;
      }
      setState(() {
        _pendingSeekPosition = null;
      });
    });
  }
}

class _QueueView extends ConsumerStatefulWidget {
  const _QueueView();

  @override
  ConsumerState<_QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends ConsumerState<_QueueView> {
  static const _itemExtent = 65.0;

  final _scrollController = ScrollController();
  // Paging state and row inputs live in the controller (SC-27); this view
  // keeps only scroll geometry.
  // Created eagerly: dispose must never be its first use (an empty queue
  // never touches it in build).
  late final QueueListControls _list;

  @override
  void initState() {
    super.initState();
    _list = ref.read(queueListControllerFactoryProvider)()
      ..addListener(_onListChanged);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _list.removeListener(_onListChanged);
    _list.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onListChanged() {
    if (mounted) setState(() {});
  }

  int get _totalCount =>
      ref.read(audioProvider.select((s) => s.queue.totalCount));

  void _onScroll() {
    if (!_scrollController.hasClients ||
        _list.isInitialLoad ||
        _list.isViewportReload) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels <= 320) _loadBefore();
    if (position.maxScrollExtent - position.pixels <= 320) {
      _list.loadAfter(totalCount: _totalCount);
    }
  }

  Future<void> _loadBefore() async {
    final previousOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final prepended = await _list.loadBefore(totalCount: _totalCount);
    if (prepended == 0 || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(previousOffset + (prepended * _itemExtent));
    });
  }

  void _scheduleReload({
    required int sessionId,
    required int queueVersion,
    required int currentPlayPosition,
    required int totalCount,
  }) {
    switch (_list.plan(
      sessionId: sessionId,
      queueVersion: queueVersion,
      currentPlayPosition: currentPlayPosition,
      totalCount: totalCount,
    )) {
      case QueueReloadKind.none:
        return;
      case QueueReloadKind.initial:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _list.loadInitial(
            sessionId: sessionId,
            expectedQueueVersion: queueVersion,
            currentPlayPosition: currentPlayPosition,
            totalCount: totalCount,
          );
        });
      case QueueReloadKind.visible:
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final rowCount = _list.rows.length;
          final previousOffset = _scrollController.hasClients
              ? _scrollController.offset
              : 0.0;
          final anchorLocalIndex = rowCount == 0
              ? 0
              : (previousOffset / _itemExtent).floor().clamp(0, rowCount - 1);
          final anchorOffsetWithinItem =
              previousOffset - (anchorLocalIndex * _itemExtent);
          final newAnchorIndex = await _list.reloadVisible(
            sessionId: sessionId,
            expectedQueueVersion: queueVersion,
            currentPlayPosition: ref.read(queueCurrentPlayPositionProvider),
            totalCount: totalCount,
            anchorLocalIndex: anchorLocalIndex,
          );
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scrollController.hasClients) return;
            final rawOffset = newAnchorIndex == null
                ? previousOffset
                : (newAnchorIndex * _itemExtent) + anchorOffsetWithinItem;
            final maxScrollExtent = _scrollController.position.maxScrollExtent;
            _scrollController.jumpTo(rawOffset.clamp(0.0, maxScrollExtent));
          });
        });
    }
  }

  void _scrollToCurrentTrack(int currentPlayPosition, int rowCount) {
    if (!_list.shouldScrollToCurrent) return;
    final localIndex = currentPlayPosition - _list.startPlayPosition;
    if (localIndex < 0 || localIndex >= rowCount) return;
    _list.scrolledToCurrent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      const itemHeight = _itemExtent;
      final targetOffset =
          (localIndex * itemHeight) -
          (_scrollController.position.viewportDimension / 2) +
          (itemHeight / 2);
      _scrollController.jumpTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(audioProvider.select((s) => s.queue.sessionId));
    final queueVersion = ref.watch(
      audioProvider.select((s) => s.queue.queueVersion),
    );
    final currentPlayPosition = ref.watch(queueCurrentPlayPositionProvider);
    final currentItemId = ref.watch(queueCurrentItemIdProvider);
    final totalCount = ref.watch(
      audioProvider.select((s) => s.queue.totalCount),
    );
    // Observed only so rows re-derive their model availability on a flip.
    ref.watch(offlineModeProvider);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (sessionId == null || totalCount == 0) {
      return Center(
        child: Text(
          'Queue is empty',
          style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      );
    }

    _scheduleReload(
      sessionId: sessionId,
      queueVersion: queueVersion,
      currentPlayPosition: currentPlayPosition,
      totalCount: totalCount,
    );
    final rows = _list.rows;
    _scrollToCurrentTrack(currentPlayPosition, rows.length);

    if (_list.isInitialLoad && rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_list.error != null && rows.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Error loading queue',
                style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
              ),
              TextButton(
                onPressed: () => _list.loadInitial(
                  sessionId: sessionId,
                  expectedQueueVersion: queueVersion,
                  currentPlayPosition: currentPlayPosition,
                  totalCount: totalCount,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final entry = row.entry;
        final isCurrent = entry.itemId == currentItemId;
        final isPast = entry.playPosition < currentPlayPosition;
        // Offline, the player skips streaming-only entries; grey them out so
        // the queue matches what playback will actually do. The row stays
        // tappable (a tap still advances to the next local entry).
        final isUnavailableOffline = !row.availability.canPlay;
        final showQueueTypeBoundary = _shouldShowQueueTypeBoundary(
          rows,
          index,
          currentPlayPosition,
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showQueueTypeBoundary)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Divider(
                  key: const ValueKey('queue_type_separator'),
                  height: 1,
                  thickness: 1,
                  color: colors.outlineVariant,
                ),
              ),
            TrackTile(
              track: entry.track,
              isHighlighted: isCurrent,
              isDimmed: isPast || isUnavailableOffline,
              onTap: () => _list.tapRow(entry.itemId),
              trailing: !isCurrent
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => _list.remove(entry.itemId),
                    )
                  : null,
            ),
          ],
        );
      },
    );
  }

  bool _shouldShowQueueTypeBoundary(
    List<QueueRow> rows,
    int index,
    int currentPlayPosition,
  ) {
    if (index <= 0) return false;

    final entry = rows[index].entry;
    final previous = rows[index - 1].entry;
    if (entry.playPosition < currentPlayPosition ||
        previous.playPosition < currentPlayPosition) {
      return false;
    }

    return entry.queueType != previous.queueType;
  }
}
