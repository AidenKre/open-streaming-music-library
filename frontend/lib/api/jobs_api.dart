import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/conversion_job.dart';

/// Thin wrapper around the backend's generic `/jobs` resource. Only
/// `type="conversion"` exists today -- the shape is forward-looking per the
/// backend doc so future bulk/upload job types add zero endpoints.
class JobsApi {
  final ApiClient _apiClient = ApiClient.instance;

  /// Enqueues a conversion job. Non-idempotent (mints a job) -> single
  /// attempt; an orphaned job from a timed-out-but-succeeded POST is
  /// recovered via [getJobs].
  Future<ConversionJob> postConversionJob({
    required String uuidId,
    required String targetCodec,
    required int? targetBitrateKbps,
    required int? baseRevision,
  }) async {
    final json = await _apiClient.postJson(
      ['jobs'],
      body: {
        'type': 'conversion',
        'uuid_id': uuidId,
        'params': {
          'target_codec': targetCodec,
          'target_bitrate_kbps': targetBitrateKbps,
        },
        'base_revision': baseRevision,
      },
    );
    return ConversionJob.fromJson(json);
  }

  /// Fetches one page of jobs, optionally filtered. [cursor]/the response's
  /// `nextCursor` are job ids (ascending) -- mirrors `/changes`' int-cursor
  /// convention.
  Future<List<ConversionJob>> getJobs({
    String? uuidId,
    String? status,
    int? cursor,
    int limit = 50,
  }) async {
    final query = <String, String>{
      'limit': limit.toString(),
      if (uuidId != null) 'uuid_id': uuidId,
      if (status != null) 'status': status,
      if (cursor != null) 'cursor': cursor.toString(),
    };
    final json = await _apiClient.getJson(['jobs'], query: query);
    final data = (json['data'] as List<dynamic>?) ?? const [];
    return data
        .map((j) => ConversionJob.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Cancels a queued or running job. Idempotent per the backend (a no-op
  /// `cancelled: false` for an already-terminal or unknown job_id, never a
  /// 404) -- `deleteJson` defaults to retrying transient failures.
  Future<bool> cancelJob(int jobId) async {
    final json = await _apiClient.deleteJson(['jobs', jobId.toString()]);
    return json['cancelled'] as bool;
  }
}
