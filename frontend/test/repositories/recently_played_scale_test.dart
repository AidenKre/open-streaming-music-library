// Plan decision O5: no new index for the recents CTE. This scale check
// seeds 20,000 clicked rows and holds the Home read (eligibility + hydration
// of 20) under a stated budget, printing the measured time for the record.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';

import '../helpers/server_binding.dart';
import 'catalog_seed.dart';

/// Median page read budget (in-memory SQLite). Measured medians are about
/// 15-18 ms; 1 s only catches a gross regression (for example a per-card
/// query) and leaves a loaded CI machine ample headroom (6-R1-11).
const _budget = Duration(seconds: 1);

void main() {
  test('20,000 clicked rows: a Home page reads within budget', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final seed = CatalogSeed(db);
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    const albums = 100;
    const tracksPerAlbum = 10;
    for (var a = 1; a <= albums; a++) {
      await seed.artist(a, 'Artist $a');
      await seed.album(a, artistId: a, name: 'Album $a');
    }
    await db.transaction(() async {
      for (var a = 1; a <= albums; a++) {
        for (var n = 0; n < tracksPerAlbum; n++) {
          await seed.track(
            't$a-$n',
            artistId: a,
            albumId: a,
            trackNumber: n + 1,
            downloaded: n == 0,
          );
        }
      }
    });
    // 20,000 rows: 18,000 track clicks (18 repeats each over 1,000 tracks),
    // 1,000 album and artist clicks, and 1,000 invalid refs newest.
    await db.batch((b) {
      var i = 0;
      HistoryEventsCompanion row(String type, String ref, int at) =>
          HistoryEventsCompanion.insert(
            eventUuid: 'ev-${(i++).toString().padLeft(6, '0')}',
            kind: 'clicked',
            entityType: type,
            entityRef: ref,
            occurredAt: at,
            pendingUpload: false,
          );
      final rows = <HistoryEventsCompanion>[];
      for (var k = 0; k < 18000; k++) {
        final t = k % (albums * tracksPerAlbum);
        rows.add(row('track', 't${t ~/ tracksPerAlbum + 1}-${t % tracksPerAlbum}', k));
      }
      for (var k = 0; k < 1000; k++) {
        final id = k % albums + 1;
        rows.add(row(k.isEven ? 'album' : 'artist', 'srv-1:$id', 18000 + k));
      }
      for (var k = 0; k < 1000; k++) {
        rows.add(row('album', 'srv-1:0$k', 100000 + k));
      }
      b.insertAll(db.historyEvents, rows);
    });
    final count = await db
        .customSelect("SELECT COUNT(*) AS c FROM history_events "
            "WHERE kind = 'clicked'")
        .getSingle();
    expect(count.read<int>('c'), 20000);

    final repo = RecentlyPlayedRepository(db, BrowseRepository(db));
    final boundary = (await db
            .customSelect('SELECT MAX(local_id) AS m FROM history_events')
            .getSingle())
        .read<int>('m');

    Future<Duration> timed(bool downloadedOnly) async {
      final sw = Stopwatch()..start();
      final got = await repo.page(
        boundaryLocalId: boundary,
        limit: 20,
        downloadedOnly: downloadedOnly,
      );
      sw.stop();
      expect(got, hasLength(20));
      return sw.elapsed;
    }

    for (final downloadedOnly in [false, true]) {
      await timed(downloadedOnly); // warm-up
      final runs = [for (var r = 0; r < 5; r++) await timed(downloadedOnly)]
        ..sort();
      final median = runs[2];
      // ignore: avoid_print
      print('6B.1 scale (20k clicked, downloadedOnly: $downloadedOnly): '
          'median ${median.inMicroseconds / 1000} ms, '
          'runs ${runs.map((d) => d.inMicroseconds / 1000).join(', ')} ms '
          '(budget ${_budget.inMilliseconds} ms)');
      expect(median, lessThan(_budget));
    }
  });
}
