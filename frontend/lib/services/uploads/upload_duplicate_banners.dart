// The per-item duplicate banners (spec §7 Duplicate UX; SC-25): built from
// the item's `duplicate_check` only. Model code: pure, nothing from ui/.
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/duration_text.dart';

/// The exact-match groups of a report that need an explicit decision.
enum DuplicateGroup { library, staged }

/// At most this many matches are shown per banner ("+N more" for the rest).
const duplicateDisplayCap = 5;

enum DuplicateBannerKind {
  exactLibrary,
  exactStaged,
  fingerprintLibrary,
  fingerprintStaged,
}

/// One match as the banner shows it.
class DuplicateRow {
  const DuplicateRow({
    required this.title,
    required this.details,
    required this.available,
    this.trackUuid,
  });
  final String title;
  final String? details;
  final bool available;

  /// The library track to play or resolve to; null unless available.
  final String? trackUuid;
}

class DuplicateBanner {
  const DuplicateBanner({
    required this.kind,
    required this.headline,
    required this.rows,
    required this.needsChoice,
  });
  final DuplicateBannerKind kind;
  final String headline;

  /// Every match of this banner, best first.
  final List<DuplicateRow> rows;
  final bool needsChoice;

  List<DuplicateRow> get shown => rows.take(duplicateDisplayCap).toList();
  int get moreCount =>
      rows.length > duplicateDisplayCap ? rows.length - duplicateDisplayCap : 0;
}

class DuplicateBanners {
  const DuplicateBanners._({
    required this.banners,
    required this.useExistingTrackUuid,
    required this.dontImportTrackUuid,
    required this.thisFile,
    required this.coverage,
    required this.notes,
  });

  factory DuplicateBanners.of(
    UploadItem item, {
    Set<DuplicateGroup> chosen = const {},
  }) {
    final check = item.duplicateCheck;
    final thisFile = _joinKnown([
      _codec(item.detectedMetadata?.codec),
      _bitrate(item.detectedMetadata?.bitrateKbps),
      _duration(item.detectedMetadata?.durationS),
    ]);
    if (check == null || !check.isReadable) {
      return DuplicateBanners._(
        banners: const [],
        useExistingTrackUuid: null,
        dontImportTrackUuid: null,
        thisFile: thisFile,
        coverage: _coverage(check),
        notes: const [],
      );
    }
    final exactLib = <DuplicateMatch>[];
    final exactStaged = <DuplicateMatch>[];
    final fpLib = <DuplicateMatch>[];
    final fpStaged = <DuplicateMatch>[];
    for (final m in check.matches) {
      final s = m.subject;
      if (s is LibraryTrackSubject) {
        (m.isExact ? exactLib : fpLib).add(m);
      } else if (s is StagedItemSubject) {
        (m.isExact ? exactStaged : fpStaged).add(m);
      }
    }
    // Best first: strong before possible, then score descending, null last.
    int rank(DuplicateMatch m) => m.band == 'strong' ? 0 : 1;
    int byBest(DuplicateMatch a, DuplicateMatch b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final sa = a.score, sb = b.score;
      if (sa == null && sb == null) return 0;
      if (sa == null) return 1;
      if (sb == null) return -1;
      return sb.compareTo(sa);
    }

    // List.sort is not stable; sort by (comparison, original index).
    List<DuplicateMatch> sorted(List<DuplicateMatch> l) {
      final idx = <DuplicateMatch, int>{
        for (var i = 0; i < l.length; i++) l[i]: i,
      };
      return [...l]..sort((a, b) {
        final c = byBest(a, b);
        return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
      });
    }

    final fpLibSorted = sorted(fpLib);
    final fpStagedSorted = sorted(fpStaged);
    final exactStagedRows = [
      for (final m in exactStaged) _stagedRow(m, item.batchUuid),
    ];
    final fpStagedRows = [
      for (final m in fpStagedSorted) _stagedRow(m, item.batchUuid),
    ];
    final banners = <DuplicateBanner>[
      if (exactLib.isNotEmpty)
        DuplicateBanner(
          kind: DuplicateBannerKind.exactLibrary,
          headline: 'This audio is already in your library',
          rows: exactLib.map(_libraryRow).toList(),
          needsChoice: !chosen.contains(DuplicateGroup.library),
        ),
      if (exactStaged.isNotEmpty)
        DuplicateBanner(
          kind: DuplicateBannerKind.exactStaged,
          headline: _stagedHeadline('Same audio as ', exactStagedRows),
          rows: exactStagedRows,
          needsChoice: !chosen.contains(DuplicateGroup.staged),
        ),
      if (fpLibSorted.isNotEmpty)
        DuplicateBanner(
          kind: DuplicateBannerKind.fingerprintLibrary,
          headline: _fingerprintHeadline(fpLibSorted),
          rows: fpLibSorted.map(_libraryRow).toList(),
          needsChoice: false,
        ),
      if (fpStagedSorted.isNotEmpty)
        DuplicateBanner(
          kind: DuplicateBannerKind.fingerprintStaged,
          headline: _stagedHeadline('Sounds like ', fpStagedRows),
          rows: fpStagedRows,
          needsChoice: false,
        ),
    ];
    return DuplicateBanners._(
      banners: banners,
      useExistingTrackUuid: _firstAvailableUuid(exactLib),
      dontImportTrackUuid: _firstAvailableUuid(fpLibSorted),
      thisFile: thisFile,
      coverage: _coverage(check),
      notes: _notes(check),
    );
  }

