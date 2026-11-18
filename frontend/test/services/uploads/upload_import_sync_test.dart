// TR-UPLOAD-06 (with U32-FE-UPL-REVIEW-B-01): spec §7 "After imported result
// request normal track sync". The library sync follows an item becoming
// imported or duplicate in the local intents, whoever wrote it (the status
// poll, a review answer, a review re-read) and whether or not a review page
// shows the item. Model code, no page involved.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_import_sync.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/providers/providers.dart'
    show TrackSyncNotifier, serverBindingRepositoryProvider,
        trackSyncProvider;
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/uploads/upload_manager.dart'
    show uploadIntentStoreProvider;

import '../../helpers/upload_intent_record.dart';

UploadIntentRecord _intent(String uuid, String state) => intentRecord(
  uuid,
  batchUuid: 'b-1',
  displayName: '$uuid.flac',
  state: state,
  localBindingId: 'bind',
);

List<UploadIntentRecord> _list(Map<String, String> states) => [
  for (final MapEntry(:key, :value) in states.entries) _intent(key, value),
];

void main() {
  late int syncs;
  late Completer<void>? gate;
  late Object? error;
  late UploadImportSync sync;

  setUp(() {
    syncs = 0;
    gate = null;
    error = null;
    sync = UploadImportSync(() async {
      syncs++;
      await gate?.future;
      if (error != null) throw error!;
    });
  });

  test('rows already ended when first seen ask for nothing', () async {
    sync.onIntents(_list({'a': 'imported', 'b': 'duplicate'}));
    await pumpEventQueue();
    expect(syncs, 0);
  });

  test('an item turning imported asks for one library sync', () async {
    sync.onIntents(_list({'a': 'committing', 'b': 'review_ready'}));
    sync.onIntents(_list({'a': 'imported', 'b': 'review_ready'}));
    await pumpEventQueue();
    expect(syncs, 1);

    // The same state again is no new import.
    sync.onIntents(_list({'a': 'imported', 'b': 'review_ready'}));
    await pumpEventQueue();
    expect(syncs, 1);
  });

  test('closed as a duplicate also asks for a sync', () async {
    sync.onIntents(_list({'a': 'review_submitted'}));
    sync.onIntents(_list({'a': 'duplicate'}));
    await pumpEventQueue();
    expect(syncs, 1);
  });

  test('other changes ask for nothing', () async {
    sync.onIntents(_list({'a': 'committing', 'b': 'review_ready'}));
    sync.onIntents(_list({'a': 'review_ready', 'b': 'cancelled'}));
    sync.onIntents(_list({'a': 'duplicate_conflict', 'b': 'cancelled'}));
    await pumpEventQueue();
    expect(syncs, 0);
  });

  test('several imports in one change are one sync', () async {
    sync.onIntents(_list({'a': 'committing', 'b': 'committing'}));
    sync.onIntents(_list({'a': 'imported', 'b': 'duplicate'}));
    await pumpEventQueue();
    expect(syncs, 1);
  });

  test('imports while a sync runs give exactly one more sync after it',
      () async {
    gate = Completer<void>();
    sync.onIntents(_list({'a': 'committing', 'b': 'committing',
      'c': 'committing'}));
    sync.onIntents(_list({'a': 'imported', 'b': 'committing',
      'c': 'committing'}));
    await pumpEventQueue();
    expect(syncs, 1);
    sync.onIntents(_list({'a': 'imported', 'b': 'imported',
      'c': 'committing'}));
    sync.onIntents(_list({'a': 'imported', 'b': 'imported',
      'c': 'imported'}));
    await pumpEventQueue();
    expect(syncs, 1);

    final first = gate!;
    gate = null;
    first.complete();
    await pumpEventQueue();
    expect(syncs, 2);
  });

  test('a failed sync is not thrown and the next import still syncs',
      () async {
    error = Exception('offline');
    sync.onIntents(_list({'a': 'committing', 'b': 'committing'}));
    sync.onIntents(_list({'a': 'imported', 'b': 'committing'}));
    await pumpEventQueue();
    expect(syncs, 1);

    error = null;
    sync.onIntents(_list({'a': 'imported', 'b': 'imported'}));
    await pumpEventQueue();
    expect(syncs, 2);
  });

  // review r1 (rev-1 #1): the sync must not hang on Riverpod listeners
  // (Riverpod 3 pauses a provider nobody listens to, and the manager is only
  // listened while an Uploads page is shown). Read once, never listened:
  // an import still syncs.
  test('wired to the store: an import syncs while nothing listens',
      () async {
    final intents = StreamController<List<UploadIntentRecord>>.broadcast();
    var wired = 0;
    final container = ProviderContainer(
      overrides: [
        uploadIntentStoreProvider.overrideWithValue(_Store(intents.stream)),
        serverBindingRepositoryProvider.overrideWithValue(_Binding()),
        uploadLibrarySyncProvider.overrideWithValue(() async => wired++),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await intents.close();
    });
    container.read(uploadImportSyncProvider);
    await pumpEventQueue();

    intents.add(_list({'a': 'committing'}));
    await pumpEventQueue();
    intents.add(_list({'a': 'imported'}));
    await pumpEventQueue();
    expect(wired, 1);
  });

  test('disposing the scope stops it', () async {
    final intents = StreamController<List<UploadIntentRecord>>.broadcast();
    var wired = 0;
    final container = ProviderContainer(
      overrides: [
        uploadIntentStoreProvider.overrideWithValue(_Store(intents.stream)),
        serverBindingRepositoryProvider.overrideWithValue(_Binding()),
        uploadLibrarySyncProvider.overrideWithValue(() async => wired++),
      ],
    );
    container.read(uploadImportSyncProvider);
    await pumpEventQueue();
    intents.add(_list({'a': 'committing'}));
    await pumpEventQueue();
    container.dispose();
    await pumpEventQueue();
    expect(intents.hasListener, isFalse);
    await intents.close();
    expect(wired, 0);
  });

  // V-332-FE-P7 (DR-332-FE-B-01): the plain sync returns at once while
  // another sync runs (a resume, a periodic sync), and that pull may predate
  // the import. The import asks for a fresh pull: it waits out the running
  // one, then pulls.
  group('V-332-FE-P7 the import asks for a fresh pull', () {
    test('an import while another sync is in flight is one fresh pull, '
        'never the plain sync', () async {
      final intents = StreamController<List<UploadIntentRecord>>.broadcast();
      final track = _RecordingSync();
      final container = ProviderContainer(
        overrides: [
          uploadIntentStoreProvider.overrideWithValue(_Store(intents.stream)),
          serverBindingRepositoryProvider.overrideWithValue(_Binding()),
          trackSyncProvider.overrideWith(() => track),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await intents.close();
      });
      container.read(uploadImportSyncProvider);
      await pumpEventQueue();

      intents.add(_list({'a': 'committing'}));
      await pumpEventQueue();
      intents.add(_list({'a': 'imported'}));
      await pumpEventQueue();
      expect(track.calls, ['syncFresh'],
          reason: 'the plain sync is a no-op while another one runs');

      intents.add(_list({'a': 'imported'}));
      await pumpEventQueue();
      expect(track.calls, ['syncFresh']);
    });
  });
}

/// Records which track sync the import asks for.
class _RecordingSync extends TrackSyncNotifier {
  final calls = <String>[];

  @override
  Future<void> sync() async => calls.add('sync');

  @override
  Future<bool> syncFresh() async {
    calls.add('syncFresh');
    return true;
  }
}

class _Store implements UploadIntentStore {
  _Store(this.stream);
  final Stream<List<UploadIntentRecord>> stream;
  @override
  Stream<List<UploadIntentRecord>> watch(String bindingToken) {
    expect(bindingToken, 'bind');
    return stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Binding implements ServerBindingRepository {
  @override
  Future<ServerBindingRecord?> current() async => const ServerBindingRecord(
    instanceId: 'inst-1',
    localBindingId: 'bind',
    lastBaseUrl: 'http://srv:1',
    boundAtMs: 0,
    catalogReconciled: true,
    userId: 1,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
