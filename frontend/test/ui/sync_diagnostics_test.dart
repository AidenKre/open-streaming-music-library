// SC-21 (Phase 5 §4): Settings "Sync & storage" with the history diagnostics
// row, and the diagnostics page (SessionDestination.syncDiagnostics). Views
// only show model state and send input to SyncDiagnosticsControls (SC-26).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings/sync_diagnostics_controller.dart';
import 'package:frontend/ui/settings/sync_diagnostics_page.dart';
import 'package:frontend/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_session_controls.dart';
import 'browse_harness.dart' show teardownTree;
import '../helpers/test_credentials.dart';
import '../helpers/test_offline.dart';

class _FakeControls implements SyncDiagnosticsControls {
  final calls = <String>[];
  @override
  Future<void> retryHistory() async => calls.add('retry');
  @override
  Future<void> keepServerVersion(HistoryServerEvent server) async =>
      calls.add('keep ${server.payload.eventUuid}@${server.revision}');
}

HistoryEventPayload _payload(double seconds) => HistoryEventPayload(
  eventUuid: 'mine',
  kind: 'play',
  entityType: 'track',
  entityRef: 'track-abc',
  occurredAt: 1000,
  secondsPlayed: seconds,
);

final _conflict = (
  local: _payload(30.5),
  server: HistoryServerEvent(payload: _payload(99), revision: 5, receivedAt: 7),
);

