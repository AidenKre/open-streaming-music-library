// Phase 8 spec §6 "Possible duplicates", Header; SC-25 coverage rule;
// 8A.4 hand-over (summary fields). The scan-status header's words. Model
// code: nothing from ui/. Unknown is never zero: a count the summary did not
// give never supports a claim.
import 'package:frontend/models/dto/library_tools_dtos.dart';

/// The spec's sentence when the server has no fingerprint tool.
const fingerprintToolMissingText =
    'Fingerprint tool not installed on the server — only exact copies are '
    'found';

/// What the header says for one summary.
class DuplicatesHeader {
  const DuplicatesHeader({
    this.toolMissing,
    this.scanLine,
    this.notes = const [],
    this.outcome,
  });

  /// [fingerprintToolMissingText] when there is no fingerprinter.
  final String? toolMissing;

  /// "Checked X of Y tracks"; null when the counts are unknown.
  final String? scanLine;

  /// Tracks that failed, and tracks that can't be compared by design.
  final List<String> notes;

  /// "No duplicates" (only under the SC-25 rule) or "No exact copies found"
  /// (no fingerprinter); null when nothing may be claimed.
  final String? outcome;
}

DuplicatesHeader duplicatesHeader(DuplicateSummaryDto summary) {
  final inUse = summary.fingerprinter != null;
  final exact = summary.exactCoverage;
  final fp = summary.fingerprintCoverage;
  final match = summary.matchCoverage;

  final done = match.current;
  final pending = match.pending;
  final scanLine = done == null || pending == null
      ? null
      : 'Checked ${_thousands(done)} of ${_thousands(done + pending)} tracks';

  final notes = <String>[
    ?_count(
      exact.failed,
      plural: "couldn't be checked for exact copies",
      singular: "couldn't be checked for exact copies",
    ),
    if (inUse)
      ?_count(
        fp.failed,
        plural: "couldn't be fingerprinted",
        singular: "couldn't be fingerprinted",
      ),
    ?_count(
      exact.unsupported,
      plural: "can't be checked for exact copies (unsupported format)",
      singular: "can't be checked for exact copies (unsupported format)",
    ),
    if (inUse)
      ?_count(
        _sum(fp.tooShort, fp.lowInformation) ?? fp.tooShort ?? fp.lowInformation,
        atLeast: fp.tooShort == null || fp.lowInformation == null,
        plural: 'are too short or too quiet to compare by sound',
        singular: 'is too short or too quiet to compare by sound',
      ),
  ];

  final open = [
    summary.exact.open,
    summary.strong.open,
    summary.possible.open,
  ];
  var complete =
      exact.pending == 0 &&
      exact.failed == 0 &&
      match.pending == 0 &&
      !open.contains(null) &&
      open.fold<int>(0, (a, b) => a + b!) == 0;
  if (inUse) complete = complete && fp.pending == 0 && fp.failed == 0;

  return DuplicatesHeader(
    toolMissing: inUse ? null : fingerprintToolMissingText,
    scanLine: scanLine,
    notes: notes,
    outcome: !complete
        ? null
        : (inUse ? 'No duplicates' : 'No exact copies found'),
  );
}

int? _sum(int? a, int? b) => a == null || b == null ? null : a + b;

/// "N tracks" plus the plural phrase, or "1 track" plus the singular one; null when unknown or zero.
/// With [atLeast] (one part unknown) the number is only a lower bound and is worded as one.
String? _count(
  int? n, {
  required String plural,
  required String singular,
  bool atLeast = false,
}) {
  if (n == null || n <= 0) return null;
  final lead = atLeast ? 'At least ' : '';
  if (n == 1) return '${lead}1 track $singular';
  return '$lead${_thousands(n)} tracks $plural';
}

String _thousands(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
