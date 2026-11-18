import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';

import '../fake_library_actions.dart';

TrackUI _track(String uuid, {bool downloaded = false, bool damaged = false}) =>
    TrackUI(
  uuidId: uuid,
  filePath: downloaded ? '/f/$uuid' : null,
  damagedFilePath: damaged ? '/f/$uuid' : null,
  createdAt: 0,
  lastUpdated: 0,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

PlaybackAvailability _a(bool offline, int downloaded, int total) =>
    PlaybackAvailability.of(
      offline: offline,
      downloaded: downloaded,
      total: total,
    );

/// Records each call like [FakeLibraryActions], then fails the way a local
/// database error does (U30-A-01).
class _FailingActions extends FakeLibraryActions {
  @override
  Future<void> download(LibraryScope scope) async {
    await super.download(scope);
    throw StateError('database is locked');
  }

  @override
  Future<void> downloadAtQuality(LibraryScope scope, String quality) async {
    await super.downloadAtQuality(scope, quality);
    throw StateError('database is locked');
  }

  @override
  Future<void> deleteDownloads(LibraryScope scope) async {
    await super.deleteDownloads(scope);
    throw StateError('database is locked');
  }
}

/// `label` for an enabled action, `label (disabled)`, or `Download`.
List<String> _describe(List<LibraryMenuEntry> entries) => [
  for (final e in entries)
    switch (e) {
      LibraryMenuAction(:final label, :final onSelected) =>
        onSelected == null ? '$label (disabled)' : label,
      LibraryMenuDownload() => 'Download',
    },
];

void main() {
  late FakeLibraryActions actions;
  setUp(() => actions = FakeLibraryActions());

  const album = AlbumScope(artistId: 3, albumId: 7);

  testWidgets('short window: every menu action can be reached', (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showLibraryActionMenu(
          context,
          buildLibraryActionMenu(album, _a(false, 2, 4), actions: actions),
        ),
        child: const Text('Open menu'),
      ),
    ))));
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Delete downloads'));
    await tester.tap(find.text('Delete downloads'));
    await tester.pumpAndSettle();
    expect(actions.calls, ['deleteDownloads album(3,7)']);
  });

  group('collection menu (was LibraryCard._showMenu)', () {
    test('online, nothing downloaded: queue actions and Download', () {
      expect(
        _describe(buildLibraryActionMenu(album, _a(false, 0, 4),
            actions: actions)),
        ['Play Next', 'Add to Queue', 'Download'],
      );
    });

    test('partial: Download the rest and Delete downloads are both offered',
        () {
      expect(
        _describe(buildLibraryActionMenu(album, _a(false, 2, 4),
            actions: actions)),
        ['Play Next', 'Add to Queue', 'Download', 'Delete downloads'],
      );
    });

    // Phase 6 (O2 / DEV-6-02): a partial collection plays its downloads
    // offline.
    test('offline partial: queue actions enabled, no Download', () {
      expect(
        _describe(buildLibraryActionMenu(album, _a(true, 2, 4),
            actions: actions)),
        ['Play Next', 'Add to Queue', 'Delete downloads'],
      );
    });

    test('offline, nothing downloaded: queue actions disabled', () {
      expect(
        _describe(buildLibraryActionMenu(album, _a(true, 0, 4),
            actions: actions)),
        ['Play Next (disabled)', 'Add to Queue (disabled)'],
      );
    });

    test('offline unknown: not yet enabled and no delete claim', () {
      expect(
        _describe(buildLibraryActionMenu(
          album,
          const PlaybackAvailability.unknown(offline: true),
          actions: actions,
        )),
        ['Play Next (disabled)', 'Add to Queue (disabled)'],
      );
    });

    test('fully downloaded: no Download entry', () {
      expect(
        _describe(buildLibraryActionMenu(album, _a(true, 4, 4),
            actions: actions)),
        ['Play Next', 'Add to Queue', 'Delete downloads'],
      );
    });
  });

  group('track menu (was TrackTile._showTrackMenu)', () {
    test('Get info first, then queue actions, Download, then extras', () {
      final scope = TrackScope(_track('u1'));
      final entries = buildLibraryActionMenu(
        scope,
        _a(false, 0, 1),
        actions: actions,
        onGetInfo: () {},
        extraActions: [
          LibraryMenuAction(icon: Icons.transform, label: 'Convert…',
              onSelected: () {}),
        ],
      );
      expect(_describe(entries),
          ['Get Info', 'Play Next', 'Add to Queue', 'Download', 'Convert…']);
    });

    test('a downloaded track offers Delete download (singular)', () {
      final scope = TrackScope(_track('u1', downloaded: true));
      expect(
        _describe(buildLibraryActionMenu(scope, _a(true, 1, 1),
            actions: actions, onGetInfo: () {})),
        ['Get Info', 'Play Next', 'Add to Queue', 'Delete download'],
      );
    });

    // Decision 6: a damaged download offers its re-download (online) and
    // the Delete of the kept file in place of the plain Download row.
    test('a damaged download: re-download online, delete the kept file', () {
      final scope = TrackScope(_track('u1', damaged: true));
      final entries = buildLibraryActionMenu(scope, _a(false, 0, 1),
          actions: actions, onGetInfo: () {});
      expect(_describe(entries), [
        'Get Info',
        'Play Next',
        'Add to Queue',
        'Damaged download: re-download',
        'Delete damaged file',
      ]);
      for (final e in entries.whereType<LibraryMenuAction>().skip(3)) {
        e.onSelected!();
      }
      expect(actions.calls, ['download track(u1)', 'deleteDownloads track(u1)']);
    });

    test('a damaged download offline: the re-download needs the server', () {
      final scope = TrackScope(_track('u1', damaged: true));
      expect(
        _describe(buildLibraryActionMenu(scope, _a(true, 0, 1),
            actions: actions, onGetInfo: () {})),
        [
          'Get Info',
          'Play Next (disabled)',
          'Add to Queue (disabled)',
          'Damaged download: re-download (disabled)',
          'Delete damaged file',
        ],
      );
    });

    test('open detail comes first when the surface supplies it', () {
      expect(
        _describe(buildLibraryActionMenu(album, _a(false, 0, 1),
            actions: actions, onOpenDetail: () {})).first,
        'Go to album',
      );
      expect(
        _describe(buildLibraryActionMenu(const ArtistScope(artistId: 3),
            _a(false, 0, 1), actions: actions, onOpenDetail: () {})).first,
        'Go to artist',
      );
    });
  });

  test('every entry acts on the menu scope through the controller', () {
    final entries = buildLibraryActionMenu(album, _a(false, 2, 4),
        actions: actions);
    for (final e in entries) {
      switch (e) {
        case LibraryMenuAction(:final onSelected):
          onSelected!();
        case LibraryMenuDownload(:final onDownload, :final onDownloadAtQuality):
          onDownload();
          onDownloadAtQuality('128');
      }
    }
    expect(actions.calls, [
      'playNext album(3,7)',
      'addToQueue album(3,7)',
      'download album(3,7)',
      'downloadAtQuality album(3,7) 128',
      'deleteDownloads album(3,7)',
    ]);
  });

  group('showLibraryActionMenu (bottom sheet)', () {
    Future<void> open(WidgetTester tester, List<LibraryMenuEntry> entries) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLibraryActionMenu(context, entries),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('selecting an entry closes the sheet, then acts', (tester) async {
      await open(tester, buildLibraryActionMenu(album, _a(false, 0, 4),
          actions: actions));
      await tester.tap(find.text('Play Next'));
      await tester.pumpAndSettle();
      expect(find.text('Add to Queue'), findsNothing);
      expect(actions.calls, ['playNext album(3,7)']);
    });

    testWidgets('a disabled entry is shown but does nothing', (tester) async {
      await open(tester, buildLibraryActionMenu(album, _a(true, 0, 4),
          actions: actions));
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Play Next'),
      );
      expect(tile.enabled, isFalse);
      await tester.tap(find.text('Play Next'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(actions.calls, isEmpty);
      expect(find.text('Play Next'), findsOneWidget);
    });

    // U30-A-01: a Download or Delete that fails says so (it used to fail
    // silently, with an unhandled error); one that goes through says
    // nothing (downloads show their progress elsewhere).
    group('a failed Download or Delete is reported', () {
      // Sign-off s7-app-texts item 3: each row names what it queued. The
      // failure is a local fault of unknown cause, so no "Try again."
      const downloadsFailed = "Couldn't queue the downloads.";
      const downloadFailed = "Couldn't queue the download.";
      const redownloadFailed = "Couldn't queue re-download.";
      late _FailingActions failing;
      setUp(() => failing = _FailingActions());

      Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      testWidgets('Download', (tester) async {
        await open(tester,
            buildLibraryActionMenu(album, _a(false, 0, 4), actions: failing));
        await tapAndSettle(tester, find.text('Download'));
        expect(failing.calls, ['download album(3,7)']);
        expect(find.text(downloadsFailed), findsOneWidget);
      });

      testWidgets('Download at a chosen quality', (tester) async {
        await open(tester,
            buildLibraryActionMenu(album, _a(false, 0, 4), actions: failing));
        await tapAndSettle(tester, find.byTooltip('Choose quality'));
        await tapAndSettle(tester, find.text('128 kbps').last);
        expect(failing.calls, ['downloadAtQuality album(3,7) 128']);
        expect(find.text(downloadsFailed), findsOneWidget);
      });

      testWidgets('Download (one track)', (tester) async {
        final scope = TrackScope(_track('u1'));
        await open(tester,
            buildLibraryActionMenu(scope, _a(false, 0, 1), actions: failing));
        await tapAndSettle(tester, find.text('Download'));
        expect(failing.calls, ['download track(u1)']);
        expect(find.text(downloadFailed), findsOneWidget);
      });

      testWidgets('Download (one track) at a chosen quality', (tester) async {
        final scope = TrackScope(_track('u1'));
        await open(tester,
            buildLibraryActionMenu(scope, _a(false, 0, 1), actions: failing));
        await tapAndSettle(tester, find.byTooltip('Choose quality'));
        await tapAndSettle(tester, find.text('128 kbps').last);
        expect(failing.calls, ['downloadAtQuality track(u1) 128']);
        expect(find.text(downloadFailed), findsOneWidget);
      });

      testWidgets('Delete downloads', (tester) async {
        await open(tester,
            buildLibraryActionMenu(album, _a(false, 2, 4), actions: failing));
        await tapAndSettle(tester, find.text('Delete downloads'));
        expect(failing.calls, ['deleteDownloads album(3,7)']);
        expect(find.text("Couldn't delete the downloads."), findsOneWidget);
      });

      testWidgets('Delete download (one track)', (tester) async {
        final scope = TrackScope(_track('u1', downloaded: true));
        await open(tester,
            buildLibraryActionMenu(scope, _a(false, 1, 1), actions: failing));
        await tapAndSettle(tester, find.text('Delete download'));
        expect(failing.calls, ['deleteDownloads track(u1)']);
        expect(find.text("Couldn't delete the download."), findsOneWidget);
      });

      testWidgets('a damaged download: re-download', (tester) async {
        final scope = TrackScope(_track('u1', damaged: true));
        await open(tester,
            buildLibraryActionMenu(scope, _a(false, 0, 1), actions: failing));
        await tapAndSettle(tester, find.text('Damaged download: re-download'));
        expect(failing.calls, ['download track(u1)']);
        expect(find.text(redownloadFailed), findsOneWidget);
      });

      testWidgets('a damaged download: delete the kept file', (tester) async {
        final scope = TrackScope(_track('u1', damaged: true));
        await open(tester,
            buildLibraryActionMenu(scope, _a(false, 0, 1), actions: failing));
        await tapAndSettle(tester, find.text('Delete damaged file'));
        expect(failing.calls, ['deleteDownloads track(u1)']);
        expect(find.text("Couldn't delete the download."), findsOneWidget);
      });

      testWidgets('a Download or Delete that goes through shows no message',
          (tester) async {
        await open(tester,
            buildLibraryActionMenu(album, _a(false, 2, 4), actions: actions));
        await tapAndSettle(tester, find.text('Download'));
        await open(tester,
            buildLibraryActionMenu(album, _a(false, 2, 4), actions: actions));
        await tapAndSettle(tester, find.text('Delete downloads'));
        expect(actions.calls,
            ['download album(3,7)', 'deleteDownloads album(3,7)']);
        expect(find.byType(SnackBar), findsNothing);
      });
    });

    testWidgets('Download at a chosen quality closes the menu, then acts',
        (tester) async {
      await open(tester, buildLibraryActionMenu(album, _a(false, 0, 4),
          actions: actions));
      await tester.tap(find.byTooltip('Choose quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('128 kbps').last);
      await tester.pumpAndSettle();
      expect(find.text('Play Next'), findsNothing);
      expect(actions.calls, ['downloadAtQuality album(3,7) 128']);
    });
  });
}
