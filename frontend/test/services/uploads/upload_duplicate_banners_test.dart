// Phase 7B.2d S2: the per-item duplicate banners, library part (model,
// pure; the view only renders them). Spec §7 Duplicate UX (user decisions
// 2026-10-29), driven by `duplicate_check` only, never by client guessing:
//  * Display caps: "Each banner shows at most five matches per kind, with
//    '+N more' opening the full list."
//  * Exact match banner: "This audio is already in your library". It shows
//    the existing track (title, artist, album, format, bitrate, duration)
//    next to the staged file's detected values. Primary action Use existing
//    track; secondary Import as separate track; until one is picked Confirm
//    and Skip are disabled (an explicit decision is required).
//  * Fingerprint match banner: "Possibly the same song as *Title — Artist*
//    (FLAC, 4:12)", or "Very likely the same recording" for the `strong`
//    band. Advisory (thresholds provisional, DEV-6.5-04): never a required
//    decision. `Don't import` "resolves to the best match".
// Unknown is not zero: an unknown bitrate is left out, never "0 kbps". A
// match whose track is gone (`available` false, or unknown) is shown as
// unavailable: never hidden, never counted as absent, never offered to play
// or to resolve to.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_duplicate_banners.dart';

import '../../helpers/duplicate_check_fixtures.dart';

