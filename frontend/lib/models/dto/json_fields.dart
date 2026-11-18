/// Strict readers for API DTOs: a [FormatException] on a missing or
/// wrong-typed field; a nullable field keeps null as unknown (never 0/false).
/// An int field must be a Dart `int` (not a double or a string), except
/// through [jsonWholeInt], which also takes a whole float.
library;

/// [json] as a string-keyed object, else a [FormatException] naming [what].
Map<String, dynamic> jsonObject(Object? json, String what) {
  if (json is! Map) throw FormatException('$what must be an object');
  return json.cast<String, dynamic>();
}

String jsonString(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is String) return v;
  throw FormatException('$key must be a string');
}

String? jsonStringOrNull(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v == null || v is String) return v as String?;
  throw FormatException('$key must be a string or null');
}

int jsonInt(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is int) return v;
  throw FormatException('$key must be an integer');
}

int? jsonIntOrNull(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v == null || v is int) return v as int?;
  throw FormatException('$key must be an integer or null');
}

bool jsonBool(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is bool) return v;
  throw FormatException('$key must be a boolean');
}

bool? jsonBoolOrNull(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v == null || v is bool) return v as bool?;
  throw FormatException('$key must be a boolean or null');
}

List<Object?> jsonList(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is List) return v.cast<Object?>();
  throw FormatException('$key must be a list');
}

List<String> jsonStringList(Map<String, dynamic> m, String key) {
  final out = <String>[];
  for (final e in jsonList(m, key)) {
    if (e is! String) throw FormatException('$key entries must be strings');
    out.add(e);
  }
  return out;
}

Map<String, int> jsonIntMap(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! Map) throw FormatException('$key must be an object');
  final out = <String, int>{};
  for (final e in v.entries) {
    final k = e.key;
    final n = e.value;
    if (k is! String || n is! int) {
      throw FormatException('$key entries must be ints');
    }
    out[k] = n;
  }
  return out;
}

/// Any JSON number as a double (a whole float may arrive as an int), else
/// null when null; a [FormatException] for anything else (e.g. a string).
double? jsonDoubleOrNull(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  throw FormatException('$key must be a number or null');
}

/// A whole JSON number as an int, the tolerance the catalog readers always
/// had: an int, or a float with no fractional part (`3.0` reads 3). A
/// missing key, null, a fraction (`3.5`), a string or any other type is a
/// [FormatException]; nothing malformed is read as 0.
int jsonWholeInt(Map<String, dynamic> m, String key) {
  final v = jsonWholeIntOrNull(m, key);
  if (v != null) return v;
  throw FormatException('$key must be an integer');
}

/// [jsonWholeInt] for a nullable field: missing or null is unknown (null),
/// never 0; anything else that is not a whole number is a
/// [FormatException].
int? jsonWholeIntOrNull(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v == null || v is int) return v as int?;
  if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt();
  throw FormatException('$key must be an integer or null');
}
