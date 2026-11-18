import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

/// What happens to the upload and deletion records of an ended sign-in
/// (DEV-7-22, DEV-8-14). A log-out that keeps them remembers their token
/// ([keepForNextLogin]); the same user's next login or resume takes those rows
/// over ([takeOver]) and removes every other leftover. Settings' log-out
/// removes them ([removeAllBut]); a reset wipes them. Rows of another token
/// are fenced: the managers never read or send them, though the loss counts
/// and the reset sheets do read them. Local only; nothing on the server
/// changes.
class DeadSignInRecords {
  DeadSignInRecords({
    required AppDatabase db,
    required ServerBindingRepository binding,
    Future<SharedPreferences> Function()? prefs,
  }) : _db = db,
       _binding = binding,
       _prefs = prefs ?? SharedPreferences.getInstance;

  /// The preference naming the token whose records a log-out kept. The
  /// preferences wipe of a reset clears it.
  static const keptTokenKey = 'keptSignInToken';

  final AppDatabase _db;
  final ServerBindingRepository _binding;
  final Future<SharedPreferences> Function() _prefs;

  /// Remembers [token] as the one whose records the next same-user login
  /// takes over.
  Future<void> keepForNextLogin(String token) async {
    final prefs = await _prefs();
    if (!await prefs.setString(keptTokenKey, token)) {
      throw StateError('kept sign-in token could not be saved');
    }
  }

  /// Forgets the kept token (the records are being discarded).
  Future<void> forgetKept() async {
    final prefs = await _prefs();
    if (!await prefs.remove(keptTokenKey)) {
      throw StateError('kept sign-in token could not be removed');
    }
  }

  /// Deletes every `upload_intents` and `durable_submissions` row not of
  /// [currentToken], in one fenced transaction (a stale token throws
  /// `BindingFencedException` and deletes nothing). Only uploads and
  /// deletions write `durable_submissions`.
  Future<void> removeAllBut(String currentToken) =>
      _binding.runFenced(currentToken, () async {
        for (final table in const ['upload_intents', 'durable_submissions']) {
          await _db.customStatement(
            'DELETE FROM $table WHERE local_binding_id <> ?',
            [currentToken],
          );
        }
      });

  /// In one fenced transaction: gives the kept token's rows (if any, and not
  /// [currentToken]) to [currentToken], changing only `local_binding_id`, then
  /// deletes every row still of another token (discarded records, older
  /// leftovers). Then forgets the kept token. Idempotent.
  Future<void> takeOver(String currentToken) async {
    final prefs = await _prefs();
    final kept = prefs.getString(keptTokenKey);
    await _binding.runFenced(currentToken, () async {
      for (final table in const ['upload_intents', 'durable_submissions']) {
        if (kept != null && kept != currentToken) {
          await _db.customStatement(
            'UPDATE $table SET local_binding_id = ? WHERE local_binding_id = ?',
            [currentToken, kept],
          );
        }
        await _db.customStatement(
          'DELETE FROM $table WHERE local_binding_id <> ?',
          [currentToken],
        );
      }
    });
    if (kept != null) await forgetKept();
  }
}

final deadSignInRecordsProvider = Provider<DeadSignInRecords>(
  (ref) => DeadSignInRecords(
    db: ref.read(databaseProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    prefs: () => ref.read(sharedPreferencesProvider.future),
  ),
);
