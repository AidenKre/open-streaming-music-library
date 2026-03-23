import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
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
              // Album art placeholder
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxArtSize,
                  maxHeight: maxArtSize,
                ),
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
                        ref.read(audioProvider.notifier).toggleShuffle(),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    iconSize: 36,
                    onPressed: () =>
                        ref.read(audioProvider.notifier).skipPrevious(),
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
                    onPressed: () =>
                        ref.read(audioProvider.notifier).skipNext(),
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
                        ref.read(audioProvider.notifier).cycleQueueRepeatMode(),
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
                        ref.read(audioProvider.notifier).setVolume(v);
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
    final target = _clampPosition(
      Duration(milliseconds: value.round()),
      ref.read(audioDurationProvider),
    );

    setState(() {
      _isScrubbing = false;
      _scrubPosition = target;
      _pendingSeekPosition = target;
    });

    unawaited(ref.read(audioProvider.notifier).seek(target));
  }

  Duration _clampPosition(Duration position, Duration duration) {
    if (duration <= Duration.zero) {
      return Duration.zero;
    }
    if (position.isNegative) {
      return Duration.zero;
    }
    if (position > duration) {
      return duration;
    }
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
  static const _pageSize = 80;
  static const _initialLeadingCount = 40;
  static const _initialTrailingCount = 60;
  static const _itemExtent = 65.0;

  final _scrollController = ScrollController();
  List<QueueTrackEntry> _tracks = const [];
  int _startPlayPosition = 0;
  int? _sessionId;
  int _queueVersion = -1;
  bool _isInitialLoad = false;
  bool _isViewportReload = false;
  bool _isLoadingBefore = false;
  bool _isLoadingAfter = false;
  bool _hasMoreBefore = false;
  bool _hasMoreAfter = false;
  bool _shouldScrollToCurrent = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _isInitialLoad || _isViewportReload) {
      return;
    }

    final position = _scrollController.position;
    if (position.pixels <= 320) {
      _loadBefore();
    }
    if (position.maxScrollExtent - position.pixels <= 320) {
      _loadAfter();
    }
  }

  void _scheduleReload({
    required int sessionId,
    required int queueVersion,
    required int currentPlayPosition,
    required int totalCount,
  }) {
    final sessionChanged = _sessionId != sessionId;
    final currentOutsideLoadedRange =
        _tracks.isEmpty ||
        currentPlayPosition < _startPlayPosition ||
        currentPlayPosition >= _startPlayPosition + _tracks.length;

    if (sessionChanged || currentOutsideLoadedRange) {
      if (_isInitialLoad) return;
      _sessionId = sessionId;
      _queueVersion = queueVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadInitialPage(
          sessionId: sessionId,
          expectedQueueVersion: queueVersion,
          currentPlayPosition: currentPlayPosition,
          totalCount: totalCount,
        );
      });
      return;
    }

    final queueChanged = _queueVersion != queueVersion;
    if (!queueChanged || _isInitialLoad || _isViewportReload) return;

    _sessionId = sessionId;
    _queueVersion = queueVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reloadVisiblePage(
        sessionId: sessionId,
        expectedQueueVersion: queueVersion,
        totalCount: totalCount,
      );
    });
  }

  Future<void> _loadInitialPage({
    required int sessionId,
    required int expectedQueueVersion,
    required int currentPlayPosition,
    required int totalCount,
  }) async {
    setState(() {
      _isInitialLoad = true;
      _error = null;
    });

    if (totalCount == 0) {
      if (!mounted) return;
      setState(() {
        _tracks = const [];
        _startPlayPosition = 0;
        _hasMoreBefore = false;
        _hasMoreAfter = false;
        _shouldScrollToCurrent = false;
        _isInitialLoad = false;
      });
      return;
    }

    final repo = ref.read(queueRepositoryProvider);
    final start = (currentPlayPosition - _initialLeadingCount).clamp(
      0,
      totalCount - 1,
    );
    final limit = (_initialLeadingCount + _initialTrailingCount + 1).clamp(
      1,
      totalCount - start,
    );

    try {
      final tracks = await repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: start,
        limit: limit,
      );
      if (!mounted ||
          _sessionId != sessionId ||
          _queueVersion != expectedQueueVersion) {
        return;
      }

      setState(() {
        _tracks = tracks;
        _startPlayPosition = start;
        _hasMoreBefore = start > 0;
        _hasMoreAfter = start + tracks.length < totalCount;
        _shouldScrollToCurrent = true;
        _error = null;
        _isInitialLoad = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _isInitialLoad = false;
      });
    }
  }

  Future<void> _reloadVisiblePage({
    required int sessionId,
    required int expectedQueueVersion,
    required int totalCount,
  }) async {
    if (_tracks.isEmpty) {
      final currentPlayPosition = ref.read(queueCurrentPlayPositionProvider);
      await _loadInitialPage(
        sessionId: sessionId,
        expectedQueueVersion: expectedQueueVersion,
        currentPlayPosition: currentPlayPosition,
        totalCount: totalCount,
      );
      return;
    }

    setState(() {
      _isViewportReload = true;
      _error = null;
    });

    final repo = ref.read(queueRepositoryProvider);
    final previousOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final anchorLocalIndex = _tracks.isEmpty
        ? 0
        : ((previousOffset / _itemExtent).floor()).clamp(0, _tracks.length - 1);
    final anchorItemId = _tracks[anchorLocalIndex].itemId;
    final anchorOffsetWithinItem =
        previousOffset - (anchorLocalIndex * _itemExtent);
    final desiredLimit = totalCount < _tracks.length
        ? totalCount
        : _tracks.length;

    try {
      final anchorEntry = await repo.getPlaybackEntryForItem(
        sessionId,
        anchorItemId,
      );
      if (!mounted ||
          _sessionId != sessionId ||
          _queueVersion != expectedQueueVersion) {
        return;
      }

      final maxStart = totalCount > desiredLimit
          ? totalCount - desiredLimit
          : 0;
      final start = anchorEntry == null
          ? _startPlayPosition.clamp(0, maxStart)
          : (anchorEntry.playPosition - anchorLocalIndex).clamp(0, maxStart);

      final tracks = desiredLimit <= 0
          ? const <QueueTrackEntry>[]
          : await repo.getSessionTracksPage(
              sessionId,
              startPlayPosition: start,
              limit: desiredLimit,
            );
      if (!mounted ||
          _sessionId != sessionId ||
          _queueVersion != expectedQueueVersion) {
        return;
      }

      setState(() {
        _tracks = tracks;
        _startPlayPosition = start;
        _hasMoreBefore = start > 0;
        _hasMoreAfter = start + tracks.length < totalCount;
        _shouldScrollToCurrent = false;
        _error = null;
        _isViewportReload = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;

        final newAnchorIndex = tracks.indexWhere(
          (entry) => entry.itemId == anchorItemId,
        );
        final rawOffset = newAnchorIndex == -1
            ? previousOffset
            : (newAnchorIndex * _itemExtent) + anchorOffsetWithinItem;
        final maxScrollExtent = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(rawOffset.clamp(0.0, maxScrollExtent));
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _isViewportReload = false;
      });
    }
  }

  Future<void> _loadBefore() async {
    if (_isLoadingBefore || !_hasMoreBefore) return;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final expectedQueueVersion = _queueVersion;

    final currentTotalCount = ref.read(
      audioProvider.select((s) => s.queue.totalCount),
    );
    final fetchStart = (_startPlayPosition - _pageSize).clamp(
      0,
      _startPlayPosition,
    );
    final limit = _startPlayPosition - fetchStart;
    if (limit <= 0) {
      setState(() => _hasMoreBefore = false);
      return;
    }

    setState(() => _isLoadingBefore = true);
    final repo = ref.read(queueRepositoryProvider);
    final previousOffset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;

    try {
      final tracks = await repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: fetchStart,
        limit: limit,
      );
      if (!mounted ||
          _sessionId != sessionId ||
          _queueVersion != expectedQueueVersion) {
        return;
      }

      setState(() {
        _tracks = [...tracks, ..._tracks];
        _startPlayPosition = fetchStart;
        _hasMoreBefore = fetchStart > 0;
        _hasMoreAfter = _startPlayPosition + _tracks.length < currentTotalCount;
        _isLoadingBefore = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(
          previousOffset + (tracks.length * _itemExtent),
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _isLoadingBefore = false;
      });
    }
  }

  Future<void> _loadAfter() async {
    if (_isLoadingAfter || !_hasMoreAfter) return;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final expectedQueueVersion = _queueVersion;

    final totalCount = ref.read(
      audioProvider.select((s) => s.queue.totalCount),
    );
    final fetchStart = _startPlayPosition + _tracks.length;
    final remaining = totalCount - fetchStart;
    if (remaining <= 0) {
      setState(() => _hasMoreAfter = false);
      return;
    }
    final limit = remaining < _pageSize ? remaining : _pageSize;

    setState(() => _isLoadingAfter = true);
    final repo = ref.read(queueRepositoryProvider);

    try {
      final tracks = await repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: fetchStart,
        limit: limit,
      );
      if (!mounted ||
          _sessionId != sessionId ||
          _queueVersion != expectedQueueVersion) {
        return;
      }

      setState(() {
        _tracks = [..._tracks, ...tracks];
        _hasMoreBefore = _startPlayPosition > 0;
        _hasMoreAfter = _startPlayPosition + _tracks.length < totalCount;
        _isLoadingAfter = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _isLoadingAfter = false;
      });
    }
  }

  void _scrollToCurrentTrack(int currentPlayPosition) {
    if (!_shouldScrollToCurrent) return;
    final localIndex = currentPlayPosition - _startPlayPosition;
    if (localIndex < 0 || localIndex >= _tracks.length) return;

    _shouldScrollToCurrent = false;
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
    _scrollToCurrentTrack(currentPlayPosition);

    if (_isInitialLoad && _tracks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _tracks.isEmpty) {
      return Center(
        child: Text(
          'Error loading queue',
          style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: _tracks.length,
      itemBuilder: (context, index) {
        final entry = _tracks[index];
        final isCurrent = entry.itemId == currentItemId;
        final isPast = entry.playPosition < currentPlayPosition;
        final showQueueTypeBoundary = _shouldShowQueueTypeBoundary(
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
              isDimmed: isPast,
              onTap: () =>
                  ref.read(audioProvider.notifier).skipToTrack(entry.itemId),
              trailing: !isCurrent
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => ref
                          .read(audioProvider.notifier)
                          .removeFromQueue(entry.itemId),
                    )
                  : null,
            ),
          ],
        );
      },
    );
  }

  bool _shouldShowQueueTypeBoundary(int index, int currentPlayPosition) {
    if (index <= 0) return false;

    final entry = _tracks[index];
    final previous = _tracks[index - 1];
    if (entry.playPosition < currentPlayPosition ||
        previous.playPosition < currentPlayPosition) {
      return false;
    }

    return entry.queueType != previous.queueType;
  }
}
