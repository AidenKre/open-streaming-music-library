// 8B.3 S2: the scan-status header's words for each coverage state.
//  * Spec §6 Header: "Scan status from /tracks/duplicates/summary, for
//    example 'Checked 12,340 of 50,000 tracks'. When there is no
//    fingerprinter it says 'Fingerprint tool not installed on the server —
//    only exact copies are found'. It never shows 'No duplicates' unless the
//    SC-25 rule holds: no pending and no failed rows on the layers in use.
//    Tracks that cannot be compared by design (too short, silent,
//    unsupported) are disclosed as a count, not as an unfinished scan."
//  * 8A.4 hand-over: not comparable by design = exact unsupported,
//    fingerprint too_short + low_information (+ unavailable when there is no
//    tool). The fingerprint layer is in use only with a fingerprinter.
//  * 8-D14: no fingerprint tool -> exact-only wording, no "no duplicates"
//    claim.
//  * Unknown is not zero: a count the summary didn't give never supports a
//    claim and is never shown as 0.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/duplicates/duplicates_header.dart';

const _tool =
    'Fingerprint tool not installed on the server — only exact copies are '
    'found';

/// A summary over [total] live tracks; by default everything is checked and
/// current, the tool is present and no pair is open.
DuplicateSummaryDto summary({
  int? total = 50000,
  int? exactPending = 0,
  int? exactFailed = 0,
  int? exactUnsupported = 0,
  int? fpPending = 0,
  int? fpFailed = 0,
  int? fpUnavailable = 0,
  int? fpTooShort = 0,
  int? fpLowInfo = 0,
  int? matchPending = 0,
  int? matchCurrent,
  int? openExact = 0,
  int? openStrong = 0,
  int? openPossible = 0,
  int? dismissed = 0,
  String? fingerprinter = 'fpcalc',
}) {
  int? rest(List<int?> parts) {
    if (total == null || parts.contains(null)) return null;
    return total - parts.fold<int>(0, (a, b) => a + b!);
  }

  return DuplicateSummaryDto(
    exact: DuplicateBandCountsDto(open: openExact, dismissed: dismissed),
    strong: DuplicateBandCountsDto(open: openStrong, dismissed: 0),
    possible: DuplicateBandCountsDto(open: openPossible, dismissed: 0),
    exactCoverage: ExactCoverageDto(
      pending: exactPending,
      current: rest([exactPending, exactFailed, exactUnsupported]),
      failed: exactFailed,
      unsupported: exactUnsupported,
    ),
    fingerprintCoverage: FingerprintCoverageDto(
      pending: fpPending,
      current: rest([fpPending, fpFailed, fpUnavailable, fpTooShort, fpLowInfo]),
      unavailable: fpUnavailable,
      tooShort: fpTooShort,
      lowInformation: fpLowInfo,
      failed: fpFailed,
    ),
    matchCoverage: MatchCoverageDto(
      pending: matchPending,
      current: matchCurrent ?? rest([matchPending]),
    ),
    fingerprinter: fingerprinter,
  );
}

