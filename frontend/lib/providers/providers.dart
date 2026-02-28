import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase(openAppDatabase());
});

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

final tracksApiProvider = Provider<TracksApi>((ref) => TracksApi());

class TrackSyncState {
  final bool isSyncing;
  final String? error;

  const TrackSyncState({this.isSyncing = false, this.error});

  TrackSyncState copyWith({bool? isSyncing, String? error}) {
    return TrackSyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      error: error,
    );
  }
}

class TrackSyncNotifier extends AsyncNotifier<TrackSyncState> {
  static const lastFetchTimeKey = 'lastFetchTime';

  @override
  Future<TrackSyncState> build() async {
    return const TrackSyncState();
  }

  Future<void> sync({String? artist, String? album}) async {
    final current = state.value;
    if (current != null && current.isSyncing) return;

    state = AsyncData(const TrackSyncState(isSyncing: true));

    try {
      final api = ref.read(tracksApiProvider);
      final db = ref.read(databaseProvider);
      final prefs = await ref.read(sharedPreferencesProvider.future);

      final lastFetchTime = prefs.getInt(lastFetchTimeKey);
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

      // First page: use time filters
      var response = await api.getTracksPage(
        newerThan: lastFetchTime,
        olderThan: now,
        artist: artist,
        album: album,
      );
      await _upsertTracks(db, response.data);

      // Follow cursor for remaining pages
      while (response.nextCursor != null) {
        response = await api.getTracksPage(cursor: response.nextCursor);
        await _upsertTracks(db, response.data);
      }

      await prefs.setInt(lastFetchTimeKey, now);
      state = AsyncData(const TrackSyncState());
    } catch (e) {
      state = AsyncData(TrackSyncState(error: e.toString()));
    }
  }

  Future<void> _upsertTracks(
    AppDatabase db,
    List<ClientTrackDto> tracks,
  ) async {
    for (final dto in tracks) {
      await db.into(db.tracks).insertOnConflictUpdate(
        tracksCompanionFromDto(dto),
      );
      await db.into(db.trackmetadata).insertOnConflictUpdate(
        trackmetadataCompanionFromDto(dto),
      );
    }
  }
}

final trackSyncProvider =
    AsyncNotifierProvider<TrackSyncNotifier, TrackSyncState>(
  TrackSyncNotifier.new,
);
