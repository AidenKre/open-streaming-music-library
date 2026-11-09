import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/ui/player_controller.dart';

@immutable
class QueueRow {
  const QueueRow(this.entry, this.availability);
  final QueueTrackEntry entry;
  final PlaybackAvailability availability;
}

enum QueueReloadKind { none, initial, visible }

/// The full player's queue list (SC-27 `QueueListControls`): pages the
/// active session's play order in a window around the current item, exposes
/// rows whose availability comes from the model (`PlaybackAvailability`),
/// and forwards row taps/removals to `PlayerControls`. Scroll geometry stays
/// in the view; this holds the paging state the widget used to.
abstract interface class QueueListControls implements Listenable {
  List<QueueRow> get rows;
  int get startPlayPosition;
  bool get isInitialLoad;
  bool get isViewportReload;
  bool get hasMoreBefore;
  bool get hasMoreAfter;
  Object? get error;

  /// Set after an initial load: the view should centre the current item.
  bool get shouldScrollToCurrent;
  void scrolledToCurrent();

  /// Given the playback state the view observes, which load (if any) the
  /// view should schedule after this frame.
  QueueReloadKind plan({
    required int sessionId,
    required int queueVersion,
    required int currentPlayPosition,
    required int totalCount,
  });

  Future<void> loadInitial({
    required int sessionId,
    required int expectedQueueVersion,
    required int currentPlayPosition,
    required int totalCount,
  });

  /// Re-reads the visible window after a queue edit, anchored on the row
  /// at [anchorLocalIndex]. Returns that row's new local index (null when it
  /// is gone or the load was superseded).
  Future<int?> reloadVisible({
    required int sessionId,
    required int expectedQueueVersion,
    required int currentPlayPosition,
    required int totalCount,
    required int anchorLocalIndex,
  });

  /// Pages up; returns how many rows were prepended.
  Future<int> loadBefore({required int totalCount});
  Future<void> loadAfter({required int totalCount});

  void tapRow(int itemId);
  void remove(int itemId);
  void dispose();
}

/// Creates a page-scoped [QueueListControls] (disposed by its widget).
final queueListControllerFactoryProvider =
    Provider<QueueListControls Function()>(
      (ref) => () => QueueListController(
        repository: ref.read(queueRepositoryProvider),
        player: ref.read(playerControlsProvider),
        isOffline: () => ref.read(offlineModeProvider),
        codecs: () => ref.read(codecSupportProvider),
      ),
    );

class QueueListController extends ChangeNotifier implements QueueListControls {
  QueueListController({
    required QueueRepository repository,
    required PlayerControls player,
    required bool Function() isOffline,
    CodecSupport Function()? codecs,
  }) : _repo = repository,
       _player = player,
       _isOffline = isOffline,
       _codecs = codecs ?? (() => const CodecSupport.unknown());

  static const pageSize = 80;
  static const initialLeadingCount = 40;
  static const initialTrailingCount = 60;

  final QueueRepository _repo;
  final PlayerControls _player;
  final bool Function() _isOffline;

  /// A download in a codec this device can't decode doesn't play offline.
  final CodecSupport Function() _codecs;

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
  (int, int, int, int)? _failedInitialLoad;
  bool _disposed = false;

  @override
  List<QueueRow> get rows {
    final offline = _isOffline();
    final codecs = _codecs();
    return [
      for (final e in _tracks)
        QueueRow(
          e,
          PlaybackAvailability.of(
            offline: offline,
            downloaded: e.track.isDownloaded ? 1 : 0,
            undecodable:
                e.track.isDownloaded && !codecs.playsDownload(e.track) ? 1 : 0,
            total: 1,
          ),
        ),
    ];
  }

  @override
  int get startPlayPosition => _startPlayPosition;
  @override
  bool get isInitialLoad => _isInitialLoad;
  @override
  bool get isViewportReload => _isViewportReload;
  @override
  bool get hasMoreBefore => _hasMoreBefore;
  @override
  bool get hasMoreAfter => _hasMoreAfter;
  @override
  Object? get error => _error;
  @override
  bool get shouldScrollToCurrent => _shouldScrollToCurrent;
  @override
  void scrolledToCurrent() => _shouldScrollToCurrent = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _stale(int sessionId, int expectedQueueVersion) =>
      _disposed || _sessionId != sessionId || _queueVersion != expectedQueueVersion;

