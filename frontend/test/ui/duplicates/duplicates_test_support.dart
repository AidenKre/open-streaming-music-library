// Fakes shared by the Possible duplicates tests (8B.3).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/preview_controller.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../../helpers/fake_library_tools_api.dart';
import '../browse_harness.dart' show TestOffline;

/// A track sync whose runs the test starts and finishes.
class DupSync extends TrackSyncNotifier {
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {}

  /// One finished run that deleted [deleted] locally (none: a no-op run,
  /// as on every resume).
  void runOnce({Set<String> deleted = const {}}) {
    state = const AsyncData(TrackSyncState(isSyncing: true));
    state = AsyncData(TrackSyncState(deletedTrackUuids: deleted));
  }
}

/// Records every preview input.
class RecordingPreviewControls implements PreviewControls {
  final calls = <String>[];

  @override
  Future<void> playStaged(String itemUuid) async =>
      calls.add('playStaged $itemUuid');

  @override
  Future<void> playLibraryTrack(String trackUuid) async =>
      calls.add('playLibraryTrack $trackUuid');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> close() async => calls.add('close');
}

/// A controller over a fake server: [pages] by status then cursor (null =
/// first page), [summary], and the given offline / switch state.
class DupHarness {
  DupHarness() {
    api.onListDuplicates = (status, after, limit) async =>
        pages[status]![after] ?? (throw StateError('no page $status $after'));
    api.onDuplicateSummary = () async => summary;
  }

  final api = FakeLibraryToolsApi();
  final preview = RecordingPreviewControls();
  final pages = <String, Map<String?, DuplicatePairPageDto>>{
    'open': {null: dupPage(const [])},
    'dismissed': {null: dupPage(const [])},
  };
  DuplicateSummaryDto summary = dupSummary();
  late DupSync sync;
  late TestOffline offline;
  late ProviderContainer container;
  late DuplicatesControls dup;

  /// Opens the page's controller. [extra] overrides come last.
  Future<DuplicatesControls> open({
    bool isOffline = false,
    bool serverDelete = true,
    bool fromCache = false,
    List<Override> extra = const [],
  }) async {
    offline = TestOffline(isOffline);
    container = ProviderContainer(
      overrides: [
        libraryToolsApiProvider.overrideWithValue(api),
        trackSyncProvider.overrideWith(() => sync = DupSync()),
        offlineModeProvider.overrideWith(() => offline),
        previewControlsProvider.overrideWithValue(preview),
        libraryToolsFeatureProvider.overrideWith(
          (ref) async => AdvertisedFeature(
            LibraryToolsFeature(
              version: 1,
              serverDelete: serverDelete,
              duplicateReview: true,
            ),
            fromCache: fromCache,
          ),
        ),
        ...extra,
      ],
    );
    container.listen(trackSyncProvider, (_, _) {});
    container.listen(offlineModeProvider, (_, _) {});
    container.listen(libraryToolsFeatureProvider, (_, _) {});
    await container.read(trackSyncProvider.future);
    await container.read(libraryToolsFeatureProvider.future);
    dup = container.read(duplicatesControllerFactoryProvider)();
    await pumpEventQueue();
    return dup;
  }

  List<String> keys() => [for (final p in dup.pairs) p.key];

  DuplicatePairView row(String key) =>
      dup.pairs.singleWhere((p) => p.key == key);

  void dispose() {
    dup.dispose();
    container.dispose();
  }
}
