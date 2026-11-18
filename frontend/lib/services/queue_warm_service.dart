import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';

/// Warms the server's encode cache via `POST /tracks/warm` so upcoming tracks
/// are pre-transcoded before the user needs them.
///
/// We POST a debounced snapshot whenever:
/// - the active queue changes (queueVersion bumps), OR
/// - the user changes their stream quality preset, OR
/// - the currently-playing track advances.
///
/// Responses are advisory: failures are logged and ignored. Warm POSTs do not
/// opt into ApiClient's mutation retry path because this is intentionally
/// fire-and-forget; a later schedule can try warming again if needed.
class QueueWarmService {
  static const _debounce = Duration(milliseconds: 500);
  static const _maxTrackUuids = 50;

  final QueueRepository _queueRepo;
  final ApiClient _apiClient;
  final bool Function() _isOfflineFn;
  // Separate timers so queue-driven and download-driven warms never cancel
  // each other. They're logically independent flows.
  Timer? _queueWarmTimer;
  Timer? _uuidsWarmTimer;
  // Uuids pending a download-driven warm, accumulated across the debounce
  // window and keyed by quality. Using a set (insertion-ordered) coalesces
  // duplicates without dropping earlier batches when calls arrive in quick
  // succession.
  final Map<String, Set<String>> _pendingWarmUuids = {};

  /// Set by [quiesce] (a reset or log-out, SC-15): no timer starts and no
  /// request is sent after it. Terminal: the scope is rebuilt afterwards.
  bool _quiesced = false;

  QueueWarmService({
    required QueueRepository queueRepo,
    required ApiClient apiClient,
    bool Function()? isOfflineFn,
  })  : _queueRepo = queueRepo,
        _apiClient = apiClient,
        _isOfflineFn = isOfflineFn ?? (() => false);

  void scheduleWarm({
    required int? sessionId,
    required int currentPlayPosition,
    required String quality,
  }) {
    if (_quiesced) return;
    _queueWarmTimer?.cancel();
    _queueWarmTimer = Timer(_debounce, () {
      unawaited(
        _warm(
          sessionId: sessionId,
          currentPlayPosition: currentPlayPosition,
          quality: quality,
        ),
      );
    });
  }

  Future<void> _warm({
    required int? sessionId,
    required int currentPlayPosition,
    required String quality,
  }) async {
    if (sessionId == null) return;
    // Warming is advisory and pure overhead while the network is down.
    if (_isOfflineFn()) return;
    // Advisory, fired from a timer: nothing here may escape it.
    try {
      final entries = await _queueRepo.getPlaybackEntries(
        sessionId,
        startPlayPosition: currentPlayPosition,
        limit: _maxTrackUuids,
      );
      if (entries.isEmpty) return;
      // A reset's quiet step landed during the queue read: send nothing.
      if (_quiesced) return;

      final trackUuids = entries.map((e) => e.uuidId).toList(growable: false);
      await _apiClient.postJson(
        ['tracks', 'warm'],
        body: {
          'session_id': sessionId.toString(),
          'current_index': 0,
          'quality': quality,
          'track_uuids': trackUuids,
        },
      );
    } on ApiException catch (e) {
      developer.log('queue warm failed: $e', name: 'QueueWarm');
    } on NetworkException catch (e) {
      developer.log('queue warm failed: $e', name: 'QueueWarm');
    } on TokenWithheldException {
      developer.log('queue warm skipped: the server is not verified', name: 'QueueWarm');
    } catch (e) {
      developer.log('queue warm failed: $e', name: 'QueueWarm');
    }
  }

  /// Directly warm [trackUuids] at [quality] without going through the queue.
  /// Used by the download manager to pre-transcode queued downloads on the server.
  /// Debounced — rapid calls within the window accumulate (per quality) so no
  /// earlier batch is dropped.
  void scheduleWarmUuids(List<String> trackUuids, {required String quality}) {
    if (_quiesced || trackUuids.isEmpty) return;
    _pendingWarmUuids.putIfAbsent(quality, () => <String>{}).addAll(trackUuids);
    _uuidsWarmTimer?.cancel();
    _uuidsWarmTimer = Timer(_debounce, _flushWarmUuids);
  }

  void _flushWarmUuids() {
    if (_pendingWarmUuids.isEmpty) return;
    final batches = Map<String, Set<String>>.from(_pendingWarmUuids);
    _pendingWarmUuids.clear();
    for (final entry in batches.entries) {
      unawaited(
        _warmUuids(entry.value.toList(growable: false), quality: entry.key),
      );
    }
  }

  Future<void> _warmUuids(
    List<String> trackUuids, {
    required String quality,
  }) async {
    if (trackUuids.isEmpty) return;
    if (_isOfflineFn()) return;
    final capped = trackUuids.take(_maxTrackUuids).toList(growable: false);
    try {
      await _apiClient.postJson(
        ['tracks', 'warm'],
        body: {
          // session_id is omitted (null) for the download-driven path: the
          // backend doesn't read this field, and using a magic string here
          // risked colliding with a real session id.
          'session_id': null,
          'current_index': 0,
          // Warm the whole batch, not just the server's default look-ahead
          // window. The batch is capped at [_maxTrackUuids]: queued
          // downloads beyond the first 50 are not warmed by this request.
          'count': capped.length,
          'quality': quality,
          'track_uuids': capped,
        },
      );
    } on ApiException catch (e) {
      developer.log('queue warm (uuids) failed: $e', name: 'QueueWarm');
    } on NetworkException catch (e) {
      developer.log('queue warm (uuids) failed: $e', name: 'QueueWarm');
    } on TokenWithheldException {
      developer.log('queue warm (uuids) skipped: the server is not verified', name: 'QueueWarm');
    }
  }

  /// The reset's quiet step (SC-15, after playback): cancels both pending
  /// warm-ups and stops for good, so no warm-up request leaves during or
  /// after the wipe. A request already handed to the client is not awaited
  /// (it is advisory, and its token is the old scope's).
  Future<void> quiesce() async {
    _quiesced = true;
    _queueWarmTimer?.cancel();
    _uuidsWarmTimer?.cancel();
    _pendingWarmUuids.clear();
  }

  void dispose() {
    _queueWarmTimer?.cancel();
    _uuidsWarmTimer?.cancel();
    _pendingWarmUuids.clear();
  }
}

final queueWarmServiceProvider = Provider<QueueWarmService>((ref) {
  final service = QueueWarmService(
    queueRepo: ref.read(queueRepositoryProvider),
    apiClient: ref.read(apiClientProvider),
    isOfflineFn: () => ref.read(offlineModeProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