  final List<DuplicateBanner> banners;
  final String? useExistingTrackUuid;
  final String? dontImportTrackUuid;

  /// The staged file's detected format, bitrate and duration, or null.
  final String? thisFile;

  /// What the check says when it found nothing (or could not run); null
  /// when there are matches.
  final String? coverage;

  /// The item's own coverage limits, in words.
  final List<String> notes;

  bool get needsChoice => banners.any((b) => b.needsChoice);
}

const _goneTitle = 'A track that is no longer in your library';

String? _firstAvailableUuid(List<DuplicateMatch> matches) {
  for (final m in matches) {
    final s = m.subject;
    if (s is LibraryTrackSubject && s.available == true) return s.trackUuid;
  }
  return null;
}

String? _joinKnown(List<String?> parts) {
  final known = parts.whereType<String>().toList();
  return known.isEmpty ? null : known.join(' · ');
}

String? _codec(String? codec) {
  if (codec == null || codec.isEmpty) return null;
  return codec.split('_').first.toUpperCase();
}

String? _bitrate(double? kbps) => kbps == null ? null : '${kbps.round()} kbps';

String? _duration(double? seconds) =>
    seconds == null ? null : formatTrackDuration(seconds);

String _trackName(LibraryTrackSubject t) {
  final title = t.title ?? 'Unknown title';
  return t.artist == null ? title : '$title — ${t.artist}';
}

DuplicateRow _libraryRow(DuplicateMatch m) {
  final t = m.subject as LibraryTrackSubject;
  if (t.available != true) {
    return const DuplicateRow(
      title: _goneTitle,
      details: null,
      available: false,
    );
  }
  return DuplicateRow(
    title: _trackName(t),
    details: _joinKnown([
      t.album,
      _codec(t.codec),
      _bitrate(t.bitrateKbps),
      _duration(t.durationS),
    ]),
    available: true,
    trackUuid: t.trackUuid,
  );
}

const _goneStagedTitle = 'A file that is no longer in your uploads';

DuplicateRow _stagedRow(DuplicateMatch m, String ownBatchUuid) {
  final s = m.subject as StagedItemSubject;
  final name = s.filename;
  if (s.available != true || name == null) {
    return const DuplicateRow(
      title: _goneStagedTitle,
      details: null,
      available: false,
    );
  }
  final String where;
  if (s.batchUuid != null && s.batchUuid == ownBatchUuid) {
    where = 'in this upload';
  } else if (s.batchCreatedAt != null) {
    final t = DateTime.fromMillisecondsSinceEpoch(s.batchCreatedAt! * 1000);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    where = 'in your upload from $hh:$mm';
  } else {
    where = 'in another upload';
  }
  return DuplicateRow(title: name, details: where, available: true);
}

String _stagedHeadline(String opening, List<DuplicateRow> rows) {
  final first = rows.first;
  if (!first.available) return '${opening}a file that is no longer in your uploads';
  return '$opening${first.title} ${first.details}';
}

String? _coverage(DuplicateCheck? check) {
  if (check == null) return 'Not checked for duplicates yet';
  if (!check.ranToCompletion) {
    return "The duplicate check couldn't run for this file";
  }
  if (check.matches.isNotEmpty) return null;
  return check.noDuplicatesFound(
        layers: {DuplicateLayer.exact, DuplicateLayer.fingerprint},
      )
      ? 'No duplicates found'
      : 'No matches among what could be compared';
}

List<String> _notes(DuplicateCheck check) {
  if (!check.ranToCompletion) return const [];
  final fp = check.fingerprint.subjectState;
  return [
    if (fp == 'too_short' || fp == 'low_information')
      'Too short or quiet to compare by sound'
    else if (fp == 'unavailable')
      'Only exact copies are detected on this server'
    else if (fp != 'current')
      "This file couldn't be compared by sound",
    if (check.exact.subjectState != 'current')
      "This file couldn't be checked for exact copies",
  ];
}

String _fingerprintHeadline(List<DuplicateMatch> sortedLibrary) {
  for (final m in sortedLibrary) {
    final t = m.subject as LibraryTrackSubject;
    if (t.available != true) continue;
    final opening = m.band == 'strong'
        ? 'Very likely the same recording as '
        : 'Possibly the same song as ';
    final facts = [_codec(t.codec), _duration(t.durationS)].whereType<String>();
    final suffix = facts.isEmpty ? '' : ' (${facts.join(', ')})';
    return '$opening${_trackName(t)}$suffix';
  }
  return 'Possibly the same song as a track that is no longer in your library';
}

/// A `duplicate_conflict` item: the library tracks that now match.
class DuplicateConflictView {
  const DuplicateConflictView._({
    required this.headline,
    required this.rows,
    required this.useExistingTrackUuid,
  });

  factory DuplicateConflictView.of(UploadItem item) {
    final matches = item.conflictMatches ?? const <DuplicateMatch>[];
    final library = [
      for (final m in matches)
        if (m.subject is LibraryTrackSubject) m,
    ];
    return DuplicateConflictView._(
      headline: 'This audio was added to your library after your review',
      rows: library.map(_libraryRow).toList(),
      useExistingTrackUuid: _firstAvailableUuid(library),
    );
  }

  final String headline;
  final List<DuplicateRow> rows;
  final String? useExistingTrackUuid;
}
