// TR-UPLOAD-06 (with U32-FE-UPL-REVIEW-B-01): spec §7 "After imported result
// request normal track sync". The library sync follows an item becoming
// imported or duplicate in the local intents, whoever wrote it (the status
// poll, a review answer, a review re-read) and whether or not a review page
// shows the item. Model code, no page involved. A sync that fails, or does
// not run (offline, no verified connection), is tried again on the shared
// background runner's backoff, a bounded number of times; it never changes
// the import's row.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/uploads/upload_import_sync.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/providers/providers.dart'
    show TrackSyncNotifier, serverBindingRepositoryProvider,
        trackSyncProvider;
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/uploads/upload_manager.dart'
    show uploadIntentStoreProvider;

import '../../helpers/upload_intent_record.dart';
import '../../helpers/upload_manager_harness.dart' show ManualTimers;

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
  late bool ran;
  late ManualTimers timers;
  late UploadImportSync sync;

  setUp(() {
    syncs = 0;
    gate = null;
    error = null;
    ran = true;
    timers = ManualTimers();
    sync = UploadImportSync(
      () async {
        syncs++;
        await gate?.future;
        if (error != null) throw error!;
        return ran;
      },
      timer: timers.call,
      backoff: BackoffSchedule(jitter: 0),
    );
  });
  tearDown(() => sync.close());

  /// An item turning imported (a new item each time).
  var n = 0;
  void anImport() {
    final uuid = 'x-${n++}';
    sync.onIntents(_list({uuid: 'committing'}));
    sync.onIntents(_list({uuid: 'imported'}));
  }

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

  test('a failed sync is not thrown and the next import still syncs, at '
      'the retry', () async {
    error = Exception('offline');
    sync.onIntents(_list({'a': 'committing', 'b': 'committing'}));
    sync.onIntents(_list({'a': 'imported', 'b': 'committing'}));
    await pumpEventQueue();
    expect(syncs, 1);

    error = null;
    sync.onIntents(_list({'a': 'imported', 'b': 'imported'}));
    await pumpEventQueue();
    expect(syncs, 1, reason: 'the import waits for the pending retry');
    timers.fire();
    await pumpEventQueue();
    expect(syncs, 2);
  });

  group('a sync that did not happen is tried again', () {
    test('one that did not run (false) is tried again after the first '
        'backoff step, and not again once one ran', () async {
      ran = false;
      anImport();
      await pumpEventQueue();
      expect(syncs, 1);
      expect([for (final t in timers.active) t.duration],
          [const Duration(seconds: 1)]);

      ran = true;
      timers.fire();
      await pumpEventQueue();
      expect(syncs, 2);
      expect(timers.active, isEmpty);
    });

    test('one that threw is tried again the same way', () async {
      error = Exception('server error');
      anImport();
      await pumpEventQueue();
      expect(syncs, 1);
      error = null;
      timers.fire();
      await pumpEventQueue();
      expect(syncs, 2);
      expect(timers.active, isEmpty);
    });

    test('the waits grow, and after five tries again it stops until the '
        'next import', () async {
      ran = false;
      anImport();
      await pumpEventQueue();
      final waits = <Duration>[];
      while (timers.active.isNotEmpty) {
        waits.add(timers.active.single.duration);
        timers.fire();
        await pumpEventQueue();
      }
      expect(syncs, 6);
      expect(waits, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
      ]);

      // A later import asks again, at once.
      anImport();
      await pumpEventQueue();
      expect(syncs, 7);
    });

    test('closing cancels a pending retry and ignores later imports',
        () async {
      ran = false;
      anImport();
      await pumpEventQueue();
      expect(timers.active, hasLength(1));
      await sync.close();
      expect(timers.active, isEmpty);
      anImport();
      await pumpEventQueue();
      expect(syncs, 1);
    });
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
        uploadLibrarySyncProvider.overrideWithValue(() async {
          wired++;
          return true;
        }),
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

  test('a sync that did not run leaves the upload rows alone', () async {
    final intents = StreamController<List<UploadIntentRecord>>.broadcast();
    final store = _Store(intents.stream);
    var wired = 0;
    final container = ProviderContainer(
      overrides: [
        uploadIntentStoreProvider.overrideWithValue(store),
        serverBindingRepositoryProvider.overrideWithValue(_Binding()),
        uploadLibrarySyncProvider.overrideWithValue(() async {
          wired++;
          return false;
        }),
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
    expect(store.other, isEmpty, reason: 'only watched, never written');
  });

  test('disposing the scope stops it', () async {
    final intents = StreamController<List<UploadIntentRecord>>.broadcast();
    var wired = 0;
    final container = ProviderContainer(
      overrides: [
        uploadIntentStoreProvider.overrideWithValue(_Store(intents.stream)),
        serverBindingRepositoryProvider.overrideWithValue(_Binding()),
        uploadLibrarySyncProvider.overrideWithValue(() async {
          wired++;
          return true;
        }),
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

  /// Every call other than [watch].
  final other = <Symbol>[];
  @override
  Stream<List<UploadIntentRecord>> watch(String bindingToken) {
    expect(bindingToken, 'bind');
    return stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    other.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
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
