import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/widgets/artist_card.dart';

class ArtistsPage extends ConsumerStatefulWidget {
  final VoidCallback? onDisconnect;
  const ArtistsPage({super.key, this.onDisconnect});

  @override
  ConsumerState<ArtistsPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistsPage> {
  static const _pageSize = 30;

  final _scrollController = ScrollController();
  List<String> _artists = [];
  bool _hasMore = true;
  bool _isLoading = false;
  int _newArtistCount = 0;
  StreamSubscription<int>? _watchSub;

  List<ArtistOrderParameter> get _orderParams => [
    ArtistOrderParameter(column: 'artist'),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(trackSyncProvider.notifier).sync());
    _scrollController.addListener(_onScroll);
    _loadMore();
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

    final useCursor = _hasMore && _artists.isNotEmpty;
    final cursorFilters = useCursor
        ? _buildCursorFromLast(_artists.last)
        : <ArtistRowFilterParameter>[];
    final orderBy = useCursor ? _orderParams : <ArtistOrderParameter>[];

    _watchSub = db
        .watchArtistCount(
          orderBy: orderBy,
          cursorFilters: cursorFilters,
        )
        .listen((count) {
          if (!mounted) return;
          final newCount = count - _artists.length;
          if (newCount != _newArtistCount) {
            setState(() => _newArtistCount = newCount > 0 ? newCount : 0);
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

    final cursorFilters = _artists.isEmpty
        ? <ArtistRowFilterParameter>[]
        : _buildCursorFromLast(_artists.last);

    final artists = await db.getArtists(
      orderBy: _orderParams,
      cursorFilters: cursorFilters,
      limit: _pageSize,
    );

    if (!mounted) return;
    setState(() {
      _artists.addAll(artists);
      _hasMore = artists.length == _pageSize;
      _isLoading = false;
    });
    _startWatching();
  }

  List<ArtistRowFilterParameter> _buildCursorFromLast(String lastArtist) {
    return [
      ArtistRowFilterParameter(column: 'artist', value: lastArtist),
    ];
  }

  void _refresh() {
    _watchSub?.cancel();
    setState(() {
      _artists = [];
      _hasMore = true;
      _newArtistCount = 0;
    });
    _loadMore();
  }

  void _onArtistTap(String artistName) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(artistName)),
          body: AlbumsPage(artist: artistName),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        if (_newArtistCount > 0)
          MaterialBanner(
            content: Text('$_newArtistCount new artists available'),
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
              childAspectRatio: 0.85,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _artists.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _artists.length) {
                return const Center(child: CircularProgressIndicator());
              }
              final artist = _artists[index];
              return ArtistCard(
                artistName: artist,
                onTap: () => _onArtistTap(artist),
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
