// The delete-jobs model in the app's shared lifecycles (8B.1b S10): recovery
// (SC-13), quiesce (SC-15) and the Disconnect loss copy.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// One manager per scope, on the scope's [DurableSubmission]; quiesced when
/// the scope is disposed and by a reset (SC-15).
final deleteJobsManagerProvider = Provider<DeleteJobsManager>((ref) {
  final manager = DeleteJobsManager(
    api: ref.read(libraryToolsApiProvider),
    submissions: ref.read(durableSubmissionProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    gate: ref.read(serverBindingGateProvider),
    feature: () async {
      try {
        return await ref
            .read(libraryToolsFeatureProvider.future)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        return null;
      }
    },
    isOffline: () => ref.read(offlineModeProvider),
    requestSync: () => ref.read(trackSyncProvider.notifier).syncFresh(),
  );
  ref.onDispose(manager.quiesce);
  return manager;
});

/// Requests a delete-jobs pass on every recovery trigger, once the binding
/// is verified: a cold start resumes an unresolved submission without any
/// page being visited.
class DeleteJobsRecoverable implements RecoverableService {
  DeleteJobsRecoverable(this._ref);
  final Ref _ref;

  @override
  bool get requiresBinding => true;

  @override
  int get recoveryPriority => RecoveryPriority.deleteJobs;

  @override
  Set<RecoveryTrigger> get triggers => RecoveryTrigger.values.toSet();

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    final deletions = _ref.read(deleteJobsManagerProvider);
    if (resumesParkedWork(trigger, _ref.read(serverBindingGateProvider))) {
      deletions.resumeAfterBoundServerBack();
    }
    deletions.request(
      trigger.name,
      bypassBackoff: trigger != RecoveryTrigger.coldStart,
    );
  }
}

/// Quiesces the manager on reset or logout (SC-15); never builds it.
class DeleteJobsQuiescable implements Quiescable {
  DeleteJobsQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'delete-jobs';

  @override
  Future<void> quiesce() async {
    if (_ref.exists(deleteJobsManagerProvider)) {
      await _ref.read(deleteJobsManagerProvider).quiesce();
    }
  }
}

/// Counts the deletions on this device (kept ones of an ended sign-in
/// included) that the server has not yet answered, for the Disconnect copy.
class DeleteJobsLossReporter implements LossReporter {
  DeleteJobsLossReporter({
    required DurableSubmission submissions,
    required ServerBindingRepository binding,
  }) : _submissions = submissions,
       _binding = binding;

  final DurableSubmission _submissions;
  final ServerBindingRepository _binding;

  /// The tracks of every unanswered deletion on this device while a binding
  /// exists (kept ones of an ended sign-in included), split by whether the
  /// server may have received them (an unreadable one counts as 1 in its own
  /// group). Throws when the binding or submissions cannot be read.
  Future<({int neverSent, int maybeReceived})> pendingCounts() async {
    final token = (await _binding.current())?.localBindingId;
    if (token == null) return (neverSent: 0, maybeReceived: 0);
    var neverSent = 0, maybeReceived = 0;
    for (final row in await _submissions.unresolvedAll(
      kind: DeleteJobsManager.submissionKind,
    )) {
      int n;
      try {
        final body = jsonDecode(row.frozenBodyJson!) as Map<String, dynamic>;
        n = (body['targets'] as List).length;
      } catch (_) {
        n = 1; // unknown size: counted as one, never as zero
      }
      if (row.state == SubmissionState.prepared) {
        neverSent += n;
      } else {
        maybeReceived += n;
      }
    }
    return (neverSent: neverSent, maybeReceived: maybeReceived);
  }

  /// All unanswered deletion tracks (the Disconnect count).
  Future<int> pendingCount() async {
    final c = await pendingCounts();
    return c.neverSent + c.maybeReceived;
  }

  @override
  Future<String?> pendingLossSummary() async {
    final count = await pendingCount();
    return switch (count) {
      0 => null,
      1 => '1 deletion not yet confirmed',
      _ => '$count deletions not yet confirmed',
    };
  }
}
