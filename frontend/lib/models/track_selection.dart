/// One selected track: its UUID and the revision it had when selected.
///
/// A null [baseRevision] means the revision is unknown; it is never 0.
class SelectedTrack {
  const SelectedTrack({required this.uuid, required this.baseRevision});

  final String uuid;
  final int? baseRevision;

  @override
  bool operator ==(Object other) =>
      other is SelectedTrack &&
      other.uuid == uuid &&
      other.baseRevision == baseRevision;

  @override
  int get hashCode => Object.hash(uuid, baseRevision);
}

/// SC-17 selection: an ordered set of (uuid, base revision) pairs, in
/// selection order. Immutable; [toggled] returns a new value.
///
/// The only way to change the revision of an already selected entry is the
/// explicit [withRevision], used by a user's Refresh after a server preview
/// reported a newer revision. Nothing updates revisions silently.
class TrackSelection {
  const TrackSelection.empty() : _entries = const [];

  TrackSelection._(List<SelectedTrack> entries)
    : _entries = List.unmodifiable(entries);

  /// Always unmodifiable (built once), so [entries] can hand it out as is.
  final List<SelectedTrack> _entries;

  /// Selected entries in selection order (unmodifiable).
  List<SelectedTrack> get entries => _entries;

  int get count => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  bool contains(String uuid) => _entries.any((e) => e.uuid == uuid);

  /// Removes [uuid] if selected (whatever [baseRevision] is passed);
  /// otherwise appends it with [baseRevision].
  TrackSelection toggled({required String uuid, required int? baseRevision}) {
    if (contains(uuid)) {
      return TrackSelection._([
        for (final e in _entries)
          if (e.uuid != uuid) e,
      ]);
    }
    return TrackSelection._([
      ..._entries,
      SelectedTrack(uuid: uuid, baseRevision: baseRevision),
    ]);
  }

  /// Removes the entry with [uuid] (by id alone), keeping order; an equal
  /// selection if it is not selected.
  TrackSelection without(String uuid) => TrackSelection._([
    for (final e in _entries)
      if (e.uuid != uuid) e,
  ]);

  /// Replaces the revision of the selected [uuid] in place. Never selects an
  /// unselected [uuid].
  TrackSelection withRevision(String uuid, int revision) => TrackSelection._([
    for (final e in _entries)
      if (e.uuid == uuid)
        SelectedTrack(uuid: uuid, baseRevision: revision)
      else
        e,
  ]);
}
