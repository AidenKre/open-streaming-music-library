import 'package:flutter/foundation.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';

/// A scripted [LibrarySearchControls] for page widget tests (SC-26: views
/// are tested against fake controllers). Tests set its state with [show]
/// and read back the inputs the page sent.
class FakeLibrarySearchControls extends ChangeNotifier
    implements LibrarySearchControls {
  FakeLibrarySearchControls({
    required this.types,
    required this.limitPerType,
    required this.downloadedOnly,
  });

  @override
  final Set<SearchType> types;
  @override
  final int limitPerType;

  /// The page's filter callback, as the real controller would read it.
  final bool Function() downloadedOnly;

  final calls = <String>[];

  String _query = '';
  bool _searching = false;
  bool _failed = false;
  LibrarySearchResults _results = emptySearchResults;
  bool disposed = false;

  /// Put the controller in a state and notify the page.
  void show({
    String? query,
    bool searching = false,
    bool failed = false,
    LibrarySearchResults? results,
  }) {
    if (query != null) _query = query;
    _searching = searching;
    _failed = failed;
    if (results != null) _results = results;
    notifyListeners();
  }

  @override
  String get query => _query;
  @override
  bool get isActive => _query.isNotEmpty;
  @override
  bool get isSearching => _searching;
  @override
  bool get failed => _failed;
  @override
  LibrarySearchResults get results => _results;
  @override
  bool get hasResults =>
      _results.artists.isNotEmpty ||
      _results.albums.isNotEmpty ||
      _results.tracks.isNotEmpty;

  @override
  bool cappedFor(SearchType type) =>
      types.contains(type) &&
      switch (type) {
            SearchType.artists => _results.artists.length,
            SearchType.albums => _results.albums.length,
            SearchType.tracks => _results.tracks.length,
          } >=
          limitPerType;

  @override
  bool get isCapped => types.any(cappedFor);

  @override
  void onQueryChanged(String raw) => calls.add('changed:$raw');
  @override
  void submit(String raw) => calls.add('submit:$raw');
  @override
  void clear() => calls.add('clear');
  @override
  Future<void> rerun() async =>
      calls.add('rerun downloadedOnly=${downloadedOnly()}');
  @override
  Future<void> retry() async =>
      calls.add('retry downloadedOnly=${downloadedOnly()}');
  @override
  Future<void> onDownloadStatusChanged() async => calls.add('downloads');

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
