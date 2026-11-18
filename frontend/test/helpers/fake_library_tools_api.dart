import 'dart:async';
import 'dart:convert';

import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/server_binding_gate.dart';

import 'fake_uploads_api.dart' show apiError;

export 'fake_uploads_api.dart' show apiError;

/// One job item as the 8A.2b server answers it.
Map<String, dynamic> deletionItemJson(
  String uuid, {
  int baseRevision = 1,
  String status = 'pending',
  String? error,
  int? tombstoneRevision,
  List<String> details = const [],
}) => {
  'uuid_id': uuid,
  'base_revision': baseRevision,
  'status': status,
  'error': error,
  'tombstone_revision': tombstoneRevision,
  'details': details,
};

/// A job as the server answers it.
Map<String, dynamic> deletionJobJson(
  String op,
  List<Map<String, dynamic>> items, {
  String status = 'pending',
  int createdAt = 1762800000,
}) => {
  'operation_uuid': op,
  'created_at': createdAt,
  'status': status,
  'item_count': items.length,
  'items': items,
};

/// One preview target as the server answers it: by default a live track
/// whose revision equals the base sent.
Map<String, dynamic> previewTargetJson(
  String uuid,
  int baseRevision, {
  int? revision,
  bool unknown = false,
  bool alreadyDeleted = false,
  bool missingMaster = false,
  bool fileUnchecked = false,
  bool conflict = false,
  bool busy = false,
}) => {
  'uuid_id': uuid,
  'base_revision': baseRevision,
  'revision': unknown ? null : (revision ?? baseRevision),
  'title': unknown ? null : 'Title $uuid',
  'artist': unknown ? null : 'Artist',
  'album': null,
  // fileUnchecked: the server refused to judge the stored path (a symlink, a
  // folder, outside the library, an unmounted volume): existence unknown.
  'master_exists': unknown || fileUnchecked ? null : !missingMaster,
  'master_size': unknown || missingMaster || fileUnchecked ? null : 1000,
  'unknown': unknown,
  'already_deleted': alreadyDeleted,
  'missing_master': missingMaster,
  'conflict': conflict,
  'busy': busy,
};

/// A scriptable [LibraryToolsApi] with a small server-side job store.
/// Every call is recorded in [calls] as `'<method> <id>'` (preview: the
/// UUIDs joined by `,`), with [callsBeforeVerified] counting calls made
/// while [gate] was not verified. An abort trigger ends a pending answer
/// with [LibraryToolsRequestAborted], like the real transport's gate wait.
class FakeLibraryToolsApi implements LibraryToolsApi {
  FakeLibraryToolsApi({this.gate});

  final ServerBindingGate? gate;

  /// Without a [gate]: whether the binding counts as verified for calls
  /// made with `waitForBinding: false` (U33-B-02). Setting it true
  /// completes [whenVerified] waiters.
  bool get bindingVerified => _bindingVerified;
  set bindingVerified(bool value) {
    _bindingVerified = value;
    if (value) {
      final w = _verifiedWaiter;
      _verifiedWaiter = null;
      w?.complete();
    }
  }

  bool _bindingVerified = true;
  Completer<void>? _verifiedWaiter;

  @override
  Future<void> whenVerified() {
    final g = gate;
    if (g != null) return g.awaitVerified();
    if (_bindingVerified) return Future.value();
    return (_verifiedWaiter ??= Completer<void>()).future;
  }

  /// The transport's fail-fast rule: a page read that must not wait at the
  /// gate throws [LibraryToolsNotConnected] while the binding is unverified,
  /// and nothing is recorded as sent.
  void _failFast(bool waitForBinding) {
    if (waitForBinding) return;
    final g = gate;
    final verified = g == null ? bindingVerified : g.isVerifiedNow;
    if (!verified) throw const LibraryToolsNotConnected();
  }

  final calls = <String>[];
  int callsBeforeVerified = 0;

  /// Preview requests as sent (wire JSON).
  final previews = <Map<String, dynamic>>[];

  /// createJob bodies as sent (the frozen JSON string, verbatim).
  final createBodies = <String>[];

  /// The server's jobs by operation UUID (wire JSON), as [onGetJob] reads
  /// them by default; the default [onCreateJob] stores new jobs here.
  final serverJobs = <String, Map<String, dynamic>>{};

  /// Default: every target is a live track at the base revision sent.
  Future<DeletionPreviewDto> Function(List<DeletionTargetDto> targets)
  onPreview = (targets) async => DeletionPreviewDto.fromJson({
    'targets': [
      for (final t in targets) previewTargetJson(t.uuidId, t.baseRevision),
    ],
  });

  /// Default: the job is accepted with every target pending (stored in
  /// [serverJobs]); an exact replay answers the stored job.
  late Future<DeletionJobDto> Function(String frozenBodyJson) onCreateJob =
      (body) async {
        final m = jsonDecode(body) as Map<String, dynamic>;
        final op = m['operation_uuid'] as String;
        serverJobs[op] ??= deletionJobJson(op, [
          for (final t in (m['targets'] as List).cast<Map<String, dynamic>>())
            deletionItemJson(
              t['uuid_id'] as String,
              baseRevision: t['base_revision'] as int,
            ),
        ]);
        return DeletionJobDto.fromJson(serverJobs[op]);
      };

