// Phase 9A.2a review r1 F2, F3 (spec §4 "sync freshness/pending-upload
// indicator"; unknown is not zero): the rule behind the statistics page's
// sync line. The pending count is the snapshot's own count of counted
// listens (never the diagnostics' count of every unsent event, which
// includes clicks); "all uploaded" is claimed only when the diagnostics are
// known and nothing is pending or failing.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/services/history/listening_sync_note.dart';

void main() {
  ListeningSyncNote note(HistoryDiagnostics? d, {int pending = 0}) =>
      ListeningSyncNote.of(diagnostics: d, pendingListens: pending);

  test('unknown diagnostics: no claim, but the snapshot count is known', () {
    final a = note(null);
    expect(a.allUploaded, isFalse);
    expect(a.syncProblem, isFalse);
    expect(a.serverWithoutSync, isFalse);
    expect(a.pendingListens, 0);
    expect(note(null, pending: 2).pendingListens, 2);
  });

  test('clean diagnostics and nothing pending: all uploaded', () {
    expect(note(const HistoryDiagnostics()).allUploaded, isTrue);
  });

  test('unsent clicks do not count as listens', () {
    final n = note(const HistoryDiagnostics(pending: 5));
    expect(n.pendingListens, 0);
    expect(n.allUploaded, isTrue);
  });

  test('pending listens are not all uploaded', () {
    final n = note(const HistoryDiagnostics(pending: 5), pending: 3);
    expect(n.pendingListens, 3);
    expect(n.allUploaded, isFalse);
  });

  for (final (name, d) in [
    ('a sync error', const HistoryDiagnostics(lastError: 'boom')),
    ('held-back events', const HistoryDiagnostics(quarantined: 1)),
    ('frozen listens', const HistoryDiagnostics(frozenListens: 1)),
    ('a listen recording error', const HistoryDiagnostics(listenError: 'x')),
  ]) {
    test('$name is a problem and never "all uploaded"', () {
      final n = note(d);
      expect(n.syncProblem, isTrue);
      expect(n.allUploaded, isFalse);
    });
  }

  test('a server without history sync says so instead of a problem', () {
    final n = note(
      const HistoryDiagnostics(waitingForServerSupport: true, lastError: 'x'),
    );
    expect(n.serverWithoutSync, isTrue);
    expect(n.syncProblem, isFalse);
    expect(n.allUploaded, isFalse);
  });
}
