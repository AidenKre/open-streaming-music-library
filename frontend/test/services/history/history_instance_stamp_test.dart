// Phase 7B.1a exit proof (SC-01 rule 6, history stream): each
// `/history/changes` page is compared with the bound instance before it
// commits.
//  * a different instance on page 2 leaves exactly page 1's events and
//    cursor; the pass reports the change once (the different-server flow)
//    and waits like offline (no error text with ids, not "regressed");
//  * another instance's low latestRevision is an instance change, not a
//    restored server;
//  * a legacy server (no stamp) pulls as before.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/history_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/history/history_sync_service.dart';
import 'package:http/testing.dart';

import '../../helpers/server_binding.dart';

const _bound = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const _other = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';

HistoryServerEvent _server(String uuid, int revision) => HistoryServerEvent(
  payload: HistoryEventPayload(
    eventUuid: uuid,
    kind: 'play',
    entityType: 'track',
    entityRef: 't-1',
    occurredAt: 1000,
    secondsPlayed: 30.5,
  ),
  revision: revision,
  receivedAt: 9,
);

class _FakeApi extends HistoryApi {
  _FakeApi(ApiClient client) : super(api: client);
  final pulledAfter = <int>[];
  late HistoryPage Function(int after) onChanges;

  @override
  Future<Object?> post(HistoryUploadBatch batch) async => batch.eventUuids;

  @override
  Future<HistoryPage> changes({required int after, int limit = 200}) async {
    pulledAfter.add(after);
    return onChanges(after);
  }
}

void main() {
  late AppDatabase db;
  late String token;
  late HistoryRepository repo;
  late _FakeApi api;
  late SyncCursorStore cursors;
  late List<ServerInstanceChangedException> reported;
  late List<int?> reportedConnections;
  late int connectionNow;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db, instanceId: _bound);
    repo = HistoryRepository(db);
    api = _FakeApi(testApiClient(
      'http://srv',
      MockClient((_) async => throw StateError('no real requests')),
    ));
    cursors = SyncCursorStore(db);
    reported = [];
    reportedConnections = [];
    connectionNow = 7;
  });
  tearDown(() => db.close());

  HistorySyncService service() => HistorySyncService(
    repository: repo,
    api: api,
    cursors: cursors,
    verifiedToken: () => token,
    isOffline: () => false,
    supportsHistory: () async => true,
    // The connection the pass was verified on, captured when it started.
    verifiedConnection: () => connectionNow,
    onServerInstanceChanged: (e, connection) {
      reported.add(e);
      reportedConnections.add(connection);
    },
  );

  Future<List<String>> eventUuids() async => [
    for (final r in await db
        .customSelect('SELECT event_uuid FROM history_events ORDER BY event_uuid')
        .get())
      r.read<String>('event_uuid'),
  ];

  test('a different instance on page 2 leaves page 1 only', () async {
    api.onChanges = (after) => switch (after) {
      0 => HistoryPage(
        events: [_server('x1', 3)],
        nextCursor: 3,
        latestRevision: 7,
        servedBy: _bound,
      ),
      3 => HistoryPage(
        events: [_server('x2', 7)],
        nextCursor: null,
        latestRevision: 7,
        servedBy: _other,
      ),
      _ => throw StateError('unexpected after=$after'),
    };
    final pages = api.onChanges;
    api.onChanges = (after) {
      // A newer connection verified while this pass was running: the report
      // must name the connection the pass started on.
      if (after == 3) connectionNow = 8;
      return pages(after);
    };
    final s = service();

    final out = await s.runPass({'poll'});

    expect(out, isA<PassFailed>()
        .having((f) => f.reason, 'reason', BackoffReason.offline));
    expect(await eventUuids(), ['x1']);
    expect(await cursors.read(SyncStream.history), 3);
    expect(reported, hasLength(1));
    expect(reported.single.servedBy, _other);
    expect(reportedConnections, [7]);
    expect(s.status.value.serverRegressed, isFalse);
    expect(s.status.value.lastError ?? '', isNot(contains(_other)));
    expect(s.status.value.lastError ?? '', isNot(contains(_bound)));
  });

  test("another instance's low latestRevision is not a restored server",
      () async {
    await repo.applyPage(token,
        requestedAfter: 0,
        page: HistoryPage(
            events: [_server('x1', 50)], nextCursor: null, latestRevision: 50));
    api.onChanges = (after) => HistoryPage(
      events: const [],
      nextCursor: null,
      latestRevision: 2,
      servedBy: _other,
    );
    final s = service();

    final out = await s.runPass({'poll'});

    expect(out, isA<PassFailed>()
        .having((f) => f.reason, 'reason', BackoffReason.offline));
    expect(s.status.value.serverRegressed, isFalse);
    expect(reported, hasLength(1));
    expect(await cursors.read(SyncStream.history), 50);
  });

  test('a legacy server (no stamp) pulls as before', () async {
    api.onChanges = (after) => switch (after) {
      0 => HistoryPage(events: [_server('x1', 3)], nextCursor: 3, latestRevision: 7),
      3 => HistoryPage(events: [_server('x2', 7)], nextCursor: null, latestRevision: 7),
      _ => throw StateError('unexpected after=$after'),
    };

    expect(await service().runPass({'poll'}), isA<PassDone>());

    expect(await eventUuids(), ['x1', 'x2']);
    expect(await cursors.read(SyncStream.history), 7);
    expect(reported, isEmpty);
  });

  test('the repository refuses a mismatched page on its own', () async {
    await expectLater(
      repo.applyPage(token,
          requestedAfter: 0,
          page: HistoryPage(
            events: [_server('x1', 3)],
            nextCursor: null,
            latestRevision: 3,
            servedBy: _other,
          )),
      throwsA(isA<ServerInstanceChangedException>()),
    );
    expect(await eventUuids(), isEmpty);
    expect(await cursors.read(SyncStream.history), 0);
  });
}
