import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';

/// The one search primitive shared by every search surface (the global
/// Search page, the in-page search on the root browse tabs, and Phase 4's
/// Home): debounced capped FTS search over [types] with a generation
/// stale-guard.
///
/// Owned by a page `State` and disposed with it. The page listens to it and
/// treats [isActive] as "in search mode" (a non-empty committed query).
///
/// Every fetch captures a generation number; a completion from an older
/// generation (a newer query, [clear], [rerun]) or one landing after
/// [dispose] is dropped, so results can never go backwards or touch a dead
/// page.
class LibrarySearchController extends ChangeNotifier {
  LibrarySearchController({
    required BrowseRepository repository,
    required this.types,
    required this.limitPerType,
    required bool Function() downloadedOnly,
    this.debounce = const Duration(milliseconds: 300),
  }) : _repository = repository,
       _downloadedOnly = downloadedOnly;

  final BrowseRepository _repository;

  /// Read at fetch time, so a filter/offline change is picked up by [rerun].
  final bool Function() _downloadedOnly;

  final Set<SearchType> types;

  /// Rows fetched per type. Search mode is capped by design (no infinite
  /// scroll); [isCapped] tells the UI when to suggest refining.
  final int limitPerType;
  final Duration debounce;

  String _query = '';
  bool _isSearching = false;
  LibrarySearchResults _results = emptySearchResults;
  bool _failed = false;
  int _generation = 0;
  int _patchSeq = 0;
  int _appliedPatchSeq = 0;
  bool _downloadsChangedMidSearch = false;
  Timer? _debounceTimer;
  bool _disposed = false;

  /// The committed (debounced, trimmed) query.
  String get query => _query;

  /// Whether the owning page should be showing search results.
  bool get isActive => _query.isNotEmpty;

  /// A fetch for the current query is in flight. The previous results stay
  /// visible meanwhile, so typing doesn't flash an empty list.
  bool get isSearching => _isSearching;

  LibrarySearchResults get results => _results;

  /// The last fetch threw, so the (empty) [results] mean "couldn't search",
  /// not "nothing matched".
  bool get failed => _failed;

  bool get hasResults =>
      _results.artists.isNotEmpty ||
      _results.albums.isNotEmpty ||
      _results.tracks.isNotEmpty;

  /// Some requested type came back full, so there may be more matches than
  /// shown.
  bool get isCapped =>
      (types.contains(SearchType.artists) &&
          _results.artists.length >= limitPerType) ||
      (types.contains(SearchType.albums) &&
          _results.albums.length >= limitPerType) ||
      (types.contains(SearchType.tracks) &&
          _results.tracks.length >= limitPerType);

  /// Raw text-field input. Commits (and searches) once typing pauses for
  /// [debounce].
  void onQueryChanged(String raw) {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      _commit(raw.trim());
    });
  }

  /// The keyboard's search action: the user is done typing, so commit [raw]
  /// now instead of waiting out the debounce.
  void submit(String raw) {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _commit(raw.trim());
  }

  /// Leave search mode right away: there is no keystroke burst to coalesce,
  /// so don't make the user wait out the debounce.
  void clear() => submit('');

  /// Re-fetch the current query now, e.g. after the Downloaded filter or
  /// offline mode changed. No-op while inactive.
  Future<void> rerun() async {
    if (_disposed || !isActive) return;
    await _search();
  }

  /// Keep a snapshot of results honest after a download/delete. If the
  /// results are download-filtered, membership may have changed (a deleted
  /// download must drop out), so re-search. Otherwise just patch the rows'
  /// download state in place.
  ///
  /// A search already in flight may have read the old download state, and
  /// patching the rows on screen would race it. Restarting it would starve
  /// under a burst of events (each restart drops the last), so let it land
  /// and then handle this event once.
  Future<void> onDownloadStatusChanged() async {
    if (_disposed || !isActive) return;
    if (_isSearching) {
      _downloadsChangedMidSearch = true;
      return;
    }
    if (_downloadedOnly()) {
      await _search();
      return;
    }
    final generation = _generation;
    final patch = ++_patchSeq;
    final List<TrackUI> patched;
    try {
      patched = await _repository.withFreshDownloadState(_results.tracks);
    } catch (e) {
      // Pages fire this without awaiting it; keep the rows rather than
      // surface an unhandled error.
      debugPrint('LibrarySearchController: download-state patch failed: $e');
      return;
    }
    // Dropped if a search replaced the rows, or a later patch (which read
    // the DB after this one) already landed. A later patch that is still
    // pending may yet fail, so this one applies meanwhile.
    if (_disposed || generation != _generation || patch <= _appliedPatchSeq) {
      return;
    }
    _appliedPatchSeq = patch;
    _results = (
      artists: _results.artists,
      albums: _results.albums,
      tracks: patched,
    );
    notifyListeners();
  }

  void _commit(String query) {
    if (_disposed || query == _query) return;
    _query = query;
    _search();
  }

  Future<void> _search() async {
    if (_disposed) return;
    // Bump first so any in-flight older request is dropped on completion.
    final generation = ++_generation;
    // This fetch reads the DB after every download event so far.
    _downloadsChangedMidSearch = false;
    if (_query.isEmpty) {
      _isSearching = false;
      _failed = false;
      _results = emptySearchResults;
      notifyListeners();
      return;
    }

    _isSearching = true;
    notifyListeners();

    LibrarySearchResults results;
    var failed = false;
    try {
      results = await _repository.search(
        _query,
        types: types,
        limitPerType: limitPerType,
        downloadedOnly: _downloadedOnly(),
      );
    } catch (e) {
      debugPrint('LibrarySearchController: search failed: $e');
      results = emptySearchResults;
      failed = true;
    }

    if (_disposed || generation != _generation) return;
    _isSearching = false;
    _failed = failed;
    _results = results;
    notifyListeners();
    if (_downloadsChangedMidSearch) {
      _downloadsChangedMidSearch = false;
      await onDownloadStatusChanged();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    super.dispose();
  }
}
