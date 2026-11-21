// What the uploads diagnostics row shows (SC-21, spec §7 para 3). Model
// state: counts of this binding's upload intents, plus rows left by an
// earlier sign-in, which are never sent.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';

@immutable
class UploadDiagnostics {
  const UploadDiagnostics({
    required this.pending,
    required this.quarantined,
    required this.earlierSignIn,
  });

  /// Files still to send: allocating, allocated, transferring, cancelling.
  final int pending;

  /// Files held back until the user acts: needs_reselect, source_changed,
  /// rejected.
  final int quarantined;

  /// Rows of any other binding.
  final int earlierSignIn;
}

/// Emits on every change to the upload intents; zeros without a binding.
final uploadDiagnosticsProvider = StreamProvider<UploadDiagnostics>((ref) async* {
  final db = ref.read(databaseProvider);
  final token = (await ref.read(serverBindingRepositoryProvider).current())
      ?.localBindingId;
  if (token == null) {
    yield const UploadDiagnostics(pending: 0, quarantined: 0, earlierSignIn: 0);
    return;
  }
  yield* db
      .customSelect(
        'SELECT local_binding_id, last_state, COUNT(*) AS n '
        'FROM upload_intents GROUP BY local_binding_id, last_state',
        readsFrom: {db.uploadIntents},
      )
      .watch()
      .map((rows) {
        var pending = 0, quarantined = 0, earlier = 0;
        for (final r in rows) {
          final n = r.read<int>('n');
          if (r.read<String>('local_binding_id') != token) {
            earlier += n;
          } else if (pendingStates.contains(r.read<String>('last_state'))) {
            pending += n;
          } else if (quarantinedStates.contains(r.read<String>('last_state'))) {
            quarantined += n;
          }
        }
        return UploadDiagnostics(
          pending: pending,
          quarantined: quarantined,
          earlierSignIn: earlier,
        );
      });
});
