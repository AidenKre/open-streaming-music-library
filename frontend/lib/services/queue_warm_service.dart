import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
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
  Timer? _debounceTimer;

  QueueWarmService({
    required QueueRepository queueRepo,
    ApiClient? apiClient,
    bool Function()? isOfflineFn,
  })  : _queueRepo = queueRepo,
        _apiClient = apiClient ?? ApiClient.instance,
        _isOfflineFn = isOfflineFn ?? (() => false);

  void scheduleWarm({
    required int? sessionId,
    required int currentPlayPosition,
    required String quality,
  }) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
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
    final entries = await _queueRepo.getPlaybackEntries(
      sessionId,
      startPlayPosition: currentPlayPosition,
      limit: _maxTrackUuids,
    );
    if (entries.isEmpty) return;

    final trackUuids = entries.map((e) => e.uuidId).toList(growable: false);
    try {
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
    }
  }

  /// Directly warm [trackUuids] at [quality] without going through the queue.
  /// Used by the download manager to pre-transcode queued downloads on the server.
  /// Debounced — rapid calls within the debounce window are coalesced.
  void scheduleWarmUuids(List<String> trackUuids, {required String quality}) {
    if (trackUuids.isEmpty) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      unawaited(_warmUuids(trackUuids, quality: quality));
    });
  }

  Future<void> _warmUuids(
    List<String> trackUuids, {
    required String quality,
  }) async {
    if (trackUuids.isEmpty) return;
    if (_isOfflineFn()) return;
    try {
      await _apiClient.postJson(
        ['tracks', 'warm'],
        body: {
          'session_id': 'download-manager',
          'current_index': 0,
          'quality': quality,
          'track_uuids': trackUuids.take(_maxTrackUuids).toList(),
        },
      );
    } on ApiException catch (e) {
      developer.log('queue warm (uuids) failed: $e', name: 'QueueWarm');
    } on NetworkException catch (e) {
      developer.log('queue warm (uuids) failed: $e', name: 'QueueWarm');
    }
  }

  void dispose() {
    _debounceTimer?.cancel();
  }
}

final queueWarmServiceProvider = Provider<QueueWarmService>((ref) {
  final service = QueueWarmService(
    queueRepo: ref.read(queueRepositoryProvider),
    isOfflineFn: () => ref.read(offlineModeProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
