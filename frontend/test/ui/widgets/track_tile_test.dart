import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import '../fake_library_actions.dart';

TrackUI _track({
  bool hasAlbumArt = false,
  int? coverArtId,
  String? filePath,
}) {
  return TrackUI(
    uuidId: 'test-uuid',
    filePath: filePath,
    createdAt: 1,
    lastUpdated: 1,
    title: 'Test Track',
    artist: 'Test Artist',
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: hasAlbumArt,
    coverArtId: coverArtId,
  );
}

void main() {
  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  /// The tile with the menu the real builder makes for it (Get info and the
  /// conversion rows included), acting through [actions].
  Widget buildTile(
    TrackUI track, {
    bool isHighlighted = false,
    bool offline = false,
    FakeLibraryActions? actions,
    VoidCallback? onGetInfo,
    VoidCallback? onConvert,
    VoidCallback? onCancelConvert,
    ConversionJob? conversionJob,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: TrackTile(
          track: track,
          isHighlighted: isHighlighted,
          conversionJob: conversionJob,
          menu: buildLibraryActionMenu(
            TrackScope(track),
            PlaybackAvailability.of(
              offline: offline,
              downloaded: track.isDownloaded ? 1 : 0,
              total: 1,
            ),
            actions: actions ?? FakeLibraryActions(),
            onGetInfo: onGetInfo ?? () {},
            extraActions: conversionMenuEntries(
              conversionJob: conversionJob,
              onConvert: onConvert,
              onCancelConvert: onCancelConvert,
            ),
          ),
        ),
      ),
    );
  }

  group('TrackTile cover art', () {
    testWidgets(
      'shows music note fallback when track has no cover art',
      (tester) async {
        await tester.pumpWidget(
          buildTile(_track(hasAlbumArt: false, coverArtId: null)),
        );

        expect(find.byIcon(Icons.music_note), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );

    testWidgets(
      'shows CoverArtImage when track has cover art',
      (tester) async {
        await tester.pumpWidget(
          buildTile(_track(hasAlbumArt: true, coverArtId: 42)),
        );

        expect(find.byType(CoverArtImage), findsOneWidget);
        expect(find.byType(Image), findsOneWidget);
      },
    );

    testWidgets(
      'highlighted track shows equalizer icon regardless of cover art',
      (tester) async {
        await tester.pumpWidget(
          buildTile(
            _track(hasAlbumArt: true, coverArtId: 42),
            isHighlighted: true,
          ),
        );

        expect(find.byIcon(Icons.equalizer), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      },
    );
  });

  group('TrackTile downloaded indicator', () {
    testWidgets('shows download_done icon when track is downloaded',
        (tester) async {
      await tester.pumpWidget(buildTile(_track(filePath: '/tmp/abc.audio')));

      expect(find.byIcon(Icons.download_done), findsOneWidget);
    });

    testWidgets('omits the icon when track is not downloaded', (tester) async {
      await tester.pumpWidget(buildTile(_track()));

      expect(find.byIcon(Icons.download_done), findsNothing);
    });
  });

  group('TrackTile context menu', () {
    testWidgets('Download menu item appears for un-downloaded tracks',
        (tester) async {
      final actions = FakeLibraryActions();
      await tester.pumpWidget(buildTile(_track(), actions: actions));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Delete download'), findsNothing);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['download track(test-uuid)']);
    });

    testWidgets('Delete download appears instead when track is downloaded',
        (tester) async {
      final actions = FakeLibraryActions();
      await tester.pumpWidget(
        buildTile(_track(filePath: '/tmp/abc.audio'), actions: actions),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Delete download'), findsOneWidget);
      expect(find.text('Download'), findsNothing);

      await tester.tap(find.text('Delete download'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['deleteDownloads track(test-uuid)']);
    });

    testWidgets('offline downloaded track: Delete download, no Download row',
        (tester) async {
      await tester.pumpWidget(
        buildTile(_track(filePath: '/tmp/abc.audio'), offline: true),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsNothing);
      expect(find.text('Delete download'), findsOneWidget);
    });

    testWidgets('split tile shows chevron icon in track menu', (tester) async {
      await tester.pumpWidget(buildTile(_track()));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('chevron in track menu opens quality sheet', (tester) async {
      final actions = FakeLibraryActions();
      await tester.pumpWidget(buildTile(_track(), actions: actions));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(find.text('Download quality'), findsOneWidget);
      expect(find.text('Original'), findsOneWidget);

      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['downloadAtQuality track(test-uuid) original']);
    });
  });

  testWidgets('Get Info is first and runs the surface\'s navigation',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(buildTile(_track(), onGetInfo: () => opened = true));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    final first = tester.widget<ListTile>(find.byType(ListTile).first);
    expect((first.title as Text).data, 'Get Info');
    await tester.tap(find.text('Get Info'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  group('TrackTile convert menu + badge', () {
    testWidgets('Convert… appears and calls onConvert when no job is active',
        (tester) async {
      var convertCalled = false;
      await tester.pumpWidget(buildTile(
        _track(),
        onConvert: () => convertCalled = true,
      ));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Convert…'), findsOneWidget);
      await tester.tap(find.text('Convert…'));
      await tester.pumpAndSettle();

      expect(convertCalled, isTrue);
    });

    testWidgets('omits Convert… when onConvert is null', (tester) async {
      await tester.pumpWidget(buildTile(_track()));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Convert…'), findsNothing);
    });

    testWidgets(
      'shows "Cancel conversion" instead of "Convert…" while a job is active',
      (tester) async {
        var cancelCalled = false;
        final job = ConversionJob.fromJson({
          'job_id': 1, 'uuid_id': 'test-uuid', 'target_codec': 'aac',
          'target_container': 'm4a', 'target_bitrate': 192,
          'status': 'running', 'error_text': null,
          'created_at': 1, 'updated_at': 1,
        });
        await tester.pumpWidget(buildTile(
          _track(),
            onConvert: () {},
          onCancelConvert: () => cancelCalled = true,
          conversionJob: job,
        ));

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();

        expect(find.text('Convert…'), findsNothing);
        expect(find.text('Cancel conversion'), findsOneWidget);

        await tester.tap(find.text('Cancel conversion'));
        await tester.pumpAndSettle();
        expect(cancelCalled, isTrue);
      },
    );

    testWidgets('shows an inline badge icon while a conversion is active',
        (tester) async {
      final job = ConversionJob.fromJson({
        'job_id': 1, 'uuid_id': 'test-uuid', 'target_codec': 'aac',
        'target_container': 'm4a', 'target_bitrate': 192,
        'status': 'running', 'error_text': null,
        'created_at': 1, 'updated_at': 1,
      });
      await tester.pumpWidget(buildTile(_track(), conversionJob: job));

      expect(find.byIcon(Icons.sync), findsOneWidget);
    });

    testWidgets('omits the badge once the job is terminal', (tester) async {
      final job = ConversionJob.fromJson({
        'job_id': 1, 'uuid_id': 'test-uuid', 'target_codec': 'aac',
        'target_container': 'm4a', 'target_bitrate': 192,
        'status': 'done', 'error_text': null,
        'created_at': 1, 'updated_at': 1,
      });
      await tester.pumpWidget(buildTile(_track(), conversionJob: job));

      expect(find.byIcon(Icons.sync), findsNothing);
    });
  });
}