void main() {
  group('with the fingerprint tool', () {
    test('everything checked and nothing open: No duplicates', () {
      final h = duplicatesHeader(summary());
      expect(h.outcome, 'No duplicates');
      expect(h.toolMissing, isNull);
      expect(h.scanLine, 'Checked 50,000 of 50,000 tracks');
      expect(h.notes, isEmpty);
    });

    test('dismissed pairs alone still allow No duplicates', () {
      expect(duplicatesHeader(summary(dismissed: 5)).outcome, 'No duplicates');
    });

    test('a scan in progress shows its progress and claims nothing', () {
      final h = duplicatesHeader(
        summary(exactPending: 37660, fpPending: 37660, matchPending: 37660),
      );
      expect(h.scanLine, 'Checked 12,340 of 50,000 tracks');
      expect(h.outcome, isNull);
    });

    for (final (name, s) in [
      ('exact pending', summary(exactPending: 1)),
      ('exact failed', summary(exactFailed: 1)),
      ('fingerprint pending', summary(fpPending: 1)),
      ('fingerprint failed', summary(fpFailed: 1)),
      ('match pending', summary(matchPending: 1)),
      ('an open exact pair', summary(openExact: 1)),
      ('an open strong pair', summary(openStrong: 1)),
      ('an open possible pair', summary(openPossible: 1)),
    ]) {
      test('never No duplicates with $name', () {
        final h = duplicatesHeader(s);
        expect(h.outcome, isNull);
        expect(_all(h), isNot(contains('No duplicates')));
      });
    }

    test('failed tracks are counted per layer, as not checked', () {
      final h = duplicatesHeader(summary(exactFailed: 3, fpFailed: 1));
      expect(h.notes, containsAll([
        "3 tracks couldn't be checked for exact copies",
        "1 track couldn't be fingerprinted",
      ]));
      expect(h.outcome, isNull);
    });

    test('tracks that cannot be compared by design are a count, not an '
        'unfinished scan', () {
      final h = duplicatesHeader(
        summary(exactUnsupported: 4, fpTooShort: 2, fpLowInfo: 1),
      );
      expect(h.notes, [
        "4 tracks can't be checked for exact copies (unsupported format)",
        '3 tracks are too short or too quiet to compare by sound',
      ]);
      expect(h.outcome, 'No duplicates');
    });

    test('one track reads in the singular', () {
      final h = duplicatesHeader(summary(exactUnsupported: 1, fpTooShort: 1));
      expect(h.notes, [
        "1 track can't be checked for exact copies (unsupported format)",
        '1 track is too short or too quiet to compare by sound',
      ]);
    });
  });

  group('without the fingerprint tool', () {
    test('says so, and never claims No duplicates', () {
      final h = duplicatesHeader(
        summary(fingerprinter: null, fpUnavailable: 50000),
      );
      expect(h.toolMissing, _tool);
      expect(h.outcome, 'No exact copies found');
      expect(_all(h), isNot(contains('No duplicates')));
      // The fingerprint layer is not in use: its unavailable rows are not
      // listed as tracks that can't be compared.
      expect(h.notes, isEmpty);
    });

    test('the fingerprint layer is not in use: its pending or failed rows '
        'neither block nor show', () {
      final h = duplicatesHeader(
        summary(fingerprinter: null, fpPending: 10, fpFailed: 2, fpTooShort: 3),
      );
      expect(h.outcome, 'No exact copies found');
      expect(h.notes, isEmpty);
    });

    test('an unfinished exact layer claims nothing', () {
      expect(
        duplicatesHeader(summary(fingerprinter: null, exactPending: 2)).outcome,
        isNull,
      );
      expect(
        duplicatesHeader(summary(fingerprinter: null, exactFailed: 2)).outcome,
        isNull,
      );
      expect(
        duplicatesHeader(summary(fingerprinter: null, openExact: 1)).outcome,
        isNull,
      );
    });
  });

  group('unknown counts', () {
    for (final (name, s) in [
      ('exact pending', summary(exactPending: null)),
      ('exact failed', summary(exactFailed: null)),
      ('fingerprint pending', summary(fpPending: null)),
      ('fingerprint failed', summary(fpFailed: null)),
      ('match pending', summary(matchPending: null)),
      ('open exact pairs', summary(openExact: null)),
      ('open strong pairs', summary(openStrong: null)),
      ('open possible pairs', summary(openPossible: null)),
    ]) {
      test('an unknown count of $name never supports No duplicates', () {
        expect(duplicatesHeader(s).outcome, isNull);
      });
    }

    test('unknown match counts give no progress line, never "0 of"', () {
      expect(duplicatesHeader(summary(matchPending: null)).scanLine, isNull);
      expect(duplicatesHeader(summary(total: null)).scanLine, isNull);
    });

    test('an unknown failed or not-comparable count is not shown as 0', () {
      final h = duplicatesHeader(
        summary(exactFailed: null, exactUnsupported: null, fpTooShort: null),
      );
      expect(h.notes, isEmpty);
      expect(_all(h), isNot(matches(RegExp(r'(^|[^\d,])0 track'))));
    });

    // 8-R1-24: a known part is shown as a lower bound when the other part of
    // the not-comparable count is unknown (never hidden, never a total).
    test('a known too-short count is shown when the quiet count is unknown',
        () {
      final h = duplicatesHeader(summary(fpTooShort: 40, fpLowInfo: null));
      expect(h.notes, [
        'At least 40 tracks are too short or too quiet to compare by sound',
      ]);
    });

    test('a known quiet count is shown when the too-short count is unknown',
        () {
      final h = duplicatesHeader(summary(fpTooShort: null, fpLowInfo: 1));
      expect(h.notes, [
        'At least 1 track is too short or too quiet to compare by sound',
      ]);
    });

    test('a lower bound of zero claims nothing', () {
      final h = duplicatesHeader(summary(fpTooShort: 0, fpLowInfo: null));
      expect(h.notes, isEmpty);
    });
  });
}

String _all(DuplicatesHeader h) =>
    [h.toolMissing, h.scanLine, ...h.notes, h.outcome].whereType<String>().join('\n');
