import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';

class TracksPage extends ConsumerStatefulWidget {
  final String? artist;
  final String? album;

  const TracksPage({super.key, this.artist, this.album});

  @override
  ConsumerState<TracksPage> createState() => TracksPageState();
}

class TracksPageState extends ConsumerState<TracksPage> {
  static const _pageSize = 50;

  final _scrollController = ScrollController();
  List<TrackUI> _tracks = [];
  bool _hasMore = true;
  bool _isLoading = false;
  int _newTrackCount = 0;
  StreamSubscription<int>? _watchSub;

  List<OrderParameter> get _orderParams => [
    OrderParameter(column: 'artist'),
    OrderParameter(column: 'album'),
    OrderParameter(column: 'disc_number'),
    OrderParameter(column: 'track_number'),
    OrderParameter(column: 'uuid_id'),
  ];

  @override
  void initState() {
    super.initState();
    sync();
    _scrollController.addListener(_onScroll);
    _loadMore();
  }

  void sync() {
    Future.microtask(
      () => ref
          .read(trackSyncProvider.notifier)
          .sync(artist: widget.artist, album: widget.album),
    );
  }

  @override
  void dispose() {
    _watchSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _startWatching() {
    _watchSub?.cancel();

    final db = ref.read(databaseProvider);

    // If all tracks are loaded, or there is no loaded cursor row yet, count
    // everything. Otherwise, count only tracks at or before the last loaded
    // position.
    final useCursor = _hasMore && _tracks.isNotEmpty;
    final cursorFilters = useCursor
        ? _buildCursorFromLast(_tracks.last)
        : <RowFilterParameter>[];
    final orderBy = useCursor ? _orderParams : <OrderParameter>[];

    _watchSub = db
        .watchTrackCount(
          orderBy: orderBy,
          cursorFilters: cursorFilters,
          artist: widget.artist,
          album: widget.album,
        )
        .listen((count) {
          if (!mounted) return;
          final newCount = count - _tracks.length;
          if (newCount != _newTrackCount) {
            setState(() => _newTrackCount = newCount > 0 ? newCount : 0);
          }
        });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    _isLoading = true;

    final db = ref.read(databaseProvider);

    final cursorFilters = _tracks.isEmpty
        ? <RowFilterParameter>[]
        : _buildCursorFromLast(_tracks.last);

    final rows = await db.getTracks(
      orderBy: _orderParams,
      cursorFilters: cursorFilters,
      artist: widget.artist,
      album: widget.album,
      limit: _pageSize,
    );

    if (!mounted) return;
    setState(() {
      _tracks.addAll(rows.map(TrackUI.fromQueryRow));
      _hasMore = rows.length == _pageSize;
      _isLoading = false;
    });
    _startWatching();
  }

  List<RowFilterParameter> _buildCursorFromLast(TrackUI last) {
    return [
      RowFilterParameter(column: 'artist', value: last.artist),
      RowFilterParameter(column: 'album', value: last.album),
      RowFilterParameter(column: 'disc_number', value: last.discNumber),
      RowFilterParameter(column: 'track_number', value: last.trackNumber),
      RowFilterParameter(column: 'uuid_id', value: last.uuidId),
    ];
  }

  void _refresh() {
    _watchSub?.cancel();
    setState(() {
      _tracks = [];
      _hasMore = true;
      _newTrackCount = 0;
    });
    _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_newTrackCount > 0)
          MaterialBanner(
            content: Text('$_newTrackCount new tracks available'),
            actions: [
              TextButton(onPressed: _refresh, child: const Text('Refresh')),
            ],
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            itemCount: _tracks.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _tracks.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final track = _tracks[index];
              return ListTile(
                title: Text(track.title ?? 'Unknown Title'),
                subtitle: Text(
                  [
                    track.artist ?? 'Unknown Artist',
                    track.album,
                  ].where((s) => s != null).join(' — '),
                ),
                trailing: Text(track.formattedDuration),
              );
            },
          ),
        ),
      ],
    );
  }
}
