import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';

import '../fake_library_actions.dart';

TrackUI _track(String uuid, {bool downloaded = false}) => TrackUI(
  uuidId: uuid,
  filePath: downloaded ? '/f/$uuid' : null,
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

    test('offline partial: queue actions shown but disabled, no Download', () {
      expect(
        _describe(buildLibraryActionMenu(album, _a(true, 2, 4),
            actions: actions)),
        [
          'Play Next (disabled)',
          'Add to Queue (disabled)',
          'Delete downloads',
        ],
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
