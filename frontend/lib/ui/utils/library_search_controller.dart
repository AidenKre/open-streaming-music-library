import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
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
/// The search input of a page (SC-19/SC-26): what every search surface
/// depends on. Page-scoped: obtained from
/// [librarySearchControllerFactoryProvider] and disposed by its page.
abstract interface class LibrarySearchControls implements Listenable {
  Set<SearchType> get types;
  int get limitPerType;

  /// The committed (debounced, trimmed) query.
  String get query;

  /// Whether the owning page should be showing search results.
  bool get isActive;

  /// A fetch for the current query is in flight.
  bool get isSearching;
  LibrarySearchResults get results;

  /// The last fetch threw.
  bool get failed;
  bool get hasResults;

  /// Some requested type came back full.
  bool get isCapped;

  /// [type] was requested and came back full (one hint per capped type).
  bool cappedFor(SearchType type);

  /// Raw text-field input (debounced).
  void onQueryChanged(String raw);

  /// The keyboard's search action: commit now.
  void submit(String raw);

  /// Leave search mode right away.
  void clear();

  /// Re-fetch the current query now (filter/offline change).
  Future<void> rerun();

  /// The user's Retry after a failure: re-runs the committed query with the
  /// current filter.
  Future<void> retry();

  /// Keep a results snapshot honest after a download/delete.
  Future<void> onDownloadStatusChanged();

  void dispose();
}

typedef LibrarySearchFactory =
    LibrarySearchControls Function({
      required Set<SearchType> types,
      required int limitPerType,
      required bool Function() downloadedOnly,
    });

/// Creates a page's [LibrarySearchControls] over the model's search
/// (SC-26: page-scoped controllers come from a provider, never from a view
/// passing in a repository). Override in tests to substitute a fake.
final librarySearchControllerFactoryProvider = Provider<LibrarySearchFactory>(
  (ref) =>
      ({required types, required limitPerType, required downloadedOnly}) =>
          LibrarySearchController(
            repository: ref.read(browseRepositoryProvider),
            types: types,
            limitPerType: limitPerType,
            downloadedOnly: downloadedOnly,
          ),
);

class LibrarySearchController extends ChangeNotifier
    implements LibrarySearchControls {
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

  @override
  final Set<SearchType> types;

  /// Rows fetched per type. Search mode is capped by design (no infinite
  /// scroll); [isCapped] tells the UI when to suggest refining.
  @override
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

  /// A download patch was dropped because a search was replacing the rows;
  /// redone if that search fails and keeps the old rows.
  bool _patchDroppedForSearch = false;
  Timer? _debounceTimer;
  bool _disposed = false;

  /// The committed (debounced, trimmed) query.
  @override
  String get query => _query;

  /// Whether the owning page should be showing search results.
  @override
  bool get isActive => _query.isNotEmpty;

  /// A fetch for the current query is in flight. The previous results stay
  /// visible meanwhile, so typing doesn't flash an empty list.
  @override
  bool get isSearching => _isSearching;

  @override
  LibrarySearchResults get results => _results;

  /// The last fetch threw. [results] still hold whatever was shown before
  /// (possibly empty); either way they don't mean "nothing matched".
  @override
  bool get failed => _failed;

  @override
  bool get hasResults =>
      _results.artists.isNotEmpty ||
      _results.albums.isNotEmpty ||
      _results.tracks.isNotEmpty;

  /// Some requested type came back full, so there may be more matches than
  /// shown.
  @override
  bool get isCapped => types.any(cappedFor);

  /// [type] was requested and came back full: there may be more of it.
  @override
  bool cappedFor(SearchType type) {
    if (!types.contains(type)) return false;
    final count = switch (type) {
      SearchType.artists => _results.artists.length,
      SearchType.albums => _results.albums.length,
      SearchType.tracks => _results.tracks.length,
    };
    return count >= limitPerType;
  }

  /// Raw text-field input. Commits (and searches) once typing pauses for
  /// [debounce].
  @override
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
  @override
  void submit(String raw) {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _commit(raw.trim());
  }

  /// Leave search mode right away: there is no keystroke burst to coalesce,
  /// so don't make the user wait out the debounce.
  @override
  void clear() => submit('');

  /// Re-fetch the current query now, e.g. after the Downloaded filter or
  /// offline mode changed. No-op while inactive.
  @override
  Future<void> rerun() async {
    if (_disposed || !isActive) return;
    await _search();
  }

  /// The user's Retry after a failure: the same committed query, read with
  /// the current filter. No-op while inactive or disposed.
  @override
  Future<void> retry() => rerun();

  /// Keep a snapshot of results honest after a download/delete. If the
  /// results are download-filtered, membership may have changed (a deleted
  /// download must drop out), so re-search. Otherwise just patch the rows'
  /// download state in place.
  ///
  /// A search already in flight may have read the old download state, and
  /// patching the rows on screen would race it. Restarting it would starve
  /// under a burst of events (each restart drops the last), so let it land
  /// and then handle this event once.
  @override
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
    if (_disposed) return;
    if (generation != _generation) {
      // A newer search replaced the rows this patch read. If that search
      // fails, it keeps the OLD rows, so they still need this event.
      if (_isSearching) {
        _patchDroppedForSearch = true;
      } else if (_failed) {
        await onDownloadStatusChanged();
      }
      return;
    }
    if (patch <= _appliedPatchSeq) return;
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
      // The rows a dropped patch was for are gone too.
      _patchDroppedForSearch = false;
      _results = emptySearchResults;
      notifyListeners();
      return;
    }

    // Starting a search (incl. a retry) clears the last error right away.
    _isSearching = true;
    _failed = false;
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
      // Keep the previous results on screen beside the error (4A.3): a
      // failure is never shown as an empty "no matches" result.
      results = _results;
      failed = true;
    }

    if (_disposed || generation != _generation) return;
    _isSearching = false;
    _failed = failed;
    _results = results;
    notifyListeners();
    final redoPatch = _patchDroppedForSearch;
    _patchDroppedForSearch = false;
    if (failed && redoPatch) {
      await onDownloadStatusChanged();
      return;
    }
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
