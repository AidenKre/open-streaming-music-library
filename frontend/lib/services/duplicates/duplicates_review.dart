// Phase 8 spec §6 "Possible duplicates"; SC-25; SC-16l. The rules of the
// Possible duplicates page: what a pair is called, which fields differ, how
// a value reads, the list order and the scan-status header. Model code:
// nothing from ui/.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/duration_text.dart';
import 'package:frontend/services/feature_providers.dart';

/// The server's band of a pair; [unknown] for a band this app doesn't know.
enum DuplicateBand { exact, strong, possible, unknown }

DuplicateBand duplicateBandOf(String band) => switch (band) {
  'exact' => DuplicateBand.exact,
  'strong' => DuplicateBand.strong,
  'possible' => DuplicateBand.possible,
  _ => DuplicateBand.unknown,
};

/// The badge of [pair]. Fingerprint matches are advisory: only an exact pair
/// is called an exact copy, and nothing is called a duplicate as a fact.
String duplicateBadgeText(DuplicatePairDto pair) =>
    switch (duplicateBandOf(pair.band)) {
      DuplicateBand.exact when isExactPair(pair) => 'Exact copy',
      DuplicateBand.strong => 'Very likely same recording',
      DuplicateBand.possible => 'Possibly same song',
      _ => 'Possible match',
    };

/// Only a pair of kind exact in band exact is an exact copy.
bool isExactPair(DuplicatePairDto p) =>
    duplicateBandOf(p.band) == DuplicateBand.exact && p.kind == 'exact';

/// The fields a pair row compares (spec §6: format, bitrate, sample rate,
/// duration, album, added date).
enum DuplicateField { format, bitrate, sampleRate, duration, album, addedDate }

String duplicateFieldLabel(DuplicateField field) => switch (field) {
  DuplicateField.format => 'Format',
  DuplicateField.bitrate => 'Bitrate',
  DuplicateField.sampleRate => 'Sample rate',
  DuplicateField.duration => 'Duration',
  DuplicateField.album => 'Album',
  DuplicateField.addedDate => 'Added',
};

/// How [field] of [track] reads; `Unknown` when the server doesn't know it.
String duplicateFieldText(DuplicatePairTrackDto track, DuplicateField field) =>
    _knownFieldText(track, field) ?? 'Unknown';

String? _knownFieldText(DuplicatePairTrackDto t, DuplicateField field) {
  switch (field) {
    case DuplicateField.format:
      return t.codec?.toUpperCase();
    case DuplicateField.bitrate:
      final kbps = t.bitrateKbps;
      return kbps == null ? null : '${kbps.round()} kbps';
    case DuplicateField.sampleRate:
      final hz = t.sampleRateHz;
      if (hz == null) return null;
      var khz = (hz / 1000).toStringAsFixed(1);
      if (khz.endsWith('.0')) khz = khz.substring(0, khz.length - 2);
      return '$khz kHz';
    case DuplicateField.duration:
      final s = t.durationS;
      return s == null ? null : formatTrackDuration(s);
    case DuplicateField.album:
      return t.album;
    case DuplicateField.addedDate:
      final d = DateTime.fromMillisecondsSinceEpoch(t.addedAt * 1000);
      final mm = d.month.toString().padLeft(2, '0');
      final dd = d.day.toString().padLeft(2, '0');
      return '${d.year.toString().padLeft(4, '0')}-$mm-$dd';
  }
}

/// The fields whose shown values differ. A value unknown on either side is
/// never a difference (SC-16l).
Set<DuplicateField> differingFields(
  DuplicatePairTrackDto a,
  DuplicatePairTrackDto b,
) => {
  for (final f in DuplicateField.values)
    if (_differs(a, b, f)) f,
};

bool _differs(DuplicatePairTrackDto a, DuplicatePairTrackDto b, DuplicateField f) {
  final x = _knownFieldText(a, f);
  final y = _knownFieldText(b, f);
  return x != null && y != null && x != y;
}

/// "Label: value" for every field of [track] whose value is known, in
/// [DuplicateField] order: what names one copy in a confirmation.
List<String> copyIdentityLines(DuplicatePairTrackDto track) => [
  for (final f in DuplicateField.values)
    if (_knownFieldText(track, f) case final words?)
      '${duplicateFieldLabel(f)}: $words',
];

/// The line that states a copy's file status, or null when the file is
/// present on the server. A file the server could not check (null) is
/// "unknown", never "missing".
String? copyFileStatusText(DuplicatePairTrackDto track) =>
    switch (track.masterPresent) {
      true => null,
      false => 'File missing on the server',
      null => 'File status unknown',
    };

/// The server's list order: band (exact, strong, possible), then score
/// descending (an exact pair, whose score is null, ranks as 1.0), then
/// `uuid_a`, then `uuid_b`.
int compareDuplicatePairs(DuplicatePairDto x, DuplicatePairDto y) {
  final byBand = duplicateBandOf(x.band).index.compareTo(
    duplicateBandOf(y.band).index,
  );
  if (byBand != 0) return byBand;
  final byScore = (y.score ?? 1.0).compareTo(x.score ?? 1.0);
  if (byScore != 0) return byScore;
  final byA = x.uuidA.compareTo(y.uuidA);
  return byA != 0 ? byA : x.uuidB.compareTo(y.uuidB);
}

/// The server offers the Possible duplicates review: its `library_tools`
/// block is present and says `duplicate_review`.
final duplicateReviewAdvertisedProvider = Provider<bool>(
  (ref) =>
      ref.watch(libraryToolsFeatureProvider).value?.block.duplicateReview ==
      true,
);
