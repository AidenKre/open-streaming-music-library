// "UUID disambiguation if needed" (spec §6 para 3). When two listed
// tracks would read the same (same title, artist and album), each gets a
// short distinct id hint; others get none. Model code: nothing from ui/.

/// A listed track as the reader sees it; null fields are unknown.
typedef HintSubject = ({
  String uuid,
  String? title,
  String? artist,
  String? album,
});

const _startLength = 8;

/// The id hint per uuid for every subject that shares its title, artist and
/// album (case-insensitive) with another; absent for the rest. A subject
/// with no known title is never grouped.
Map<String, String> idHints(List<HintSubject> subjects) {
  final groups = <String, List<String>>{};
  for (final s in subjects) {
    final title = s.title;
    if (title == null) continue;
    final key = [title, s.artist ?? '', s.album ?? '']
        .map((v) => v.trim().toLowerCase())
        .join('\u0000');
    groups.putIfAbsent(key, () => []).add(s.uuid);
  }
  final hints = <String, String>{};
  for (final uuids in groups.values) {
    if (uuids.length < 2) continue;
    var length = _startLength;
    final longest = uuids.fold<int>(0, (m, u) => u.length > m ? u.length : m);
    while (length < longest &&
        {for (final u in uuids) _prefix(u, length)}.length < uuids.length) {
      length++;
    }
    for (final u in uuids) {
      hints[u] = _prefix(u, length);
    }
  }
  return hints;
}

String _prefix(String uuid, int length) =>
    uuid.length <= length ? uuid : uuid.substring(0, length);
