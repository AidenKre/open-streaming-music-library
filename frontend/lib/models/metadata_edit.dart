import 'package:flutter/foundation.dart';

/// Where an edit is persisted. Mirrors the backend `write_mode`. `dbOnly`
/// updates the library DB; `dbAndMaster` also rewrites the file's tags on disk
/// (confirmation-gated) and may relocate it.
enum EditWriteMode {
  dbOnly,
  dbAndMaster;

  String get wire => this == EditWriteMode.dbAndMaster ? 'db_and_master' : 'db_only';
}

/// A persistence-neutral, in-memory description of edits to a track's editable
/// fields. The cross-phase reuse unit: the Get Info form drives it, and later
/// the outbox flush (slice 6), bulk edit, and Upload confirm-tags consume the
/// same shape — none of which it knows about.
///
/// Crucially it distinguishes **"cleared"** (key present with a `null`/empty
/// value) from **"untouched"** (key absent) via a presence set, so a flush can
/// send only what the user actually changed and an explicit clear is not lost.
@immutable
class MetadataEdit {
  /// Keys the user has touched, in stable insertion order.
  final Set<String> touched;

  /// The new value for each touched key (`null` means "clear this field").
  final Map<String, Object?> values;

  const MetadataEdit._(this.touched, this.values);

  const MetadataEdit.empty() : touched = const {}, values = const {};

  bool get isEmpty => touched.isEmpty;
  bool get isNotEmpty => touched.isNotEmpty;

  bool isTouched(String key) => touched.contains(key);

  /// The edited value for [key] if touched, else [current] (the stored value).
  Object? effective(String key, Object? current) =>
      touched.contains(key) ? values[key] : current;

  /// Returns a copy with [key] set to [value] (marks it touched). A `null`
  /// [value] records an explicit clear — still "touched".
  MetadataEdit set(String key, Object? value) {
    return MetadataEdit._(
      {...touched, key},
      {...values, key: value},
    );
  }

  /// Returns a copy with [key] reverted to untouched (e.g. a per-field server
  /// rejection in slice 6, or the user undoing a change).
  MetadataEdit clearTouched(String key) {
    if (!touched.contains(key)) return this;
    return MetadataEdit._(
      {...touched}..remove(key),
      {...values}..remove(key),
    );
  }

  /// The touched subset as a plain map — the payload a flush sends (`null`
  /// values included so a clear is transmitted).
  Map<String, Object?> toPayload() => {
    for (final key in touched) key: values[key],
  };

  @override
  bool operator ==(Object other) =>
      other is MetadataEdit &&
      setEquals(touched, other.touched) &&
      mapEquals(values, other.values);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(touched),
    Object.hashAllUnordered(values.entries.map((e) => Object.hash(e.key, e.value))),
  );
}
