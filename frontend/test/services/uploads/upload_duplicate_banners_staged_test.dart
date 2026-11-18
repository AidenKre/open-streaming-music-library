// Phase 7B.2d S3: staged-item banners, the per-item coverage line and the
// `duplicate_conflict` view (model, pure).
//  * Spec §5: "Pairs across staged items are reported once, on the
//    later-validated item. The wording names the other item's batch: 'Same
//    audio as *other.flac* in this upload' for the same batch, or '…in your
//    upload from 14:02' for another open batch."
//  * Spec §7: "'Same audio as *x.flac* in this upload' (exact) or 'Sounds
//    like *x.mp3* in this upload' (fingerprint). Exact: Import both … Until
//    one is chosen, Confirm and Skip are disabled. Fingerprint: advisory."
//  * Spec §7: "Per item, show 'Too short or quiet to compare by sound' when
//    the item's own fingerprint state is not comparable … Never show 'No
//    duplicates' unless coverage is complete." A null report (not validated
//    yet) is not an empty report. D34: never "no duplicates within this
//    upload".
//  * Spec §7 `duplicate_conflict`: "Show the new matching track(s) with Use
//    existing track or Back to review."
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_duplicate_banners.dart';

import '../../helpers/duplicate_check_fixtures.dart';

void main() {
  DuplicateBanner bannerOf(DuplicateBanners b, DuplicateBannerKind kind) =>
      b.banners.singleWhere((x) => x.kind == kind);

  /// Unix seconds of 14:02 today, local time (the wording is local).
  final at1402 =
      DateTime(2026, 11, 12, 14, 2).millisecondsSinceEpoch ~/ 1000;

  group('staged matches', () {
    test('exact, same batch: "Same audio as x.flac in this upload"; a '
        'decision is required until Import both', () {
      final item = reviewItem('i-2', batchUuid: 'b-1',
          check: duplicateCheckJson(matches: [
            stagedMatchJson('i-1', filename: 'x.flac', batchUuid: 'b-1'),
          ]));
      final b = DuplicateBanners.of(item);
      final staged = bannerOf(b, DuplicateBannerKind.exactStaged);
      expect(staged.headline, 'Same audio as x.flac in this upload');
      expect(staged.rows.single.title, 'x.flac');
      expect(staged.rows.single.details, 'in this upload');
      expect(staged.rows.single.trackUuid, isNull);
      expect(staged.needsChoice, isTrue);
      expect(b.needsChoice, isTrue);

      final chosen =
          DuplicateBanners.of(item, chosen: {DuplicateGroup.staged});
      expect(chosen.needsChoice, isFalse);
    });

    test('exact, another batch: named by its time', () {
      final item = reviewItem('i-2', batchUuid: 'b-2',
          check: duplicateCheckJson(matches: [
            stagedMatchJson('i-1', filename: 'x.flac', batchUuid: 'b-1',
                batchCreatedAt: at1402),
          ]));
      final staged = bannerOf(
          DuplicateBanners.of(item), DuplicateBannerKind.exactStaged);
      expect(staged.headline, 'Same audio as x.flac in your upload from 14:02');
      expect(staged.rows.single.details, 'in your upload from 14:02');
    });

    test('another batch of unknown time: "in another upload"', () {
      final item = reviewItem('i-2', batchUuid: 'b-2',
          check: duplicateCheckJson(matches: [
            stagedMatchJson('i-1', filename: 'x.flac', batchUuid: 'b-1',
                batchCreatedAt: null),
          ]));
      expect(
          bannerOf(DuplicateBanners.of(item), DuplicateBannerKind.exactStaged)
              .headline,
          'Same audio as x.flac in another upload');
    });

    test('fingerprint: "Sounds like x.mp3 in this upload", advisory', () {
      final item = reviewItem('i-2', batchUuid: 'b-1',
          check: duplicateCheckJson(matches: [
            stagedMatchJson('i-1', kind: 'fingerprint', score: 0.8,
                filename: 'x.mp3', batchUuid: 'b-1'),
          ]));
      final b = DuplicateBanners.of(item);
      final fp = bannerOf(b, DuplicateBannerKind.fingerprintStaged);
      expect(fp.headline, 'Sounds like x.mp3 in this upload');
      expect(fp.needsChoice, isFalse);
      expect(b.needsChoice, isFalse);
    });

    test('a staged item that is gone is shown as unavailable, never hidden, '
        'and still needs the decision', () {
      final item = reviewItem('i-2', check: duplicateCheckJson(matches: [
        stagedMatchJson('i-1', available: false),
      ]));
      final b = DuplicateBanners.of(item);
      final staged = bannerOf(b, DuplicateBannerKind.exactStaged);
      expect(staged.rows.single.available, isFalse);
      expect(staged.rows.single.title,
          'A file that is no longer in your uploads');
      expect(staged.headline,
          'Same audio as a file that is no longer in your uploads');
      expect(b.needsChoice, isTrue);
    });

    test('a library and a staged exact match need both decisions', () {
      final item = reviewItem('i-2', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1'),
        stagedMatchJson('i-1'),
      ]));
      expect(
          DuplicateBanners.of(item, chosen: {DuplicateGroup.library})
              .needsChoice,
          isTrue);
      expect(
          DuplicateBanners.of(item,
              chosen: {DuplicateGroup.library, DuplicateGroup.staged})
              .needsChoice,
          isFalse);
    });
  });

  group('coverage line', () {
    test('a null report is "not checked yet", never an empty report', () {
      final b = DuplicateBanners.of(reviewItem('i-1'));
      expect(b.coverage, 'Not checked for duplicates yet');
      expect(b.banners, isEmpty);
      expect(b.notes, isEmpty);
    });

    test('"No duplicates found" only when both layers are complete', () {
      final b = DuplicateBanners.of(
          reviewItem('i-1', check: duplicateCheckJson()));
      expect(b.coverage, 'No duplicates found');
      expect(b.notes, isEmpty);
    });

    test('library tracks not compared yet: no "No duplicates" claim', () {
      for (final check in [
        duplicateCheckJson(exact: coverageJson(pending: 3)),
        duplicateCheckJson(fingerprint: coverageJson(failed: 1)),
        duplicateCheckJson(exact: coverageJson(pending: null)),
      ]) {
        final b = DuplicateBanners.of(reviewItem('i-1', check: check));
        expect(b.coverage, 'No matches among what could be compared');
        expect(b.coverage, isNot(contains('No duplicates')));
      }
    });

    test('a failed or unreadable check says so', () {
      final failed = DuplicateBanners.of(reviewItem('i-1',
          check: duplicateCheckJson(status: 'failed')));
      expect(failed.coverage,
          "The duplicate check couldn't run for this file");
      final unreadable = DuplicateBanners.of(reviewItem('i-1',
          check: {'version': 1, 'status': 'complete', 'matches': 3}));
      expect(unreadable.coverage,
          "The duplicate check couldn't run for this file");
    });

    test('the item\'s own fingerprint and exact states, in words', () {
      String? noteFor(Map<String, dynamic> check) {
        final notes =
            DuplicateBanners.of(reviewItem('i-1', check: check)).notes;
        return notes.isEmpty ? null : notes.single;
      }

      for (final state in ['too_short', 'low_information']) {
        expect(
            noteFor(duplicateCheckJson(
                fingerprint: coverageJson(subject: state))),
            'Too short or quiet to compare by sound');
      }
      expect(
          noteFor(duplicateCheckJson(
              fingerprint: coverageJson(subject: 'unavailable'))),
          'Only exact copies are detected on this server');
      for (final state in ['failed', 'pending', null]) {
        expect(
            noteFor(duplicateCheckJson(
                fingerprint: coverageJson(subject: state))),
            "This file couldn't be compared by sound");
      }
      for (final state in ['unsupported', 'failed', 'pending']) {
        expect(
            noteFor(duplicateCheckJson(exact: coverageJson(subject: state))),
            "This file couldn't be checked for exact copies");
      }
    });

    test('with matches there is no coverage line, but the notes stay', () {
      final b = DuplicateBanners.of(reviewItem('i-1',
          check: duplicateCheckJson(
              fingerprint: coverageJson(subject: 'unavailable'),
              matches: [libraryMatchJson('t-1')])));
      expect(b.coverage, isNull);
      expect(b.notes, ['Only exact copies are detected on this server']);
    });
  });

  group('duplicate_conflict', () {
    test('the new matching tracks, with Use existing on the first one still '
        'available', () {
      final item = reviewItem('i-1', state: 'duplicate_conflict', conflicts: [
        libraryMatchJson('t-gone', available: false),
        libraryMatchJson('t-new', title: 'New', artist: 'Band'),
        libraryMatchJson('t-other'),
      ]);
      final c = DuplicateConflictView.of(item);
      expect(c.headline,
          'This audio was added to your library after your review');
      expect([for (final r in c.rows) r.available], [false, true, true]);
      expect(c.rows[1].title, 'New — Band');
      expect(c.useExistingTrackUuid, 't-new');
    });

    test('no conflict list (or none available): nothing to resolve to', () {
      expect(
          DuplicateConflictView.of(
                  reviewItem('i-1', state: 'duplicate_conflict'))
              .useExistingTrackUuid,
          isNull);
      expect(
          DuplicateConflictView.of(reviewItem('i-1',
                  state: 'duplicate_conflict',
                  conflicts: [libraryMatchJson('t', available: false)]))
              .useExistingTrackUuid,
          isNull);
    });
  });
}
