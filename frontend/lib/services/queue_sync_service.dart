import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';

/// Syncs the frontend's queue state to the backend via `POST /queue/sync` so
/// the server can autonomously manage its encoded-track cache.
///
/// We POST a debounced snapshot whenever:
/// - the active queue changes (queueVersion bumps), OR
/// - the user changes their stream quality preset, OR
/// - the currently-playing track advances.
///
/// Responses are advisory: failures are logged and ignored.
class QueueSyncService {
  static const _debounce = Duration(milliseconds: 500);
  static const _maxTrackUuids = 50;

  final QueueRepository _queueRepo;
  final http.Client _client;
  final bool _ownsClient;
  Timer? _debounceTimer;

  QueueSyncService({
    required QueueRepository queueRepo,
    http.Client? client,
  })  : _queueRepo = queueRepo,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  void scheduleSync({
    required int? sessionId,
    required int currentPlayPosition,
    required String quality,
  }) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      unawaited(_sync(
        sessionId: sessionId,
        currentPlayPosition: currentPlayPosition,
        quality: quality,
      ));
    });
  }

  Future<void> _sync({
    required int? sessionId,
    required int currentPlayPosition,
    required String quality,
  }) async {
    if (sessionId == null) return;
    final entries = await _queueRepo.getPlaybackEntries(
      sessionId,
      startPlayPosition: currentPlayPosition,
      limit: _maxTrackUuids,
    );
    if (entries.isEmpty) return;

    final trackUuids = entries.map((e) => e.uuidId).toList(growable: false);
    final url = _baseUrl('/queue/sync');
    try {
      await _client.post(
        url,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'session_id': sessionId.toString(),
          'current_index': 0,
          'quality': quality,
          'track_uuids': trackUuids,
        }),
      );
    } catch (e) {
      developer.log('queue sync failed: $e', name: 'QueueSync');
    }
  }

  Uri _baseUrl(String path) {
    final base = Uri.parse(ApiClient.instance.baseUrl);
    final basePath = base.pathSegments.where((s) => s.isNotEmpty).toList();
    final extra = path.split('/').where((s) => s.isNotEmpty).toList();
    return base.replace(pathSegments: [...basePath, ...extra]);
  }

  void dispose() {
    _debounceTimer?.cancel();
    if (_ownsClient) _client.close();
  }
}

final queueSyncServiceProvider = Provider<QueueSyncService>((ref) {
  final service = QueueSyncService(
    queueRepo: ref.read(queueRepositoryProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
