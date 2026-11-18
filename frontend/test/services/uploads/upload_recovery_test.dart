// 7B.1d S12b: unfinished uploads resume without visiting the Uploads page
// (spec §7 para 3: "Reopening/restarting reconstructs server work"). The
// upload runner is a recovery member like history's (SC-13: recovery
// adapters call `request()`, never the pass body): a cold start, a network
// recovery or an app resume requests a pass, after capabilities are fresh.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_uploads_api.dart';
import '../../helpers/server_binding.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer c;
  late FakeUploadsApi api;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db, reconciled: true);
    api = FakeUploadsApi();
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FakeClock()),
        autoVerifiedGateOverride(),
        uploadsApiProvider.overrideWithValue(api),
        uploadsFeatureProvider.overrideWith(
          (ref) async => const AdvertisedFeature(
            UploadsFeature(version: 1),
            fromCache: false,
          ),
        ),
      ],
    );
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });

  RecoverableService member() => c
      .read(recoverablesProvider)
      .singleWhere((m) => m.recoveryPriority == RecoveryPriority.uploads);

  test('a recovery member for uploads, after capabilities, on every '
      'trigger, gated on the binding', () {
    final m = member();
    expect(m.requiresBinding, isTrue);
    expect(m.triggers, RecoveryTrigger.values.toSet());
    expect(RecoveryPriority.uploads, lessThan(RecoveryPriority.appInfo));
  });

  test('a cold start resumes an unfinished allocation', () async {
    await UploadIntentStore(
      db: db,
      binding: ServerBindingRepository(db),
      clock: FakeClock(),
    ).insertAll(token, [
      const NewUploadIntent(
        itemUuid: 'i-1',
        batchUuid: 'b-1',
        selectionIndex: 0,
        displayName: 'a.flac',
        descriptor: UploadSourceDescriptor(
          path: '/nowhere/a.flac',
          length: 3,
          sha256:
              'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        ),
      ),
    ], state: UploadIntentState.allocating);

    await member().recover(RecoveryTrigger.coldStart);
    for (var i = 0; i < 10; i++) {
      await pumpEventQueue();
      await c.read(uploadManagerProvider).idle();
    }

    expect(api.calls.first, 'allocate b-1');
  });
}