  /// Default: the stored job, or 404 `deletion_job_not_found`.
  late Future<DeletionJobDto> Function(String op) onGetJob = (op) async {
    final job = serverJobs[op];
    if (job == null) {
      throw apiError(404, 'deletion_job_not_found', retryable: false);
    }
    return DeletionJobDto.fromJson(job);
  };

  /// The receipt list (8B.1c). Default: no receipts.
  Future<DeletionJobPageDto> Function(String? after, int? limit) onListJobs =
      (after, limit) async =>
          const DeletionJobPageDto(jobs: [], nextAfter: null);

  void _record(String call) {
    calls.add(call);
    final g = gate;
    if (g != null && g.verifiedConnection == null) callsBeforeVerified++;
  }

  /// [calls] of one method, e.g. `'createJob'`.
  List<String> callsOf(String method) => [
    for (final c in calls)
      if (c.startsWith('$method ')) c,
  ];

  Future<T> _abortable<T>(Future<T> answer, Future<void>? abortTrigger) {
    if (abortTrigger == null) return answer;
    final out = Completer<T>();
    answer.then(
      (v) {
        if (!out.isCompleted) out.complete(v);
      },
      onError: (Object e, StackTrace st) {
        if (!out.isCompleted) out.completeError(e, st);
      },
    );
    void abort(Object? _) {
      if (!out.isCompleted) {
        out.completeError(const LibraryToolsRequestAborted());
      }
    }

    abortTrigger.then(abort, onError: abort);
    return out.future;
  }

  @override
  Future<DeletionPreviewDto> preview(
    List<DeletionTargetDto> targets, {
    Future<void>? abortTrigger,
  }) {
    _record('preview ${targets.map((t) => t.uuidId).join(',')}');
    previews.add(DeletionPreviewRequestDto(targets: targets).toJson());
    return _abortable(onPreview(targets), abortTrigger);
  }

  @override
  Future<DeletionJobDto> createJob(
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) {
    final op =
        (jsonDecode(frozenBodyJson) as Map<String, dynamic>)['operation_uuid'];
    _record('createJob $op');
    createBodies.add(frozenBodyJson);
    return _abortable(onCreateJob(frozenBodyJson), abortTrigger);
  }

  @override
  Future<DeletionJobDto> getJob(
    String operationUuid, {
    Future<void>? abortTrigger,
  }) {
    _record('getJob $operationUuid');
    return _abortable(onGetJob(operationUuid), abortTrigger);
  }

  @override
  Future<DeletionJobPageDto> listJobs({
    String? after,
    int? limit,
    Future<void>? abortTrigger,
    bool waitForBinding = true,
  }) async {
    _failFast(waitForBinding);
    _record('listJobs $after');
    return _abortable(onListJobs(after, limit), abortTrigger);
  }

  /// Possible duplicates (8B.3). The defaults throw: the delete-jobs model
  /// never calls them. The Possible duplicates tests (test/ui/duplicates/)
  /// set the ones they need.
  Future<DuplicatePairPageDto> Function(String? status, String? after, int? limit)
  onListDuplicates = (status, after, limit) =>
      throw UnimplementedError('not used by the delete-jobs model');
  Future<DuplicateSummaryDto> Function() onDuplicateSummary = () =>
      throw UnimplementedError('not used by the delete-jobs model');
  Future<DuplicatePairStatusDto> Function(String uuidA, String uuidB)
  onDismissPair = (a, b) =>
      throw UnimplementedError('not used by the delete-jobs model');
  Future<DuplicatePairStatusDto> Function(String uuidA, String uuidB)
  onRestorePair = (a, b) =>
      throw UnimplementedError('not used by the delete-jobs model');

  @override
  Future<DuplicatePairPageDto> listDuplicates({
    String? status,
    String? after,
    int? limit,
    Future<void>? abortTrigger,
    bool waitForBinding = true,
  }) async {
    _failFast(waitForBinding);
    _record('listDuplicates $status $after');
    return _abortable(
      Future.sync(() => onListDuplicates(status, after, limit)),
      abortTrigger,
    );
  }

  @override
  Future<DuplicateSummaryDto> duplicateSummary({
    Future<void>? abortTrigger,
    bool waitForBinding = true,
  }) async {
    _failFast(waitForBinding);
    _record('duplicateSummary ');
    return _abortable(Future.sync(onDuplicateSummary), abortTrigger);
  }

  @override
  Future<DuplicatePairStatusDto> dismissPair(
    String uuidA,
    String uuidB, {
    Future<void>? abortTrigger,
  }) {
    _record('dismissPair $uuidA,$uuidB');
    return _abortable(Future.sync(() => onDismissPair(uuidA, uuidB)), abortTrigger);
  }

  @override
  Future<DuplicatePairStatusDto> restorePair(
    String uuidA,
    String uuidB, {
    Future<void>? abortTrigger,
  }) {
    _record('restorePair $uuidA,$uuidB');
    return _abortable(Future.sync(() => onRestorePair(uuidA, uuidB)), abortTrigger);
  }
}
