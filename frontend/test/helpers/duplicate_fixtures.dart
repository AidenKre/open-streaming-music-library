// Possible duplicates fixtures (8B.3): DTOs as the 8A.4 server answers them.
import 'package:frontend/models/dto/library_tools_dtos.dart';

DuplicatePairTrackDto dupTrack(
  String uuid, {
  int revision = 1,
  String? title = 'Song',
  String? artist = 'Band',
  String? album = 'Album',
  String? codec = 'flac',
  double? bitrateKbps = 900,
  int? sampleRateHz = 44100,
  int? channels = 2,
  double? durationS = 185,
  int addedAt = 1773576000,
  bool? masterPresent = true,
}) => DuplicatePairTrackDto(
  uuidId: uuid,
  revision: revision,
  title: title,
  artist: artist,
  album: album,
  codec: codec,
  bitrateKbps: bitrateKbps,
  sampleRateHz: sampleRateHz,
  channels: channels,
  durationS: durationS,
  addedAt: addedAt,
  masterPresent: masterPresent,
);

/// A pair; [band] `exact` makes an exact pair (kind exact, null score).
DuplicatePairDto dupPair(
  String a,
  String b, {
  String band = 'exact',
  double? score,
  String status = 'open',
  DuplicatePairTrackDto? trackA,
  DuplicatePairTrackDto? trackB,
}) => DuplicatePairDto(
  uuidA: a,
  uuidB: b,
  kind: band == 'exact' ? 'exact' : 'fingerprint',
  band: band,
  score: band == 'exact' ? null : (score ?? 0.9),
  status: status,
  detectedAt: 1,
  trackA: trackA ?? dupTrack(a),
  trackB: trackB ?? dupTrack(b),
);

DuplicatePairPageDto dupPage(List<DuplicatePairDto> pairs, {String? next}) =>
    DuplicatePairPageDto(pairs: pairs, nextAfter: next);

DuplicatePairStatusDto dupStatus(String a, String b, String status) =>
    DuplicatePairStatusDto(uuidA: a, uuidB: b, status: status);

/// A summary: everything checked, tool present, [open] exact pairs open.
DuplicateSummaryDto dupSummary({
  int total = 10,
  int open = 0,
  int exactPending = 0,
  String? fingerprinter = 'fpcalc',
}) => DuplicateSummaryDto(
  exact: DuplicateBandCountsDto(open: open, dismissed: 0),
  strong: const DuplicateBandCountsDto(open: 0, dismissed: 0),
  possible: const DuplicateBandCountsDto(open: 0, dismissed: 0),
  exactCoverage: ExactCoverageDto(
    pending: exactPending,
    current: total - exactPending,
    failed: 0,
    unsupported: 0,
  ),
  fingerprintCoverage: FingerprintCoverageDto(
    pending: 0,
    current: total,
    unavailable: 0,
    tooShort: 0,
    lowInformation: 0,
    failed: 0,
  ),
  matchCoverage: MatchCoverageDto(pending: exactPending, current: total - exactPending),
  fingerprinter: fingerprinter,
);
