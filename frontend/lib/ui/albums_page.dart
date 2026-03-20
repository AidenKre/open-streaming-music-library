import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';

class AlbumsPage extends ConsumerStatefulWidget {
  final int? artistId;
  final VoidCallback? onDisconnect;
  const AlbumsPage({super.key, this.artistId, this.onDisconnect});

  @override
  ConsumerState<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends ConsumerState<AlbumsPage> {
  static const _pageSize = 30;

  final _scrollController = ScrollController();
  List<AlbumUI> _albums = [];
  bool _hasMore = true;
  bool _isLoading = false;
  int _newAlbumCount = 0;
  StreamSubscription<int>? _watchSub;

  List<AlbumOrderParameter> get _orderParams => [
    AlbumOrderParameter(column: 'artist'),
    AlbumOrderParameter(column: 'year', isAscending: false, nullsLast: true),
    AlbumOrderParameter(column: 'is_single_grouping'),
    AlbumOrderParameter(column: 'name', nullsLast: true),
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
          .sync(artistId: widget.artistId, albumId: null),
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

    final useCursor = _hasMore && _albums.isNotEmpty;
    final cursorFilters = useCursor
        ? _buildCursorFromLast(_albums.last)
        : <AlbumRowFilterParameter>[];
    final orderBy = useCursor ? _orderParams : <AlbumOrderParameter>[];

    _watchSub = db
        .watchAlbumsCount(
          artistId: widget.artistId,
          orderBy: orderBy,
          cursorFilters: cursorFilters,
        )
        .listen((count) {
          if (!mounted) return;
          final newCount = count - _albums.length;
          if (newCount != _newAlbumCount) {
            setState(() => _newAlbumCount = newCount > 0 ? newCount : 0);
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

    final cursorFilters = _albums.isEmpty
        ? <AlbumRowFilterParameter>[]
        : _buildCursorFromLast(_albums.last);

    final rows = await db.getAlbums(
      artistId: widget.artistId,
      orderBy: _orderParams,
      cursorFilters: cursorFilters,
      limit: _pageSize,
    );

    if (!mounted) return;
    setState(() {
      _albums.addAll(rows.map(AlbumUI.fromQueryRow));
      _hasMore = rows.length == _pageSize;
      _isLoading = false;
    });
    _startWatching();
  }

  List<AlbumRowFilterParameter> _buildCursorFromLast(AlbumUI last) {
    return [
      AlbumRowFilterParameter(column: 'artist', value: last.artist),
      AlbumRowFilterParameter(column: 'year', value: last.year),
      AlbumRowFilterParameter(
        column: 'is_single_grouping',
        value: last.isSingleGrouping ? 1 : 0,
      ),
      AlbumRowFilterParameter(column: 'name', value: last.name),
    ];
  }

  void _refresh() {
    _watchSub?.cancel();
    setState(() {
      _albums = [];
      _hasMore = true;
      _newAlbumCount = 0;
    });
    _loadMore();
  }

  void _onAlbumTap(AlbumUI album) {
    final String appBarTitle;

    if (album.isSingleGrouping) {
      appBarTitle = '${album.artist ?? "Unknown Artist"} - Singles';
    } else {
      appBarTitle = album.name ?? 'Unknown Album';
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(appBarTitle)),
          body: TracksPage(artistId: album.artistId, albumId: album.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        if (_newAlbumCount > 0)
          MaterialBanner(
            content: Text('$_newAlbumCount new albums available'),
            actions: [
              TextButton(onPressed: _refresh, child: const Text('Refresh')),
            ],
          ),
        Expanded(
          child: GridView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              childAspectRatio: 0.75,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _albums.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _albums.length) {
                return const Center(child: CircularProgressIndicator());
              }
              final album = _albums[index];
              return AlbumCard(
                album: album,
                onTap: () => _onAlbumTap(album),
              );
            },
          ),
        ),
      ],
    );

    if (widget.onDisconnect != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('OSML'),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Disconnect',
              onPressed: widget.onDisconnect,
            ),
          ],
        ),
        body: body,
      );
    }
    return body;
  }
}