void main() {
  DuplicateBanner bannerOf(DuplicateBanners b, DuplicateBannerKind kind) =>
      b.banners.singleWhere((x) => x.kind == kind);

  group('exact library match', () {
    test('headline, the existing track in words, and a decision required '
        'until Import as separate track is chosen', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1',
            title: 'Airbag',
            artist: 'Radiohead',
            album: 'OK Computer',
            codec: 'flac',
            bitrateKbps: 920.4,
            durationS: 287.5),
      ]));

      final b = DuplicateBanners.of(item);
      final exact = bannerOf(b, DuplicateBannerKind.exactLibrary);
      expect(exact.headline, 'This audio is already in your library');
      expect(exact.rows.single.title, 'Airbag — Radiohead');
      expect(exact.rows.single.details,
          'OK Computer · FLAC · 920 kbps · 4:47');
      expect(exact.rows.single.trackUuid, 't-1');
      expect(exact.rows.single.available, isTrue);
      expect(exact.needsChoice, isTrue);
      expect(b.needsChoice, isTrue);
      expect(b.useExistingTrackUuid, 't-1');

      final chosen =
          DuplicateBanners.of(item, chosen: {DuplicateGroup.library});
      expect(bannerOf(chosen, DuplicateBannerKind.exactLibrary).needsChoice,
          isFalse);
      expect(chosen.needsChoice, isFalse);
    });

    test('at most five rows are shown; "+N more" counts the rest; the full '
        'list is kept', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        for (var i = 1; i <= 8; i++) libraryMatchJson('t-$i'),
      ]));

      final exact =
          bannerOf(DuplicateBanners.of(item), DuplicateBannerKind.exactLibrary);
      expect(duplicateDisplayCap, 5);
      expect([for (final r in exact.shown) r.trackUuid],
          ['t-1', 't-2', 't-3', 't-4', 't-5']);
      expect(exact.moreCount, 3);
      expect(exact.rows, hasLength(8));
    });

    test('five or fewer: no "+N more"', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        for (var i = 1; i <= 5; i++) libraryMatchJson('t-$i'),
      ]));
      final exact =
          bannerOf(DuplicateBanners.of(item), DuplicateBannerKind.exactLibrary);
      expect(exact.shown, hasLength(5));
      expect(exact.moreCount, 0);
    });

    test('a gone (or unknown) track is shown as unavailable, is never the '
        'Use existing target and still requires the decision', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-gone', available: false),
        libraryMatchJson('t-unknown', available: null),
        libraryMatchJson('t-live', title: 'Live', artist: 'Band'),
      ]));

      final b = DuplicateBanners.of(item);
      final rows = bannerOf(b, DuplicateBannerKind.exactLibrary).rows;
      expect(rows, hasLength(3));
      expect(rows[0].available, isFalse);
      expect(rows[0].trackUuid, isNull);
      expect(rows[0].title, 'A track that is no longer in your library');
      expect(rows[1].available, isFalse);
      expect(rows[1].trackUuid, isNull);
      expect(b.useExistingTrackUuid, 't-live');

      final allGone = DuplicateBanners.of(reviewItem('i-2',
          check: duplicateCheckJson(matches: [
            libraryMatchJson('t-gone', available: false),
          ])));
      expect(allGone.useExistingTrackUuid, isNull);
      expect(allGone.needsChoice, isTrue);
    });

    test('unknown facts are left out, never shown as zero', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1',
            title: 'Song',
            artist: 'Someone',
            codec: null,
            bitrateKbps: null,
            durationS: null),
      ]));
      final row = bannerOf(DuplicateBanners.of(item),
              DuplicateBannerKind.exactLibrary)
          .rows
          .single;
      expect(row.details, isNot(contains('0')));
      expect(row.details, isNot(contains('kbps')));
      expect(row.title, 'Song — Someone');
    });

    test("the staged file's own detected values, for the side-by-side", () {
      final item = reviewItem('i-1',
          check: duplicateCheckJson(matches: [libraryMatchJson('t-1')]),
          detected: {
            'v': 1,
            'codec': 'mp3',
            'bitrate_kbps': 320.0,
            'duration_s': 61.0,
            'tags': {'title': 'Mine', 'artist': 'Me'},
          });
      expect(DuplicateBanners.of(item).thisFile, 'MP3 · 320 kbps · 1:01');

      final unknown = reviewItem('i-2',
          check: duplicateCheckJson(matches: [libraryMatchJson('t-1')]),
          detected: {'v': 1, 'tags': {}});
      expect(DuplicateBanners.of(unknown).thisFile, isNull);
    });
  });

  group('fingerprint library match', () {
    test('possible band: "Possibly the same song as …", advisory', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1',
            kind: 'fingerprint',
            band: 'possible',
            score: 0.8,
            title: 'Title',
            artist: 'Artist',
            codec: 'flac',
            durationS: 252),
      ]));

      final b = DuplicateBanners.of(item);
      final fp = bannerOf(b, DuplicateBannerKind.fingerprintLibrary);
      expect(fp.headline, 'Possibly the same song as Title — Artist '
          '(FLAC, 4:12)');
      expect(fp.needsChoice, isFalse);
      expect(b.needsChoice, isFalse);
      expect(b.useExistingTrackUuid, isNull);
      expect(b.dontImportTrackUuid, 't-1');
    });

    test('strong band: "Very likely the same recording as …"', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1',
            kind: 'fingerprint',
            band: 'strong',
            score: 0.97,
            title: 'Title',
            artist: 'Artist',
            codec: 'mp3',
            durationS: 3725),
      ]));
      expect(
          bannerOf(DuplicateBanners.of(item),
                  DuplicateBannerKind.fingerprintLibrary)
              .headline,
          'Very likely the same recording as Title — Artist (MP3, 1:02:05)');
    });

    test("Don't import resolves to the best available match: the strongest "
        'band, then the highest score, whatever the list order', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('p-95', kind: 'fingerprint', band: 'possible',
            score: 0.95),
        libraryMatchJson('s-70-gone', kind: 'fingerprint', band: 'strong',
            score: 0.70, available: false),
        libraryMatchJson('s-60', kind: 'fingerprint', band: 'strong',
            score: 0.60),
        libraryMatchJson('s-65', kind: 'fingerprint', band: 'strong',
            score: 0.65),
        libraryMatchJson('p-99', kind: 'fingerprint', band: 'possible',
            score: 0.99),
      ]));

      final b = DuplicateBanners.of(item);
      expect(b.dontImportTrackUuid, 's-65');
      final fp = bannerOf(b, DuplicateBannerKind.fingerprintLibrary);
      expect(fp.headline, startsWith('Very likely the same recording as '
          'Title s-65'));
      // The rows read best first; the gone one stays listed.
      expect([for (final r in fp.rows) r.available],
          [false, true, true, true, true]);
      expect([for (final r in fp.rows.skip(1)) r.trackUuid],
          ['s-65', 's-60', 'p-99', 'p-95']);
    });

    test('no fingerprint match still available: nothing to resolve to', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-gone', kind: 'fingerprint', score: 0.9,
            available: false),
      ]));
      final b = DuplicateBanners.of(item);
      expect(b.dontImportTrackUuid, isNull);
      expect(
          bannerOf(b, DuplicateBannerKind.fingerprintLibrary).rows.single
              .available,
          isFalse);
    });

    test('an exact and a fingerprint match: both banners; only the exact '
        'one needs a decision', () {
      final item = reviewItem('i-1', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-exact'),
        libraryMatchJson('t-fp', kind: 'fingerprint', score: 0.9),
      ]));
      final b = DuplicateBanners.of(item, chosen: {DuplicateGroup.library});
      expect([for (final x in b.banners) x.kind], [
        DuplicateBannerKind.exactLibrary,
        DuplicateBannerKind.fingerprintLibrary,
      ]);
      expect(b.needsChoice, isFalse);
    });
  });

  test('no matches: no banners', () {
    final b = DuplicateBanners.of(reviewItem('i-1',
        check: duplicateCheckJson()));
    expect(b.banners, isEmpty);
    expect(b.needsChoice, isFalse);
    expect(b.useExistingTrackUuid, isNull);
    expect(b.dontImportTrackUuid, isNull);
  });
}
