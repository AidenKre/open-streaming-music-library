// 7-L-10: leaving the review page must not write provider state while the
// widget tree is being torn down. Real review controller, real preview
// controller and PreviewPlayer; fakes only below them (review model, preview
// engine, audio focus session).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';

import '../../playback/audio_focus_test.dart' show FakeTimers;
import '../../playback/preview_player_test.dart' show FakePreviewEngine;
import '../browse_harness.dart';
import '../fake_uploads_controls.dart';

class _NoSession implements AudioSessionPort {
  @override
  Stream<AudioSessionEvent> get events => const Stream.empty();
}

UploadItem _item(String uuid, {int index = 0}) => UploadItem.fromJson({
  'item_uuid': uuid,
  'batch_uuid': 'b-1',
  'parent_item_uuid': null,
  'filename': '$uuid.flac',
  'selection_index': index,
  'member_order_key': '',
  'state': 'review_ready',
  'expected_bytes': 3,
  'expected_sha256': null,
  'received_bytes': 3,
  'review_version': 1,
  'error': null,
  'created_at': 1,
  'updated_at': 1,
  'tag_write_supported': true,
  'result_track_uuid': null,
  'detected_metadata': {
    'v': 1,
    'tags': {'title': 'Title of $uuid', 'artist': null},
  },
});

class _Review implements UploadReview {
  final snap = [_item('a', index: 0), _item('b', index: 1)];

  @override
  Future<List<UploadItem>> snapshot(String batchUuid,
          {Set<String> keep = const {}}) async =>
      [...snap];

  @override
  Future<UploadItem> item(String itemUuid) async =>
      snap.firstWhere((i) => i.itemUuid == itemUuid);

  @override
  Future<MetadataEdit> draftOf(String itemUuid) async =>
      const MetadataEdit.empty();

  @override
  Future<void> saveDraft(String itemUuid, MetadataEdit edit) async {}

  @override
  Set<DuplicateGroup> chosenDuplicates(UploadItem item) => const {};

  @override
  Future<List<String>> suggestions(String key, String query) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Home extends StatelessWidget {
  const _Home();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) =>
                  const UploadReviewPage(batchUuid: 'b-1', startAt: 'a'))),
          child: const Text('open review'),
        ),
      );
}

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeTimers timers;
  late AudioFocus focus;
  late List<FakePreviewEngine> engines;
  late StreamController<List<UploadIntentRecord>> intents;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    timers = FakeTimers();
    focus = AudioFocus(_NoSession(), timer: timers.create);
    engines = [];
    intents = StreamController<List<UploadIntentRecord>>.broadcast();
  });
  tearDown(() async {
    focus.dispose();
    await intents.close();
    await harness.dispose();
    await db.close();
  });

  Future<ProviderContainer> openReview(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final review = _Review();
    await tester.pumpWidget(harness.wrap(
      const _Home(),
      appInfo: defaultAppInfo(),
      overrides: [
        uploadReviewProvider.overrideWithValue(review),
        uploadIntentsProvider.overrideWith((ref) => intents.stream),
        uploadsOverviewProvider
            .overrideWith((ref) => fakeUploadsOverview(const [])),
        uploadedTrackProvider
            .overrideWith((ref, uuid) => const Stream<TrackUI?>.empty()),
        audioFocusProvider.overrideWithValue(focus),
        previewSourceUrisProvider.overrideWithValue(PreviewSourceUris(
          baseUrl: 'http://srv:1',
          mediaToken: 'mt',
          mayAttachToken: () async => true,
          isOffline: () => false,
        )),
        previewEngineFactoryProvider.overrideWithValue(() {
          final e = FakePreviewEngine();
          engines.add(e);
          return e;
        }),
      ],
    ));
    await tester.pump();
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();
    expect(find.byType(UploadReviewPage), findsOneWidget);
    return ProviderScope.containerOf(tester.element(find.byType(_Home, skipOffstage: false)));
  }

  testWidgets(
      '7-L-10 leaving the review page while a preview plays closes it without '
      'touching provider state during dispose', (tester) async {
    final container = await openReview(tester);
    await tester.tap(find.text('Play preview'));
    await tester.pump();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(engines, hasLength(1));
    engines.single.finishLoad(const Duration(seconds: 30));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(container.read(previewPlayerProvider).status,
        isNot(PreviewStatus.idle));
    expect(focus.holder, AudioOutput.preview);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.runAsync(() => pumpEventQueue());

    expect(tester.takeException(), isNull);
    final state = container.read(previewPlayerProvider);
    expect(state.status, PreviewStatus.idle);
    expect(state.source, isNull);
    expect(engines.single.disposed, isTrue);
    expect(focus.holder, isNot(AudioOutput.preview),
        reason: 'the output is handed back');
    await teardownTree(tester);
  });

  testWidgets('7-L-10 leaving the review page with no preview raises nothing',
      (tester) async {
    await openReview(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.runAsync(() => pumpEventQueue());
    expect(tester.takeException(), isNull);
    await teardownTree(tester);
  });
}