  @override
  QueueReloadKind plan({
    required int sessionId,
    required int queueVersion,
    required int currentPlayPosition,
    required int totalCount,
  }) {
    final sessionChanged = _sessionId != sessionId;
    final queueChanged = _queueVersion != queueVersion;
    // A failed read is a settled state. Rebuilds must not turn it into an
    // unbounded read/notify/rebuild loop; a changed queue or Retry can load.
    if (_failedInitialLoad ==
        (sessionId, queueVersion, currentPlayPosition, totalCount)) {
      return QueueReloadKind.none;
    }
    final currentOutsideLoadedRange =
        _tracks.isEmpty ||
        currentPlayPosition < _startPlayPosition ||
        currentPlayPosition >= _startPlayPosition + _tracks.length;
    if (sessionChanged || currentOutsideLoadedRange) {
      if (_isInitialLoad) return QueueReloadKind.none;
      _sessionId = sessionId;
      _queueVersion = queueVersion;
      return QueueReloadKind.initial;
    }
    if (!queueChanged || _isInitialLoad || _isViewportReload) {
      return QueueReloadKind.none;
    }
    _sessionId = sessionId;
    _queueVersion = queueVersion;
    return QueueReloadKind.visible;
  }

  @override
  Future<void> loadInitial({
    required int sessionId,
    required int expectedQueueVersion,
    required int currentPlayPosition,
    required int totalCount,
  }) async {
    if (_disposed) return;
    _isInitialLoad = true;
    _error = null;
    _failedInitialLoad = null;
    _notify();
    if (totalCount == 0) {
      _tracks = const [];
      _startPlayPosition = 0;
      _hasMoreBefore = false;
      _hasMoreAfter = false;
      _shouldScrollToCurrent = false;
      _isInitialLoad = false;
      _notify();
      return;
    }
    final start = (currentPlayPosition - initialLeadingCount).clamp(0, totalCount - 1);
    final limit = (initialLeadingCount + initialTrailingCount + 1).clamp(1, totalCount - start);
    try {
      final tracks = await _repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: start,
        limit: limit,
      );
      if (_stale(sessionId, expectedQueueVersion)) {
        _isInitialLoad = false;
        return;
      }
      _tracks = tracks;
      _startPlayPosition = start;
      _hasMoreBefore = start > 0;
      _hasMoreAfter = start + tracks.length < totalCount;
      _shouldScrollToCurrent = true;
      _error = null;
      _isInitialLoad = false;
      _notify();
    } catch (error) {
      if (_disposed) return;
      _error = error;
      _failedInitialLoad =
          (sessionId, expectedQueueVersion, currentPlayPosition, totalCount);
      _isInitialLoad = false;
      _notify();
    }
  }

  @override
  Future<int?> reloadVisible({
    required int sessionId,
    required int expectedQueueVersion,
    required int currentPlayPosition,
    required int totalCount,
    required int anchorLocalIndex,
  }) async {
    if (_disposed) return null;
    if (_tracks.isEmpty) {
      await loadInitial(
        sessionId: sessionId,
        expectedQueueVersion: expectedQueueVersion,
        currentPlayPosition: currentPlayPosition,
        totalCount: totalCount,
      );
      return null;
    }
    _isViewportReload = true;
    _error = null;
    _notify();
    final localIndex = anchorLocalIndex.clamp(0, _tracks.length - 1);
    final anchorItemId = _tracks[localIndex].itemId;
    final desiredLimit = totalCount < _tracks.length ? totalCount : _tracks.length;
    try {
      final anchorEntry = await _repo.getPlaybackEntryForItem(sessionId, anchorItemId);
      if (_stale(sessionId, expectedQueueVersion)) {
        _isViewportReload = false;
        return null;
      }
      final maxStart = totalCount > desiredLimit ? totalCount - desiredLimit : 0;
      final start = anchorEntry == null
          ? _startPlayPosition.clamp(0, maxStart)
          : (anchorEntry.playPosition - localIndex).clamp(0, maxStart);
      final tracks = desiredLimit <= 0
          ? const <QueueTrackEntry>[]
          : await _repo.getSessionTracksPage(
              sessionId,
              startPlayPosition: start,
              limit: desiredLimit,
            );
      if (_stale(sessionId, expectedQueueVersion)) {
        _isViewportReload = false;
        return null;
      }
      _tracks = tracks;
      _startPlayPosition = start;
      _hasMoreBefore = start > 0;
      _hasMoreAfter = start + tracks.length < totalCount;
      _shouldScrollToCurrent = false;
      _error = null;
      _isViewportReload = false;
      _notify();
      final newIndex = tracks.indexWhere((e) => e.itemId == anchorItemId);
      return newIndex == -1 ? null : newIndex;
    } catch (error) {
      if (_disposed) return null;
      _error = error;
      _isViewportReload = false;
      _notify();
      return null;
    }
  }

  @override
  Future<int> loadBefore({required int totalCount}) async {
    if (_disposed || _isLoadingBefore || !_hasMoreBefore) return 0;
    final sessionId = _sessionId;
    if (sessionId == null) return 0;
    final expectedQueueVersion = _queueVersion;
    final fetchStart = (_startPlayPosition - pageSize).clamp(0, _startPlayPosition);
    final limit = _startPlayPosition - fetchStart;
    if (limit <= 0) {
      _hasMoreBefore = false;
      _notify();
      return 0;
    }
    _isLoadingBefore = true;
    _notify();
    try {
      final tracks = await _repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: fetchStart,
        limit: limit,
      );
      if (_stale(sessionId, expectedQueueVersion)) {
        _isLoadingBefore = false;
        return 0;
      }
      _tracks = [...tracks, ..._tracks];
      _startPlayPosition = fetchStart;
      _hasMoreBefore = fetchStart > 0;
      _hasMoreAfter = _startPlayPosition + _tracks.length < totalCount;
      _isLoadingBefore = false;
      _notify();
      return tracks.length;
    } catch (error) {
      if (_disposed) return 0;
      _error = error;
      _isLoadingBefore = false;
      _notify();
      return 0;
    }
  }

  @override
  Future<void> loadAfter({required int totalCount}) async {
    if (_disposed || _isLoadingAfter || !_hasMoreAfter) return;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final expectedQueueVersion = _queueVersion;
    final fetchStart = _startPlayPosition + _tracks.length;
    final remaining = totalCount - fetchStart;
    if (remaining <= 0) {
      _hasMoreAfter = false;
      _notify();
      return;
    }
    final limit = remaining < pageSize ? remaining : pageSize;
    _isLoadingAfter = true;
    _notify();
    try {
      final tracks = await _repo.getSessionTracksPage(
        sessionId,
        startPlayPosition: fetchStart,
        limit: limit,
      );
      if (_stale(sessionId, expectedQueueVersion)) {
        _isLoadingAfter = false;
        return;
      }
      _tracks = [..._tracks, ...tracks];
      _hasMoreBefore = _startPlayPosition > 0;
      _hasMoreAfter = _startPlayPosition + _tracks.length < totalCount;
      _isLoadingAfter = false;
      _notify();
    } catch (error) {
      if (_disposed) return;
      _error = error;
      _isLoadingAfter = false;
      _notify();
    }
  }

  // Row actions are fire-and-forget from a tap; give their futures an
  // error sink so a failed command is logged, not an unhandled error.
  @override
  void tapRow(int itemId) =>
      _player.skipToItem(itemId).catchError(_logRowActionError);

  @override
  void remove(int itemId) =>
      _player.removeFromQueue(itemId).catchError(_logRowActionError);

  static void _logRowActionError(Object error) =>
      debugPrint('QueueListController: row action failed: $error');

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