void main() {
  late _FakeControls controls;

  Future<void> pump(
    WidgetTester tester,
    HistoryDiagnostics diagnostics, {
    Widget? home,
  }) async {
    addTearDown(() => teardownTree(tester));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    controls = _FakeControls();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWith((_) async => prefs),
        credentialStoreTestOverride(),
        offlineModeProvider.overrideWith(() => TestOffline(false)),
        sessionControlsProvider.overrideWithValue(FakeSessionControls()),
        historyDiagnosticsProvider.overrideWith((ref) => Stream.value(diagnostics)),
        syncDiagnosticsControlsProvider.overrideWithValue(controls),
      ],
      child: MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: home ?? const SessionHost(root: SettingsPage()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> toRow(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('History sync'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  group('Settings row', () {
    for (final (label, diag, summary) in <(String, HistoryDiagnostics, String)>[
      ('caught up', const HistoryDiagnostics(), 'Up to date'),
      ('pending', const HistoryDiagnostics(pending: 3), '3 events waiting to upload'),
      ('held back', const HistoryDiagnostics(quarantined: 2), '2 events held back'),
      ('waiting', const HistoryDiagnostics(waitingForServerSupport: true, pending: 4),
          'Waiting for server history support'),
      ('conflict', HistoryDiagnostics(conflicts: [_conflict]), '1 conflict needs your choice'),
      ('restored', const HistoryDiagnostics(serverRegressed: true, pending: 1),
          'Server history looks restored'),
      ('error', const HistoryDiagnostics(lastError: 'boom'), 'Last sync failed'),
      ('listen not saved', const HistoryDiagnostics(listenError: 'disk full'),
          'A listen could not be saved'),
      ('frozen listens', const HistoryDiagnostics(frozenListens: 2),
          '2 listens waiting to be saved'),
    ]) {
      testWidgets('summarizes: $label', (tester) async {
        await pump(tester, diag);
        // Phase 9's Home section sits above: bring the row into the lazy list
        // before looking for its section title.
        await toRow(tester);
        expect(find.text('Sync & storage'), findsOneWidget);
        expect(find.text(summary), findsOneWidget);
      });
    }

    testWidgets('opens the diagnostics page', (tester) async {
      await pump(tester, const HistoryDiagnostics(pending: 3));
      await toRow(tester);
      await tester.tap(find.text('History sync'));
      await tester.pumpAndSettle();
      expect(find.byType(SyncDiagnosticsPage), findsOneWidget);
    });
  });

  group('diagnostics page', () {
    Future<void> page(WidgetTester tester, HistoryDiagnostics d) =>
        pump(tester, d, home: const SyncDiagnosticsPage());

    // Pre-merge review A5-06: the raw error text is not a sentence; the
    // page says the sync failed (the row's own sentence).
    testWidgets('shows counts and that the last sync failed, never the raw '
        "error; Retry is the controller's", (tester) async {
      await page(tester, const HistoryDiagnostics(
        pending: 3, quarantined: 2,
        lastError: 'ApiException(500): {"detail":"boom"}',
      ));
      expect(find.textContaining('Waiting to upload: 3'), findsOneWidget);
      expect(find.textContaining('Held back: 2'), findsOneWidget);
      expect(find.text('Last sync failed'), findsOneWidget);
      expect(find.textContaining('ApiException'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(controls.calls, ['retry']);
    });

    testWidgets('listen recording failures and the checkpoint limitation are '
        'shown (Phase 5 §7)', (tester) async {
      await page(tester, const HistoryDiagnostics(
        frozenListens: 1, listenError: 'Bad state: disk full',
      ));
      expect(find.textContaining('Listens waiting to be saved: 1'),
          findsOneWidget);
      // Pre-merge review A5-06: the row's sentence, not the raw error.
      expect(find.text('A listen could not be saved'), findsOneWidget);
      expect(find.textContaining('Bad state'), findsNothing);
      expect(find.textContaining('last 5 seconds'), findsOneWidget);
    });

    testWidgets('waiting for server support is explained, not "offline"',
        (tester) async {
      await page(tester, const HistoryDiagnostics(waitingForServerSupport: true));
      expect(find.textContaining('Waiting for server history support'), findsOneWidget);
      expect(find.textContaining('offline'), findsNothing);
    });

    testWidgets('a restored server explains the recovery path (D17)',
        (tester) async {
      await page(tester, const HistoryDiagnostics(serverRegressed: true));
      expect(find.textContaining('restored'), findsWidgets);
      expect(find.textContaining('Disconnect'), findsOneWidget);
      expect(find.textContaining('best effort'), findsOneWidget);
      expect(find.textContaining('other clients'), findsOneWidget);
    });

    testWidgets('a conflict shows both versions; keeping the server version '
        'asks first', (tester) async {
      await page(tester, HistoryDiagnostics(conflicts: [_conflict]));
      expect(find.textContaining('30.5'), findsOneWidget);
      expect(find.textContaining('99'), findsOneWidget);
      // Pre-merge review A5-06: never the track's internal reference.
      expect(find.textContaining('track-abc'), findsNothing);
      expect(find.textContaining('Unknown track'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'Keep server version'));
      await tester.pumpAndSettle();
      expect(controls.calls, isEmpty, reason: 'confirmation first');
      expect(find.text("Keep the server's version?"), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Keep server version').last);
      await tester.pumpAndSettle();
      expect(controls.calls, ['keep mine@5']);
    });

    testWidgets('a conflict card names the track by title and artist, never '
        'its id', (tester) async {
      await page(tester, HistoryDiagnostics(
        conflicts: [_conflict],
        trackNames: const {'track-abc': 'Aria — Artist 01'},
      ));
      expect(find.textContaining('Aria — Artist 01'), findsNWidgets(2));
      expect(find.textContaining('track-abc'), findsNothing);
    });

    testWidgets('cancelling the confirmation keeps the conflict', (tester) async {
      await page(tester, HistoryDiagnostics(conflicts: [_conflict]));
      await tester.tap(find.widgetWithText(FilledButton, 'Keep server version'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controls.calls, isEmpty);
    });

    testWidgets('summaries expose conflicts in type, timestamp and duration', (tester) async {
      const server = HistoryServerEvent(
        payload: HistoryEventPayload(
          eventUuid: 'mine', kind: 'play', entityType: 'future-type',
          entityRef: 'track-abc', occurredAt: 2000,
          secondsPlayed: 30.5, trackLength: 100,
        ),
        revision: 5, receivedAt: 7,
      );
      await page(tester, HistoryDiagnostics(conflicts: [
        (local: _payload(30.5), server: server),
      ]));
      expect(find.textContaining('future-type'), findsOneWidget);
      expect(find.textContaining('1970-01-01T00:00:01.000Z'), findsOneWidget);
      expect(find.textContaining('1970-01-01T00:00:02.000Z'), findsOneWidget);
      expect(find.textContaining('track length: unknown'), findsOneWidget);
      // Other-issues row 33: a whole number of seconds reads like the
      // seconds played ("100 s", not "100.0 s").
      expect(find.textContaining('track length: 100 s'), findsOneWidget);
      expect(find.textContaining('100.0 s'), findsNothing);
      expect(controls.calls, isEmpty);
    });
  });
}
