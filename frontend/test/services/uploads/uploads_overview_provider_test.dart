// Phase 7 §7 para 3 / SC-03: the live Uploads page state combines the
// binding's intents, the manager's progress, the offline flag, the server
// block and the feature block (a cached block never enables network work).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';

import '../../helpers/upload_intent_record.dart';
import '../../helpers/fake_session_service.dart';
import '../../helpers/test_offline.dart';

class _FakeManager implements UploadManager {
  final progressNotifier = ValueNotifier<Map<String, int>>(const {});
  @override
  ValueListenable<Map<String, int>> get progress => progressNotifier;
  // TR-UPLOAD-03: the server's per-item retryable flags (none here).
  final retryableNotifier = ValueNotifier<Map<String, bool>>(const {});
  @override
  ValueListenable<Map<String, bool>> get retryable => retryableNotifier;
  // Sign-off s7-app-texts: the uploads another device is sending (none).
  final otherDeviceNotifier = ValueNotifier<Set<String>>(const {});
  @override
  ValueListenable<Set<String>> get otherDeviceSending => otherDeviceNotifier;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UploadIntentRecord _intent(String uuid, String state) => intentRecord(
  uuid,
  batchUuid: 'b',
  displayName: '$uuid.flac',
  state: state,
  localBindingId: 'bind',
  expectedLength: 1000,
);

const _live = AdvertisedFeature(
  UploadsFeature(version: 1, limits: UploadLimits(maxFilesPerBatch: 7)),
  fromCache: false,
);

void main() {
  late StreamController<List<UploadIntentRecord>> intents;
  late _FakeManager manager;
  late FakeSessionService session;
  late TestOffline offline;

  setUp(() {
    intents = StreamController<List<UploadIntentRecord>>.broadcast();
    manager = _FakeManager();
    session = FakeSessionService();
    offline = TestOffline(false);
  });
  tearDown(() => intents.close());

  ProviderContainer container({
    Future<AdvertisedFeature<UploadsFeature>?> Function()? feature,
  }) {
    final c = ProviderContainer(
      overrides: [
        uploadIntentsProvider.overrideWith((ref) => intents.stream),
        uploadManagerProvider.overrideWithValue(manager),
        sessionServiceProvider.overrideWithValue(session),
        offlineModeProvider.overrideWith(() => offline),
        uploadsFeatureProvider.overrideWith(
          (ref) => (feature ?? () async => _live)(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Listens (Riverpod 3 pauses unlistened providers) and returns a reader.
  UploadsOverview? Function() watch(ProviderContainer c) {
    final sub = c.listen(uploadsOverviewProvider, (_, _) {});
    return () => sub.read();
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('null until the intents load, then one row per intent', () async {
    final c = container();
    final read = watch(c);
    await settle();
    expect(read(), isNull);
    intents.add([_intent('a', 'allocated'), _intent('b', 'review_ready')]);
    await settle();
    expect([for (final r in read()!.rows) r.itemUuid], ['a', 'b']);
    expect(read()!.availability, UploadsAvailability.available);
    expect(read()!.limitsText, 'Up to 7 files at a time');
    intents.add([_intent('a', 'imported')]);
    await settle();
    expect(read()!.rows.single.statusText, 'Imported');
  });

  test("the manager's progress shows on the sending row, live", () async {
    final c = container();
    final read = watch(c);
    intents.add([_intent('a', 'transferring')]);
    await settle();
    expect(read()!.rows.single.sentBytes, isNull);
    manager.progressNotifier.value = const {'a': 250};
    await settle();
    expect(c.read(uploadProgressProvider), const {'a': 250});
    expect(read()!.rows.single.sentBytes, 250);
    expect(read()!.rows.single.fraction, 0.25);
  });

  test("the manager's other-device reading shows on the waiting row, live",
      () async {
    final c = container();
    final read = watch(c);
    intents.add([_intent('a', 'on_other_device')]);
    await settle();
    expect(read()!.rows.single.needsAttention, isTrue);
    manager.otherDeviceNotifier.value = const {'b'};
    await settle();
    expect(read()!.rows.single.detailText,
        'Another device is sending this upload.');
    expect(read()!.rows.single.needsAttention, isFalse);
  });

  test('offline: cached statuses, network actions off', () async {
    final c = container();
    final read = watch(c);
    intents.add([_intent('a', 'review_ready')]);
    await settle();
    expect(read()!.rows.single.canReviewTags, isTrue);
    offline.set(true);
    await settle();
    expect(read()!.availability, UploadsAvailability.offline);
    expect(read()!.rows.single.statusText, 'Ready for review');
    expect(read()!.rows.single.canReviewTags, isFalse);
    offline.set(false);
    await settle();
    expect(read()!.availability, UploadsAvailability.available);
  });

  test('a different server or sign-out pauses network actions, live',
      () async {
    final c = container();
    final read = watch(c);
    intents.add([_intent('a', 'allocated')]);
    await settle();
    session.blocked.value = ServerBlockedReason.differentServer;
    await settle();
    expect(c.read(uploadsServerBlockedProvider),
        ServerBlockedReason.differentServer);
    expect(read()!.availability, UploadsAvailability.serverBlocked);
    expect(read()!.rows.single.canCancel, isFalse);
    session.blocked.value = ServerBlockedReason.signedOut;
    await settle();
    expect(read()!.availability, UploadsAvailability.serverBlocked);
    session.blocked.value = ServerBlockedReason.none;
    await settle();
    expect(read()!.availability, UploadsAvailability.available);
  });

  test('a cached block never enables network actions (SC-03)', () async {
    final c = container(
      feature: () async => const AdvertisedFeature(
        UploadsFeature(version: 1),
        fromCache: true,
      ),
    );
    final read = watch(c);
    intents.add([_intent('a', 'allocated')]);
    await settle();
    expect(read()!.availability, UploadsAvailability.cachedOnly);
    expect(read()!.canAddFiles, isFalse);
  });

  test('a block still loading is not network-usable', () async {
    final never = Completer<AdvertisedFeature<UploadsFeature>?>();
    final c = container(feature: () => never.future);
    final read = watch(c);
    intents.add([_intent('a', 'allocated')]);
    await settle();
    expect(read()!.availability, UploadsAvailability.cachedOnly);
  });

  test('no block: not advertised', () async {
    final c = container(feature: () async => null);
    final read = watch(c);
    intents.add(const []);
    await settle();
    expect(read()!.availability, UploadsAvailability.notAdvertised);
    expect(read()!.rows, isEmpty);
  });
}
