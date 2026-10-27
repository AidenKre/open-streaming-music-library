import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';

const _track = Track(
  uuidId: 'abc-123',
  filePath: '/local/path/song.flac',
  createdAt: 1700000000,
  lastUpdated: 1700001000,
);

const _trackNoFile = Track(
  uuidId: 'abc-123',
  filePath: null,
  createdAt: 1700000000,
  lastUpdated: 1700001000,
);

const _fullMeta = TrackmetadataData(
  uuidId: 'abc-123',
  title: 'My Song',
  artist: 'Artist Name',
  album: 'Album Name',
  albumArtist: 'Album Artist',
  year: 2023,
  date: '2023-06-15',
  genre: 'Rock',
  trackNumber: 3,
  discNumber: 1,
  codec: 'flac',
  duration: 245.5,
  bitrateKbps: 320.0,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: true,
  coverArtId: 42,
);

const _minimalMeta = TrackmetadataData(
  uuidId: 'abc-123',
  duration: 100.0,
  bitrateKbps: 128.0,
  sampleRateHz: 48000,
  channels: 1,
  hasAlbumArt: false,
);

void main() {
  group('TrackUI.fromDrift', () {
    group('Track fields', () {
      test('maps uuidId', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.uuidId, 'abc-123');
      });

      test('maps filePath', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.filePath, '/local/path/song.flac');
      });

      test('maps createdAt', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.createdAt, 1700000000);
      });

      test('maps lastUpdated', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.lastUpdated, 1700001000);
      });
    });

    group('Trackmetadata fields', () {
      test('maps all metadata fields from full meta', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);

        expect(ui.title, 'My Song');
        expect(ui.artist, 'Artist Name');
        expect(ui.album, 'Album Name');
        expect(ui.albumArtist, 'Album Artist');
        expect(ui.year, 2023);
        expect(ui.date, '2023-06-15');
        expect(ui.genre, 'Rock');
        expect(ui.trackNumber, 3);
        expect(ui.discNumber, 1);
        expect(ui.codec, 'flac');
        expect(ui.duration, 245.5);
        expect(ui.bitrateKbps, 320.0);
        expect(ui.sampleRateHz, 44100);
        expect(ui.channels, 2);
        expect(ui.hasAlbumArt, true);
      });

      test('nullable fields are null when absent', () {
        final ui = TrackUI.fromDrift(_track, _minimalMeta);

        expect(ui.title, isNull);
        expect(ui.artist, isNull);
        expect(ui.album, isNull);
        expect(ui.albumArtist, isNull);
        expect(ui.year, isNull);
        expect(ui.date, isNull);
        expect(ui.genre, isNull);
        expect(ui.trackNumber, isNull);
        expect(ui.discNumber, isNull);
        expect(ui.codec, isNull);
      });

      test('maps required fields from minimal meta', () {
        final ui = TrackUI.fromDrift(_track, _minimalMeta);

        expect(ui.duration, 100.0);
        expect(ui.bitrateKbps, 128.0);
        expect(ui.sampleRateHz, 48000);
        expect(ui.channels, 1);
        expect(ui.hasAlbumArt, false);
      });
    });
  });

  group('isDownloaded', () {
    test('returns true when filePath is non-null', () {
      final ui = TrackUI.fromDrift(_track, _fullMeta);
      expect(ui.isDownloaded, true);
    });

    test('returns false when filePath is null', () {
      final ui = TrackUI.fromDrift(_trackNoFile, _fullMeta);
      expect(ui.isDownloaded, false);
    });
  });

  group('formattedDuration', () {
    test('formats seconds only', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 0.0),
      );
      expect(ui.formattedDuration, '0:00');
    });

    test('truncates fractional seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 59.9),
      );
      expect(ui.formattedDuration, '0:59');
    });

    test('formats minutes and seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 65.0),
      );
      expect(ui.formattedDuration, '1:05');
    });

    test('formats hours, minutes, and seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 3661.0),
      );
      expect(ui.formattedDuration, '1:01:01');
    });

    test('formats days, hours, minutes, and seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 90061.0),
      );
      expect(ui.formattedDuration, '1:01:01:01');
    });
  });

  group('TrackUI.fromQueryRow', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('maps all fields correctly via DB round-trip', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'qr-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'revision': 1,
        'metadata': {
          'title': 'My Song',
          'artist': 'Artist Name',
          'album': 'Album Name',
          'album_artist': 'Album Artist',
          'year': 2023,
          'date': '2023-06-15',
          'genre': 'Rock',
          'track_number': 3,
          'disc_number': 1,
          'codec': 'flac',
          'duration': 245.5,
          'bitrate_kbps': 320.0,
          'sample_rate_hz': 44100,
          'channels': 2,
          'has_album_art': true,
        },
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));

      final rows = await db.getTracks(
        orderBy: [OrderParameter(column: 'uuid_id')],
      );
      expect(rows.length, 1);

      final ui = TrackUI.fromQueryRow(rows.first);
      expect(ui.uuidId, 'qr-1');
      expect(ui.filePath, isNull);
      expect(ui.createdAt, 1700000000);
      expect(ui.lastUpdated, 1700001000);
      expect(ui.title, 'My Song');
      expect(ui.artist, 'Artist Name');
      expect(ui.album, 'Album Name');
      expect(ui.albumArtist, 'Album Artist');
      expect(ui.year, 2023);
      expect(ui.date, '2023-06-15');
      expect(ui.genre, 'Rock');
      expect(ui.trackNumber, 3);
      expect(ui.discNumber, 1);
      expect(ui.codec, 'flac');
      expect(ui.duration, 245.5);
      expect(ui.bitrateKbps, 320.0);
      expect(ui.sampleRateHz, 44100);
      expect(ui.channels, 2);
      expect(ui.hasAlbumArt, true);
    });

    test('maps coverArtId via DB round-trip', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'qr-cover-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'revision': 1,
        'metadata': {
          'title': 'Cover Song',
          'artist': 'Artist',
          'duration': 100.0,
          'bitrate_kbps': 128.0,
          'sample_rate_hz': 44100,
          'channels': 2,
          'has_album_art': true,
          'cover_art_id': 55,
        },
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));

      final rows = await db.getTracks(
        orderBy: [OrderParameter(column: 'uuid_id')],
      );
      final ui = TrackUI.fromQueryRow(rows.first);
      expect(ui.coverArtId, 55);
    });

    test('coverArtId is null when not set via DB round-trip', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'qr-no-cover-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'revision': 1,
        'metadata': {
          'duration': 100.0,
          'bitrate_kbps': 128.0,
          'sample_rate_hz': 44100,
          'channels': 2,
          'has_album_art': false,
        },
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));

      final rows = await db.getTracks(
        orderBy: [OrderParameter(column: 'uuid_id')],
      );
      final ui = TrackUI.fromQueryRow(rows.first);
      expect(ui.coverArtId, isNull);
    });
  });

  group('coverArtId fromDrift', () {
    test('maps coverArtId from metadata', () {
      final ui = TrackUI.fromDrift(_track, _fullMeta);
      expect(ui.coverArtId, 42);
    });

    test('coverArtId is null from minimal metadata', () {
      final ui = TrackUI.fromDrift(_track, _minimalMeta);
      expect(ui.coverArtId, isNull);
    });
  });

  group('isStaleDownload', () {
    TrackUI downloaded({
      int? revision,
      int? downloadedAtRevision,
      int? staleDismissedAtRevision,
    }) => TrackUI(
      uuidId: 'abc',
      filePath: '/local/path/song.flac',
      createdAt: 0,
      lastUpdated: 0,
      revision: revision,
      duration: 1.0,
      bitrateKbps: 320.0,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
      downloadedAtRevision: downloadedAtRevision,
      staleDismissedAtRevision: staleDismissedAtRevision,
    );

    test('false when not downloaded', () {
      final ui = TrackUI(
        uuidId: 'abc',
        createdAt: 0,
        lastUpdated: 0,
        revision: 5,
        duration: 1.0,
        bitrateKbps: 320.0,
        sampleRateHz: 44100,
        channels: 2,
        hasAlbumArt: false,
        downloadedAtRevision: 1,
      );
      expect(ui.isStaleDownload, isFalse);
    });

    test('false when revision or downloadedAtRevision is unknown', () {
      expect(downloaded(revision: null, downloadedAtRevision: 1).isStaleDownload, isFalse);
      expect(downloaded(revision: 5, downloadedAtRevision: null).isStaleDownload, isFalse);
    });

    test('false when revision has not advanced past downloadedAtRevision', () {
      expect(downloaded(revision: 5, downloadedAtRevision: 5).isStaleDownload, isFalse);
      expect(downloaded(revision: 4, downloadedAtRevision: 5).isStaleDownload, isFalse);
    });

    test('true when revision advanced past downloadedAtRevision', () {
      expect(downloaded(revision: 6, downloadedAtRevision: 5).isStaleDownload, isTrue);
    });

    test('false once dismissed at the current revision', () {
      expect(
        downloaded(revision: 6, downloadedAtRevision: 5, staleDismissedAtRevision: 6)
            .isStaleDownload,
        isFalse,
      );
    });

    test('re-arms when revision climbs again after a dismiss', () {
      expect(
        downloaded(revision: 7, downloadedAtRevision: 5, staleDismissedAtRevision: 6)
            .isStaleDownload,
        isTrue,
      );
    });

    test(
      'agrees with the SQL staleDownloadPredicate over every null/ordering '
      'combination',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        const values = <int?>[null, 4, 5, 6];
        var i = 0;
        final expected = <String, bool>{};
        for (final hasFile in [true, false]) {
          for (final rev in values) {
            for (final dl in values) {
              for (final dismissed in values) {
                final uuid = 'u${i++}';
                await db.customStatement(
                  'INSERT INTO tracks (uuid_id, created_at, last_updated, '
                  'revision, file_path, downloaded_at_revision, '
                  'stale_dismissed_at_revision) VALUES (?, 0, 0, ?, ?, ?, ?)',
                  [uuid, rev, hasFile ? '/f/$uuid' : null, dl, dismissed],
                );
                await db.customStatement(
                  'INSERT INTO trackmetadata (uuid_id, duration, '
                  'bitrate_kbps, sample_rate_hz, channels) '
                  'VALUES (?, 1, 1, 1, 2)',
                  [uuid],
                );
                expected[uuid] = TrackUI(
                  uuidId: uuid,
                  filePath: hasFile ? '/f/$uuid' : null,
                  createdAt: 0,
                  lastUpdated: 0,
                  revision: rev,
                  duration: 1,
                  bitrateKbps: 1,
                  sampleRateHz: 1,
                  channels: 2,
                  hasAlbumArt: false,
                  downloadedAtRevision: dl,
                  staleDismissedAtRevision: dismissed,
                ).isStaleDownload;
              }
            }
          }
        }

        final sqlStale = {
          for (final r in await db.watchStaleDownloads().first)
            r.read<String>('uuid_id'),
        };
        final dartStale = {
          for (final e in expected.entries)
            if (e.value) e.key,
        };
        expect(dartStale, isNotEmpty);
        expect(sqlStale, dartStale);
        // And every row the SQL returns maps to a TrackUI that agrees.
        for (final r in await db.watchStaleDownloads().first) {
          expect(TrackUI.fromQueryRow(r).isStaleDownload, isTrue);
        }
      },
    );
  });
}
