import 'dart:math' show Random;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/jobs_api.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The catalog-sync state machine lives in its own file; re-exported so
// importers keep working.
export 'package:frontend/services/track_sync.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden');
});

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

/// Edits, the single-track refetch and `/changes` pages: every response is
/// checked against the bound instance ([boundApiClientProvider]).
final tracksApiProvider = Provider<TracksApi>(
  (ref) => TracksApi(api: ref.read(boundApiClientProvider)),
);

final jobsApiProvider = Provider<JobsApi>(
  (ref) => JobsApi(api: ref.read(apiClientProvider)),
);

/// The generator every queue shuffle draws from (SC-27: injected, so tests
/// can seed it).
final queueRandomProvider = Provider<Random>((ref) => Random());

/// Scope-bound: closed (refusing writes) when its session scope is disposed.
final queueRepositoryProvider = Provider<QueueRepository>((ref) {
  final repo = QueueRepository(
    ref.read(databaseProvider),
    random: ref.read(queueRandomProvider),
  );
  ref.onDispose(repo.close);
  return repo;
});

final browseRepositoryProvider = Provider<BrowseRepository>((ref) {
  return BrowseRepository(ref.read(databaseProvider));
});

/// Home's recents read model, built on this scope's database.
final recentlyPlayedRepositoryProvider = Provider<RecentlyPlayedRepository>(
  (ref) => RecentlyPlayedRepository(
    ref.read(databaseProvider),
    ref.read(browseRepositoryProvider),
  ),
);

final serverBindingRepositoryProvider = Provider<ServerBindingRepository>((
  ref,
) {
  return ServerBindingRepository(ref.read(databaseProvider));
});

/// The scope's API client whose every response is checked against the bound
/// server instance (SC-01 rule 6). Network work that changes server state or
/// applies server data uses it (edit outbox, history, single-track refetch;
/// uploads 7B.1c/7B.1d build `UploadsApi` on it).
final boundApiClientProvider = Provider<ApiClient>(
  (ref) => ref
      .watch(apiClientProvider)
      .withInstanceCheck(ref.read(serverBindingRepositoryProvider).checkServedBy),
);
