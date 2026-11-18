/// SC-01 rule 6: the `X-Server-Instance-Id` stamp a response carries.
const serverInstanceHeader = 'x-server-instance-id';

/// The stamp in [headers] (header name matched case-insensitively, value
/// trimmed); null when the header is missing or blank (a pre-Phase-7
/// server: no stamp, no check).
///
/// A repeated header arrives comma-joined (a proxy re-adding the stamp):
/// parts that all name the same instance collapse to that one id. Differing
/// parts are returned as the joined value, which matches no instance (never
/// treated as "no stamp").
String? instanceStampFrom(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == serverInstanceHeader) {
      final value = entry.value.trim();
      if (value.isEmpty) return null;
      if (!value.contains(',')) return value;
      final parts = [
        for (final p in value.split(',')) if (p.trim().isNotEmpty) p.trim(),
      ];
      if (parts.isEmpty) return null;
      return parts.every((p) => sameServerInstance(p, parts.first))
          ? parts.first
          : value;
    }
  }
  return null;
}

/// Whether two instance ids name the same server (trimmed, case-insensitive).
bool sameServerInstance(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();
