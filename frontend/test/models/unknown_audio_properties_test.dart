// SC-16l client side: duration, sample rate and channels are nullable end to
// end (wire DTO -> Drift -> TrackUI -> views / OS media item). Unknown is
// shown as "—", never as 0.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/dto/track_metadata_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/ui/get_info_page.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

const _knownJson = {
  'title': 't',
  'codec': 'flac',
  'duration': 61.5,
  'bitrate_kbps': 900.0,
  'sample_rate_hz': 48000,
  'channels': 2,
  'has_album_art': false,
};

Map<String, dynamic> _unknownJson() => {
  ..._knownJson,
  'duration': null,
  'sample_rate_hz': null,
  'channels': null,
};

const _track = Track(
  uuidId: 'u-unknown',
  filePath: null,
  createdAt: 1,
  lastUpdated: 2,
);

const _meta = TrackmetadataData(
  uuidId: 'u-unknown',
  title: 'Unknown Props',
  artist: 'A',
  codec: 'flac',
  duration: 61.5,
  bitrateKbps: 900,
  sampleRateHz: 48000,
  channels: 2,
  hasAlbumArt: false,
);

TrackUI _unknownTrack() => TrackUI.fromDrift(
  _track,
  _meta.copyWith(
    duration: const Value(null),
    sampleRateHz: const Value(null),
    channels: const Value(null),
  ),
);

class _StubOffline extends OfflineModeNotifier {
  @override
  bool build() => true;
}

void main() {
  group('wire DTO', () {
    test('null audio properties parse as null', () {
      final dto = TrackMetadataDto.fromJson(_unknownJson());
      expect(dto.duration, isNull);
      expect(dto.sampleRateHz, isNull);
      expect(dto.channels, isNull);
    });

    test('known values still parse', () {
      final dto = TrackMetadataDto.fromJson(Map.of(_knownJson));
      expect(dto.duration, 61.5);
      expect(dto.sampleRateHz, 48000);
      expect(dto.channels, 2);
    });

    test('a synced unknown track is stored as NULL, not 0', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'u1',
        'metadata': _unknownJson(),
        'created_at': 1,
        'last_updated': 2,
        'revision': 3,
      });
      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
      final row = await db
          .customSelect(
            'SELECT duration, sample_rate_hz, channels FROM trackmetadata',
          )
          .getSingle();
      expect(row.data, {
        'duration': null,
        'sample_rate_hz': null,
        'channels': null,
      });
    });
  });

  group('TrackUI', () {
    test('fromDrift keeps unknown as null', () {
      final ui = _unknownTrack();
      expect(ui.duration, isNull);
      expect(ui.sampleRateHz, isNull);
      expect(ui.channels, isNull);
    });

    test('fromQueryRow keeps unknown as null', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.into(db.tracks).insert(_track.toCompanion(true));
      await db.into(db.trackmetadata).insert(
        _meta
            .copyWith(
              duration: const Value(null),
              sampleRateHz: const Value(null),
              channels: const Value(null),
            )
            .toCompanion(true),
      );
      final row = await db
          .customSelect(
            'SELECT t.*, tm.* FROM tracks t '
            'JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id',
          )
          .getSingle();
      final ui = TrackUI.fromQueryRow(row);
      expect(ui.duration, isNull);
      expect(ui.sampleRateHz, isNull);
      expect(ui.channels, isNull);
    });

    test('formattedDuration shows an em dash for unknown', () {
      expect(_unknownTrack().formattedDuration, '—');
    });

    test('a real zero duration is still formatted as 0:00', () {
      final ui = TrackUI.fromDrift(
        _track,
        _meta.copyWith(duration: const Value(0.0)),
      );
      expect(ui.formattedDuration, '0:00');
    });
  });

  testWidgets('Get info shows unknown properties as —', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appInfoProvider.overrideWith((ref) async => defaultAppInfo()),
          offlineModeProvider.overrideWith(_StubOffline.new),
        ],
        child: MaterialApp(home: GetInfoPage(track: _unknownTrack())),
      ),
    );
    await tester.pumpAndSettle();

    Finder rowValue(String label) => find.descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byType(Row),
      ),
      matching: find.text('—'),
    );
    expect(rowValue('Duration'), findsOneWidget);
    expect(rowValue('Sample rate'), findsOneWidget);
    expect(rowValue('Channels'), findsOneWidget);
    expect(find.textContaining('null'), findsNothing);
    expect(find.text('0 Hz'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TrackTile shows an unknown duration as —', (tester) async {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TrackTile(track: _unknownTrack())),
      ),
    );
    expect(find.text('—'), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('OS media item duration is null when unknown', () async {
    final bridge = AudioServiceBridge();
    bridge.updateNowPlaying(_unknownTrack());
    expect(bridge.mediaItem.value?.id, 'u-unknown');
    expect(bridge.mediaItem.value?.duration, isNull);
  });
}
