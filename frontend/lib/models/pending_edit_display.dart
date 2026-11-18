import 'dart:convert';

import 'package:frontend/models/track_names.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// The unsent-edits banner's line: the parts that are not zero, in order,
/// joined by ` • ` (for example `2 edits pending • 1 conflict`).
String pendingEditsSummary({
  required int pending,
  required int conflicted,
  required int rejected,
}) =>
    [
      if (pending > 0) pending == 1 ? '1 edit pending' : '$pending edits pending',
      if (conflicted > 0)
        conflicted == 1 ? '1 conflict' : '$conflicted conflicts',
      if (rejected > 0) '$rejected rejected',
    ].join(' • ');

/// The name a person reads for the track of an unsent edit: the track on this
/// device (`Title — Artist`, or just `Title`), else the edit's original values
/// by the same rule, else [unknownTrackName]. Never the track's internal ID
/// (owner, 2026-11-17).
String editTrackName({TrackUI? track, String? originalValuesJson}) {
  final title = track?.title;
  if (title != null && title.isNotEmpty) return _name(title, track?.artist);
  final original = _decodeObject(originalValuesJson);
  final originalTitle = original?['title'];
  if (originalTitle is String && originalTitle.isNotEmpty) {
    final artist = original?['artist'];
    return _name(originalTitle, artist is String ? artist : null);
  }
  return unknownTrackName;
}

String _name(String title, String? artist) =>
    artist == null || artist.isEmpty ? title : '$title — $artist';

Map<String, dynamic>? _decodeObject(String? json) {
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}
