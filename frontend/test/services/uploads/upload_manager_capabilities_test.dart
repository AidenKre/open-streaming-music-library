// Phase 7 review r1, 7-R1-02: one failed `/app/info` read while online
// leaves a cached uploads block, and network work never starts on a cached
// block (SC-03). The manager therefore re-reads the capabilities itself when
// a pass finds no live block while online (like history's capability
// recheck), on every pass path: page entry, the recovery triggers and the
// capability backoff. A cached block still never starts network work, and
// offline nothing is re-read.
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_uploads_api.dart';
import '../../helpers/server_binding.dart';
import '../../helpers/upload_manager_harness.dart';

const _live = AdvertisedFeature(
  UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
  fromCache: false,
);
const _cached = AdvertisedFeature(
  UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
  fromCache: true,
);

void main() {
  late UploadHarness h;
  late int refreshes;

  setUp(() async {
    refreshes = 0;
    h = await UploadHarness.create();
    h.feature = _cached;
  });
  tearDown(() => h.dispose());

  /// A manager built with the test's capability re-read.
  Future<void> rebuild() async {
    await h.manager.quiesce();
    h.manager = h.build();
  }

  List<String> allocations() => [
    for (final c in h.api.calls)
      if (c.startsWith('allocate')) c,
  ];

  test('a cached block is read again; the live answer starts the upload '
      'without any connectivity change', () async {
    h.refreshCapabilities = () async {
      refreshes++;
      h.feature = _live;
    };
    await rebuild();
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect(refreshes, greaterThanOrEqualTo(1));
    expect(allocations(), ['allocate u-1']);
  });

  test('no uploads block at all (a failed read with no cache) is read '
      'again too', () async {
    h.feature = null;
    h.refreshCapabilities = () async {
      refreshes++;
      h.feature = _live;
    };
    await rebuild();
    await h.verify();
    h.manager.request('pageEntered');
    await h.pump();

    expect(refreshes, greaterThanOrEqualTo(1));
  });

  test('a re-read that still answers from the cache starts nothing',
      () async {
    h.refreshCapabilities = () async => refreshes++;
    await rebuild();
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect(refreshes, greaterThanOrEqualTo(1));
    expect(h.api.calls, isEmpty);
    expect((await h.states()).values, ['allocating']);
  });

  test('offline: nothing is re-read and nothing is sent', () async {
    h.offline = true;
    h.refreshCapabilities = () async {
      refreshes++;
      h.feature = _live;
    };
    await rebuild();
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect(refreshes, 0);
    expect(h.api.calls, isEmpty);
  });

  test('a live block is not read again', () async {
    h.feature = _live;
    h.refreshCapabilities = () async => refreshes++;
    await rebuild();
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect(refreshes, 0);
    expect(allocations(), ['allocate u-1']);
  });

  test('a re-read that throws is not an error: the pass waits as before',
      () async {
    h.refreshCapabilities = () async {
      refreshes++;
      throw Exception('down');
    };
    await rebuild();
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect(refreshes, greaterThanOrEqualTo(1));
    expect(h.api.calls, isEmpty);
  });

  group('wiring', () {
    test('the scope\'s manager re-reads /app/info: a cached answer, then a '
        'live one, and the waiting allocation goes out', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final token = await seedTestBinding(db, reconciled: true);
      final api = FakeUploadsApi();
      var reads = 0;
      final uploads = AppInfo.fromJson(const {
        'uploads': {'version': 1, 'limits': <String, Object?>{}},
      });
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FakeClock()),
          autoVerifiedGateOverride(),
          uploadsApiProvider.overrideWithValue(api),
          // The first read failed (the cached blob); later reads answer.
          appInfoProvider.overrideWith(
            (ref) async => ++reads == 1 ? uploads.asCached() : uploads,
          ),
        ],
      );
      addTearDown(c.dispose);
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
      // Something observes the block, as the Uploads page does.
      c.listen(uploadsFeatureProvider, (_, _) {});

      c.read(uploadManagerProvider).request('pageEntered');
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue();
        await c.read(uploadManagerProvider).idle();
      }

      expect(reads, greaterThanOrEqualTo(2));
      expect(api.calls.first, 'allocate b-1');
    });
  });

  // 7-R1-36: an advertised `receives_per_user: 0` means no transfer now
  // (a known 0 is not unknown: no fallback to one slot).
  test('7-R1-36 receives_per_user 0 runs no transfer; unknown still runs '
      'one', () async {
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 0)),
      fromCache: false,
    );
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    expect(h.api.calls, contains('allocate u-1'));
    expect(h.api.puts, isEmpty);

    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits()),
      fromCache: false,
    );
    h.manager.request('again', bypassBackoff: true);
    await h.pump();
    expect(h.api.puts, hasLength(1));
  });

  // Review (7-fix-r1-fe) R-1: a failed re-read arms the capability wait;
  // entering the Uploads page still re-reads at once.
  test('R-1 entering the page re-reads even while the capability wait is '
      'pending', () async {
    var serverBack = false;
    h.refreshCapabilities = () async {
      refreshes++;
      if (serverBack) h.feature = _live;
    };
    await rebuild();
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    expect(refreshes, 1);
    expect(h.api.calls, isEmpty);

    serverBack = true;
    (h.visible as ValueNotifier<bool>).value = true;
    await h.pump();

    expect(refreshes, 2);
    expect(allocations(), ['allocate u-1']);
  });
}
