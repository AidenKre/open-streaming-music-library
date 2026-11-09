import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/edit_sync_mutex.dart';
import 'package:frontend/ui/edit_controller.dart';

import '../ui/browse_harness.dart';
import '../helpers/server_binding.dart';

/// Save rules that lived in GetInfoPage (SC-26: model).
void main() {
  late AppDatabase db;
  late ProviderContainer c;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    await seedLibrary(db, const [
      SeedTrack(uuid: 'u1', title: 'Song', artistId: 1, artist: 'Abba',
          albumId: 1, album: 'Arrival'),
    ]);
    c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });

  EditOutbox outbox() => c.read(editOutboxProvider);
  Future<void> queued(String writeMode) => db.customStatement(
    "INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, "
    "updated_at) VALUES ('u1', '{}', '$writeMode', 'pending', 0)",
  );

  group('planSave', () {
    test('a DB-only save with no edited field is a no-op', () async {
      expect(
        await outbox().planSave('u1', const MetadataEdit.empty(), EditWriteMode.dbOnly),
        EditSavePlan.noChanges,
      );
    });

    test('a master-file write needs confirmation, even with no field edits',
        () async {
      expect(
        await outbox().planSave('u1', const MetadataEdit.empty(), EditWriteMode.dbAndMaster),
        EditSavePlan.confirmMasterWrite,
      );
    });

    test('a DB-only save escalates to a confirmed master write when one is '
        'already queued', () async {
      await queued('db_and_master');
      expect(
        await outbox().planSave('u1', const MetadataEdit.empty().set('title', 'X'),
            EditWriteMode.dbOnly),
        EditSavePlan.confirmMasterWrite,
      );
    });

    test('an edited DB-only save is ready', () async {
      expect(
        await outbox().planSave('u1', const MetadataEdit.empty().set('title', 'X'),
            EditWriteMode.dbOnly),
        EditSavePlan.ready,
      );
    });
  });

  test('a queued master write is reported (Get info reopens with it on)',
      () async {
    expect(await outbox().hasPendingMasterWrite('u1'), isFalse);
    await queued('db_and_master');
    expect(await outbox().hasPendingMasterWrite('u1'), isTrue);
  });

  test('field suggestions come from the matching column', () async {
    expect(await outbox().fieldSuggestions('artist', 'ab'), ['Abba']);
    expect(await outbox().fieldSuggestions('album_artist', 'ab'), ['Abba']);
    expect(await outbox().fieldSuggestions('album', 'arr'), ['Arrival']);
    expect(await outbox().fieldSuggestions('title', 'so'), isEmpty);
  });

  test('submit queues the edit and starts a flush', () async {
    final spy = _FlushSpy(c);
    await spy.submit(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'X'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 3,
    );
    expect(spy.flushes, 1);
    final row = await db.select(db.pendingEdits).getSingle();
    expect(row.baseRevision, 3);
  });

  for (final offline in [false, true]) {
    test('EditController reports where a submit stands (offline=$offline)',
        () async {
      final c2 = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          offlineModeProvider.overrideWith(() => _Offline(offline)),
          editOutboxProvider.overrideWith((ref) => _FlushSpy.forRef(ref, db)),
        ],
      );
      addTearDown(c2.dispose);
      final result = await c2.read(editControlsProvider).submit(
        _track,
        const MetadataEdit.empty().set('title', 'X'),
        EditWriteMode.dbOnly,
      );
      expect(result, offline ? EditSubmitted.offline : EditSubmitted.online);
    });
  }
}

const _track = TrackUI(
  uuidId: 'u1',
  createdAt: 0,
  lastUpdated: 0,
  revision: 3,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

class _Offline extends OfflineModeNotifier {
  _Offline(this.value);
  final bool value;
  @override
  bool build() => value;
}

/// The real outbox with flush() counted (no network).
class _FlushSpy extends EditOutbox {
  _FlushSpy(ProviderContainer c)
    : super(
        db: c.read(databaseProvider),
        api: c.read(tracksApiProvider),
        mutex: c.read(editSyncMutexProvider),
        ref: c.read(_refProvider),
      );
  _FlushSpy.forRef(Ref ref, AppDatabase db)
    : super(
        db: db,
        api: ref.read(tracksApiProvider),
        mutex: ref.read(editSyncMutexProvider),
        ref: ref,
      );
  int flushes = 0;
  @override
  Future<void> flush() async => flushes++;
}

final _refProvider = Provider<Ref>((ref) => ref);
