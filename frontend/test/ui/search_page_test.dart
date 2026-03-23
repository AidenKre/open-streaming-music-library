import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await _seedSearchData(db);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets(
    'search artist and album cards expose queue actions on long press',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: SearchPage()),
        ),
      );

      await tester.enterText(find.byType(TextField), 'Search');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(ArtistCard), findsOneWidget);
      expect(find.byType(AlbumCard), findsOneWidget);

      await tester.longPress(find.byType(ArtistCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsOneWidget);
    },
  );
}

Future<void> _seedSearchData(AppDatabase db) async {
  await db.batch((batch) {
    batch.insert(
      db.artists,
      const ArtistsCompanion(id: Value(1), name: Value('Search Artist')),
    );
    batch.insert(
      db.albums,
      const AlbumsCompanion(
        id: Value(1),
        name: Value('Search Album'),
        artistId: Value(1),
        year: Value(2024),
        isSingleGrouping: Value(false),
      ),
    );
    batch.insert(
      db.tracks,
      const TracksCompanion(
        uuidId: Value('track-search-1'),
        createdAt: Value(1),
        lastUpdated: Value(1),
      ),
    );
    batch.insert(
      db.trackmetadata,
      const TrackmetadataCompanion(
        uuidId: Value('track-search-1'),
        title: Value('Search Song'),
        artist: Value('Search Artist'),
        album: Value('Search Album'),
        albumArtist: Value('Search Artist'),
        artistId: Value(1),
        albumId: Value(1),
        year: Value(2024),
        date: Value('2024-01-01'),
        genre: Value('Rock'),
        trackNumber: Value(1),
        discNumber: Value(1),
        codec: Value('flac'),
        duration: Value(180.0),
        bitrateKbps: Value(320.0),
        sampleRateHz: Value(44100),
        channels: Value(2),
        hasAlbumArt: Value(false),
      ),
    );
  });

  await db.customStatement("INSERT INTO fts_artists(fts_artists) VALUES('delete-all')");
  await db.customStatement(
    'INSERT INTO fts_artists(rowid, name) '
    'SELECT id, name FROM artists',
  );
  await db.customStatement("INSERT INTO fts_albums(fts_albums) VALUES('delete-all')");
  await db.customStatement(
    'INSERT INTO fts_albums(rowid, name, artist_name) '
    'SELECT a.id, COALESCE(a.name, \'\'), ar.name '
    'FROM albums a JOIN artists ar ON a.artist_id = ar.id',
  );
  await db.customStatement("INSERT INTO fts_tracks(fts_tracks) VALUES('delete-all')");
  await db.customStatement(
    'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
    'SELECT rowid, COALESCE(title, \'\'), COALESCE(artist, \'\'), COALESCE(album, \'\') '
    'FROM trackmetadata',
  );
}
