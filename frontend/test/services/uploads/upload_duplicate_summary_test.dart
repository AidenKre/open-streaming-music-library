// Phase 7B.2d S5: the batch duplicate summary (model, pure). Spec §7
// Duplicate UX: "When review starts, show a summary line computed over the
// snapshot, for example '3 of 20 files may already be in your library · 2
// are duplicates within this upload'. When any item's report has partial
// coverage, add a footnote derived from SC-25 LayerCoverage: 'Only exact
// copies are detected on this server' (no fingerprint tool), 'N library
// tracks not yet scanned' (library_pending), or 'N library tracks could not
// be checked' (library_failed). … Tracks the library cannot fingerprint by
// design are disclosed in the details, not as an unfinished scan. Never
// show 'No duplicates' unless coverage is complete." Computed from
// `duplicate_check` only; a null report (not checked yet) is not an empty
// one. D34: the summary never claims "no duplicates within this upload".
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_duplicate_summary.dart';

import '../../helpers/duplicate_check_fixtures.dart';

void main() {
  UploadItem clean(String uuid) =>
      reviewItem(uuid, check: duplicateCheckJson());

  test('library and within-upload counts, as in the spec example', () {
    final items = [
      reviewItem('a', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1'),
      ])),
      reviewItem('b', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-2', kind: 'fingerprint', score: 0.8),
      ])),
      reviewItem('c', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-3'),
        stagedMatchJson('a', batchUuid: 'b-1'),
      ])),
      reviewItem('d', check: duplicateCheckJson(matches: [
        stagedMatchJson('b', kind: 'fingerprint', score: 0.7,
            batchUuid: 'b-1'),
      ])),
      for (var i = 0; i < 16; i++) clean('x-$i'),
    ];

    final s = DuplicateSummary.of(items);
    expect(s.line, '3 of 20 files may already be in your library · '
        '2 are duplicates within this upload');
    expect(s.footnotes, isEmpty);
  });

  test('singular wording and matches against another upload', () {
    final items = [
      reviewItem('a', check: duplicateCheckJson(matches: [
        stagedMatchJson('z', batchUuid: 'b-other'),
      ])),
      reviewItem('b', check: duplicateCheckJson(matches: [
        stagedMatchJson('a', batchUuid: 'b-1'),
      ])),
      clean('c'),
    ];
    expect(DuplicateSummary.of(items).line,
        '1 is a duplicate within this upload · '
        '1 matches a file in another upload');
  });

  test('"No duplicates found" only when every report has full coverage',
      () {
    expect(DuplicateSummary.of([clean('a'), clean('b')]).line,
        'No duplicates found');

    final partial = DuplicateSummary.of([
      clean('a'),
      reviewItem('b', check: duplicateCheckJson(
          exact: coverageJson(pending: 12))),
    ]);
    expect(partial.line, 'No matches among what could be compared');
    expect(partial.line, isNot(contains('No duplicates')));
    expect(partial.footnotes, ['12 library tracks not yet scanned']);
  });

  test('a report not checked yet (null) is counted as such, never as '
      'empty', () {
    final s = DuplicateSummary.of([clean('a'), reviewItem('b'),
      reviewItem('c')]);
    expect(s.line, '2 files not checked for duplicates yet');
    expect(s.line, isNot(contains('No duplicates')));
  });

  test('a failed check is counted as such', () {
    final s = DuplicateSummary.of([
      reviewItem('a', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1'),
      ])),
      reviewItem('b', check: duplicateCheckJson(status: 'failed')),
    ]);
    expect(s.line, '1 of 2 files may already be in your library · '
        "the duplicate check couldn't run for 1 file");
  });

  test('footnotes: no fingerprint tool, pending, failed (largest count of '
      'any report), each once', () {
    final s = DuplicateSummary.of([
      reviewItem('a', check: duplicateCheckJson(
        exact: coverageJson(pending: 2, failed: 1),
        fingerprint: coverageJson(subject: 'unavailable', pending: 900),
      )),
      reviewItem('b', check: duplicateCheckJson(
        exact: coverageJson(pending: 5, failed: 0),
        fingerprint: coverageJson(subject: 'unavailable', pending: 900),
      )),
    ]);
    // Without the tool the fingerprint layer's counts say nothing about an
    // unfinished scan.
    expect(s.footnotes, [
      'Only exact copies are detected on this server',
      '5 library tracks not yet scanned',
      '1 library track could not be checked',
    ]);
    expect(s.line, 'No matches among what could be compared');
  });

  test('fingerprint pending counts when the tool is there', () {
    final s = DuplicateSummary.of([
      reviewItem('a', check: duplicateCheckJson(
          fingerprint: coverageJson(pending: 7))),
    ]);
    expect(s.footnotes, ['7 library tracks not yet scanned']);
  });

  test('tracks that cannot be compared by design are disclosed, not as an '
      'unfinished scan, and do not block "No duplicates found"', () {
    final s = DuplicateSummary.of([
      reviewItem('a', check: duplicateCheckJson(
          fingerprint: coverageJson(notComparable: 4))),
    ]);
    expect(s.line, 'No duplicates found');
    expect(s.footnotes,
        ['4 library tracks are too short or quiet to compare by sound']);
  });

  test('unknown library counts are never read as zero', () {
    final s = DuplicateSummary.of([
      reviewItem('a', check: duplicateCheckJson(
          exact: coverageJson(pending: null))),
    ]);
    expect(s.line, 'No matches among what could be compared');
    expect(s.footnotes, ['Part of your library could not be compared']);
  });

  test('an empty snapshot has no summary', () {
    final s = DuplicateSummary.of(const []);
    expect(s.line, isNull);
    expect(s.footnotes, isEmpty);
  });
}
