import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';

/// The app's owned-file cleanup (sync tombstones, download deletes).
final ownedFileCleanupProvider = Provider<OwnedFileCleanup>((ref) {
  return OwnedFileCleanup(
    db: ref.read(databaseProvider),
    documentsDirectory: ref.read(downloadDirectoryProvider),
    clock: ref.read(clockProvider),
  );
});

/// The owned-file cleanup SingleFlightRunner (SC-13), quiesced with the scope.
final ownedFileCleanupRunnerProvider = Provider<SingleFlightRunner>((ref) {
  final runner = SingleFlightRunner(
    name: 'owned-file-cleanup',
    pass: ref.read(ownedFileCleanupProvider).runPass,
    backoff: BackoffSchedule(),
  );
  ref.onDispose(runner.quiesce);
  return runner;
});

/// How many owned-file cleanup rows are waiting (SC-21 diagnostics).
final ownedFileCleanupPendingCountProvider = StreamProvider<int>((ref) {
  final db = ref.read(databaseProvider);
  return db
      .customSelect(
        'SELECT COUNT(*) AS n FROM owned_file_cleanup',
        readsFrom: {db.ownedFileCleanupEntries},
      )
      .watchSingle()
      .map((row) => row.read<int>('n'));
});
