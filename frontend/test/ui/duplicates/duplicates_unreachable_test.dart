// Refactor APP-DUP (section 6 #11; the owner, 2026-11-17): while Possible
// duplicates cannot read from the server it says the real reason. A
// different server or a 401 sign-out turns the app offline (the session's
// block), so the offline path takes the session's reason; a read refused
// while online carries its own (BindingNotVerified.reason). Plain offline,
// or a connection not verified yet, still "needs a connection".
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/services/library_tools_pages.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../../helpers/fake_library_tools_api.dart';
import 'duplicates_test_support.dart';

/// Waits for verification never end on their own (no reload loop while a
/// scripted read keeps refusing).
class _HeldWaits extends FakeLibraryToolsApi {
  @override
  Future<void> whenVerified() => Completer<void>().future;
}

const _needs = 'Possible duplicates needs a connection';
const _different =
    'Possible duplicates is not available: a different server answers at '
    'this address.';
const _signedOut = 'Possible duplicates is not available: you are signed out.';

void main() {
  late DupHarness h;
  late _HeldWaits api;
  late ValueNotifier<ServerBlockedReason> blocked;

  setUp(() {
    api = _HeldWaits();
    h = DupHarness(api: api);
    h.pages['open']![null] = dupPage([dupPair('a1', 'b1')]);
    blocked = ValueNotifier(ServerBlockedReason.none);
  });

  tearDown(() => h.dispose());

  List<Override> overrides() => [
    libraryToolsServerBlockedProvider.overrideWith((ref) {
      void changed() => ref.invalidateSelf();
      blocked.addListener(changed);
      ref.onDispose(() => blocked.removeListener(changed));
      return blocked.value;
    }),
  ];

  void refuseWith(BindingRefusal reason) {
    api.onListDuplicates = (_, _, _) => throw BindingNotVerified(reason);
    api.onDuplicateSummary = () => throw BindingNotVerified(reason);
  }

  void expectNeedsConnection() {
    expect(h.dup.summaryLoad, DuplicatesLoad.needsConnection);
    expect(h.dup.listLoad, DuplicatesLoad.needsConnection);
  }

  group('offline', () {
    test('plain offline: needs a connection', () async {
      await h.open(isOffline: true, extra: overrides());
      expectNeedsConnection();
      expect(h.dup.unreachableText, _needs);
    });

    test('offline because a different server answers: says so', () async {
      blocked.value = ServerBlockedReason.differentServer;
      await h.open(isOffline: true, extra: overrides());
      expectNeedsConnection();
      expect(h.dup.unreachableText, _different);
    });

    test('offline because signed out: says so', () async {
      blocked.value = ServerBlockedReason.signedOut;
      await h.open(isOffline: true, extra: overrides());
      expectNeedsConnection();
      expect(h.dup.unreachableText, _signedOut);
    });

    test('the block arriving while the page shows its notice: the page is '
        'told and says the new reason', () async {
      await h.open(isOffline: true, extra: overrides());
      var notified = 0;
      h.dup.addListener(() => notified++);
      blocked.value = ServerBlockedReason.differentServer;
      await pumpEventQueue();
      expect(notified, greaterThan(0));
      expect(h.dup.unreachableText, _different);
      blocked.value = ServerBlockedReason.none;
      await pumpEventQueue();
      expect(h.dup.unreachableText, _needs);
    });
  });

  group('a read refused while online', () {
    test('not verified yet: needs a connection', () async {
      refuseWith(BindingRefusal.notYet);
      await h.open(extra: overrides());
      expectNeedsConnection();
      expect(h.dup.unreachableText, _needs);
    });

    test('a different server: says so', () async {
      refuseWith(BindingRefusal.differentServer);
      await h.open(extra: overrides());
      expectNeedsConnection();
      expect(h.dup.unreachableText, _different);
    });

    test('no session: signed out', () async {
      refuseWith(BindingRefusal.noSession);
      await h.open(extra: overrides());
      expectNeedsConnection();
      expect(h.dup.unreachableText, _signedOut);
    });

    test('the session\'s block wins over the refusal', () async {
      refuseWith(BindingRefusal.noSession);
      blocked.value = ServerBlockedReason.differentServer;
      await h.open(extra: overrides());
      expect(h.dup.unreachableText, _different);
    });

    test('a refusal\'s reason does not outlive a later plain-offline reload',
        () async {
      refuseWith(BindingRefusal.differentServer);
      await h.open(extra: overrides());
      expect(h.dup.unreachableText, _different);
      h.offline.set(true);
      await pumpEventQueue();
      await h.dup.refresh();
      await pumpEventQueue();
      expectNeedsConnection();
      expect(h.dup.unreachableText, _needs);
    });

    test('a refusal\'s reason does not outlive the app going offline, even '
        'before any reload (review B1)', () async {
      refuseWith(BindingRefusal.noSession);
      await h.open(extra: overrides());
      expect(h.dup.unreachableText, _signedOut);
      h.offline.set(true);
      await pumpEventQueue();
      expectNeedsConnection();
      expect(h.dup.unreachableText, _needs);
    });

    test('a refusal\'s reason does not outlive a refresh that is refused '
        'for another reason', () async {
      refuseWith(BindingRefusal.differentServer);
      await h.open(extra: overrides());
      refuseWith(BindingRefusal.notYet);
      await h.dup.refresh();
      await pumpEventQueue();
      expectNeedsConnection();
      expect(h.dup.unreachableText, _needs);
    });
  });

  // Retry cannot clear a different server or a sign-out; only the
  // banner's Reset, Disconnect or Log in can. A refusal alone, with the
  // session not blocked, keeps its Retry (the session may not have caught up).
  group('Retry helps only while the session is not blocked', () {
    test('blocked as a different server: Retry does not help', () async {
      blocked.value = ServerBlockedReason.differentServer;
      await h.open(isOffline: true, extra: overrides());
      expect(h.dup.unreachableText, _different);
      expect(h.dup.connectionRetryHelps, isFalse);
    });

    test('blocked as signed out: Retry does not help', () async {
      blocked.value = ServerBlockedReason.signedOut;
      await h.open(isOffline: true, extra: overrides());
      expect(h.dup.unreachableText, _signedOut);
      expect(h.dup.connectionRetryHelps, isFalse);
    });

    test('the block arriving while open, then clearing: Retry follows',
        () async {
      await h.open(isOffline: true, extra: overrides());
      expect(h.dup.connectionRetryHelps, isTrue);
      blocked.value = ServerBlockedReason.signedOut;
      await pumpEventQueue();
      expect(h.dup.connectionRetryHelps, isFalse);
      blocked.value = ServerBlockedReason.none;
      await pumpEventQueue();
      expect(h.dup.connectionRetryHelps, isTrue);
    });

    for (final reason in BindingRefusal.values) {
      test('only a refused read (${reason.name}): Retry helps', () async {
        refuseWith(reason);
        await h.open(extra: overrides());
        expectNeedsConnection();
        expect(h.dup.connectionRetryHelps, isTrue);
      });
    }

    test('plain offline (needs a connection): Retry helps', () async {
      await h.open(isOffline: true, extra: overrides());
      expect(h.dup.unreachableText, _needs);
      expect(h.dup.connectionRetryHelps, isTrue);
    });
  });
}
