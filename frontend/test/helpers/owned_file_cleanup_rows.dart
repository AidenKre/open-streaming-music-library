import 'package:frontend/database/database.dart';

/// The rows of the owned-file clean-up queue, oldest first, with only
/// [columns] (each test compares the columns it is about).
Future<List<Map<String, Object?>>> ownedFileCleanupRows(
  AppDatabase db,
  List<String> columns,
) async => [
  for (final r in await db
      .customSelect(
        'SELECT ${columns.join(', ')} FROM owned_file_cleanup ORDER BY id',
      )
      .get())
    r.data,
];

/// How many paths wait in the owned-file clean-up queue.
Future<int> pendingOwnedFileCleanups(AppDatabase db) async => (await db
        .customSelect('SELECT COUNT(*) AS n FROM owned_file_cleanup')
        .getSingle())
    .read<int>('n');
