// Refactor APP-DUP (section 6 #11; the owner, 2026-11-17: "follow the
// recommendation"): Possible duplicates and Deletion history say the real
// reason they cannot read from the server, instead of "needs a connection"
// for every reason. The session's block (what the banner shows) wins; then
// the reason the read was refused; "needs a connection" stays for the rest.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/services/library_tools_pages.dart';

void main() {
  group('libraryToolsUnreachable', () {
    const r = LibraryToolsUnreachable.values;
    final rows = <(ServerBlockedReason, BindingRefusal?, LibraryToolsUnreachable)>[
      (ServerBlockedReason.none, null, r[0]),
      (ServerBlockedReason.none, BindingRefusal.notYet, r[0]),
      (ServerBlockedReason.none, BindingRefusal.differentServer,
          LibraryToolsUnreachable.differentServer),
      (ServerBlockedReason.none, BindingRefusal.noSession,
          LibraryToolsUnreachable.signedOut),
      for (final refusal in [null, ...BindingRefusal.values])
        (ServerBlockedReason.differentServer, refusal,
            LibraryToolsUnreachable.differentServer),
      for (final refusal in [null, ...BindingRefusal.values])
        (ServerBlockedReason.signedOut, refusal,
            LibraryToolsUnreachable.signedOut),
    ];
    for (final (blocked, refusal, expected) in rows) {
      test('blocked ${blocked.name}, refused ${refusal?.name ?? '-'}: '
          '${expected.name}', () {
        expect(
          libraryToolsUnreachable(blocked: blocked, refusal: refusal),
          expected,
        );
      });
    }
  });

  test('the Possible duplicates sentences', () {
    expect(
      duplicatesUnreachableText(LibraryToolsUnreachable.needsConnection),
      'Possible duplicates needs a connection',
    );
    expect(
      duplicatesUnreachableText(LibraryToolsUnreachable.differentServer),
      'Possible duplicates is not available: a different server answers at '
      'this address.',
    );
    expect(
      duplicatesUnreachableText(LibraryToolsUnreachable.signedOut),
      'Possible duplicates is not available: you are signed out.',
    );
  });

  test('the Deletion history sentences', () {
    expect(
      deletionHistoryUnreachableText(LibraryToolsUnreachable.needsConnection),
      'Deletion history needs a connection.',
    );
    expect(
      deletionHistoryUnreachableText(LibraryToolsUnreachable.differentServer),
      'Deletion history is not available: a different server answers at '
      'this address.',
    );
    expect(
      deletionHistoryUnreachableText(LibraryToolsUnreachable.signedOut),
      'Deletion history is not available: you are signed out.',
    );
  });
}
