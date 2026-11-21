// Phase 7B.2c S10: the review controller (SC-26: input → model, holds only
// presentation state; rules come from upload_review_rules.dart). Exit proof
// of the piece:
//  * the snapshot's X is stable while items arrive (Refresh adds them);
//  * Next / Previous restore each item's own values and nulls;
//  * Skip goes to the model's skip (empty edits, false);
//  * a stale version (409) keeps the item reviewable with the error, at
//    the server's new version;
//  * no auto-advance on a failure; advance only on a durable imported /
//    duplicate result.
// Plus: View track once the imported UUID resolves after a sync; preview
// stops when the item changes or the page closes; one submit at a time.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart'
    show TokenWithheldException;
import 'package:frontend/api/gated_send.dart'
    show BindingNotVerified, BindingRefusal;
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart' show databaseProvider;
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/library_tools_pages.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';

import '../../helpers/duplicate_check_fixtures.dart';
import '../../helpers/fake_uploads_api.dart' show itemJson;
import '../../helpers/upload_intent_record.dart';
import '../../repositories/catalog_seed.dart';
import '../fake_uploads_controls.dart';

UploadItem _item(
  String uuid, {
  int index = 0,
  String state = 'review_ready',
  int version = 1,
  String? title,
  String? result,
}) => UploadItem.fromJson({
  ...itemJson(
    uuid,
    filename: '$uuid.flac',
    selectionIndex: index,
    state: state,
    expectedBytes: 3,
    receivedBytes: 3,
    reviewVersion: version,
  ),
  'tag_write_supported': true,
  'result_track_uuid': result,
  'detected_metadata': {
    'v': 1,
    'tags': {'title': title ?? 'Title of $uuid', 'artist': null},
  },
});

UploadIntentRecord _intent(String uuid, String state, {String? code,
    String batch = 'b-1'}) => intentRecord(
  uuid,
  batchUuid: batch,
  displayName: '$uuid.flac',
  state: state,
  lastErrorCode: code,
  localBindingId: 'bind',
);

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Imported $uuid',
  artist: 'Artist',
  duration: 120,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

class _Review implements UploadReview {
  final calls = <String>[];
  List<UploadItem> snap = [];
  Object? snapshotError;
  Set<String>? lastKeep;
  final server = <String, UploadItem>{};
  final drafts = <String, MetadataEdit>{};
  final saved = <(String, MetadataEdit)>[];
  final confirmed = <(String, int, MetadataEdit, bool)>[];
  Object? submitError;
  Completer<void>? submitGate;

  @override
  Future<List<UploadItem>> snapshot(String batchUuid,
      {Set<String> keep = const {}}) async {
    calls.add('snapshot $batchUuid');
    lastKeep = keep;
    // The list as the server had it when the read started.
    final answer = [...snap];
    await snapshotGate?.future;
    if (snapshotError != null) throw snapshotError!;
    return answer;
  }

  /// When set, every snapshot() read waits for it.
  Completer<void>? snapshotGate;

  Object? itemError;
  Completer<void>? itemGate;
  Object? draftError;
  Object? saveError;

  /// When set, every item() read waits for its own completer here.
  bool holdEachRead = false;
  final heldReads = <(String, Completer<UploadItem>)>[];

  @override
  Future<UploadItem> item(String itemUuid) async {
    calls.add('item $itemUuid');
    if (holdEachRead) {
      final c = Completer<UploadItem>();
      heldReads.add((itemUuid, c));
      return c.future;
    }
    await itemGate?.future;
    if (itemError != null) throw itemError!;
    return server[itemUuid] ??
        snap.firstWhere((i) => i.itemUuid == itemUuid);
  }

  /// Holds one item's draft load until completed.
  final draftGates = <String, Completer<void>>{};

  @override
  Future<MetadataEdit> draftOf(String itemUuid) async {
    await draftGates[itemUuid]?.future;
    if (draftError != null) throw draftError!;
    return drafts[itemUuid] ?? const MetadataEdit.empty();
  }

  @override
  Future<void> saveDraft(String itemUuid, MetadataEdit edit) async {
    saved.add((itemUuid, edit));
    if (saveError != null) throw saveError!;
  }

  @override
  Future<void> confirm(UploadItem item, MetadataEdit edits,
      {required bool writeTags}) async {
    calls.add('confirm ${item.itemUuid} v${item.reviewVersion}');
    confirmed.add((item.itemUuid, item.reviewVersion, edits, writeTags));
    await submitGate?.future;
    if (submitError != null) throw submitError!;
  }

  @override
  Future<void> skip(UploadItem item) async {
    calls.add('skip ${item.itemUuid} v${item.reviewVersion}');
    await submitGate?.future;
    if (submitError != null) throw submitError!;
  }

  @override
  Future<void> cancel(String itemUuid) async => calls.add('cancel $itemUuid');

  @override
  Future<List<String>> suggestions(String key, String query) async {
    calls.add('suggestions $key $query');
    return ['$query-1'];
  }

  // No syncLibrary: the library sync after an import is the model's
  // (UploadImportSync, TR-UPLOAD-06); a call from the controller would hit
  // noSuchMethod and fail the test.

  final chosen = <String, Set<DuplicateGroup>>{};
  RetryOutcome retryOutcome = RetryOutcome.accepted;
  Object? retryError;

  @override
  void chooseDuplicates(UploadItem item, DuplicateGroup group) {
    calls.add('choose ${item.itemUuid} v${item.reviewVersion} ${group.name}');
    (chosen[item.itemUuid] ??= {}).add(group);
  }

  @override
  Set<DuplicateGroup> chosenDuplicates(UploadItem item) =>
      chosen[item.itemUuid] ?? const {};

  @override
  Future<void> resolveDuplicate(UploadItem item, String trackUuid) async {
    calls.add('resolve ${item.itemUuid} v${item.reviewVersion} $trackUuid');
    await submitGate?.future;
    if (submitError != null) throw submitError!;
  }

  @override
  Future<RetryOutcome> backToReview(String itemUuid) async {
    calls.add('backToReview $itemUuid');
    if (retryError != null) throw retryError!;
    return retryOutcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preview implements PreviewControls {
  final calls = <String>[];
  @override
  Future<void> playStaged(String itemUuid) async =>
      calls.add('playStaged $itemUuid');
  @override
  Future<void> playLibraryTrack(String trackUuid) async =>
      calls.add('playLibrary $trackUuid');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> close() async => calls.add('close');
}

void main() {
  late _Review review;
  late _Preview preview;
  late StreamController<List<UploadIntentRecord>> intents;
  late StateProvider<UploadsOverview?> overview;
  late Map<String, StreamController<TrackUI?>> tracks;
  late StateProvider<ServerBlockedReason> blocked;
  late ProviderContainer container;

  setUp(() {
    review = _Review()
      ..snap = [_item('a', index: 0), _item('b', index: 1),
        _item('c', index: 2)];
    preview = _Preview();
    intents = StreamController<List<UploadIntentRecord>>.broadcast();
    overview = StateProvider<UploadsOverview?>(
      (ref) => fakeUploadsOverview(const []),
    );
    tracks = {};
    blocked = StateProvider<ServerBlockedReason>(
      (ref) => ServerBlockedReason.none,
    );
    container = ProviderContainer(
      overrides: [
        libraryToolsServerBlockedProvider.overrideWith(
          (ref) => ref.watch(blocked),
        ),
        uploadReviewProvider.overrideWithValue(review),
        appInfoProvider.overrideWith((ref) async => defaultAppInfo()),
        previewControlsProvider.overrideWithValue(preview),
        uploadIntentsProvider.overrideWith((ref) => intents.stream),
        uploadsOverviewProvider.overrideWith((ref) => ref.watch(overview)),
        uploadedTrackProvider.overrideWith((ref, uuid) =>
            (tracks[uuid] ??= StreamController<TrackUI?>.broadcast()).stream),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await intents.close();
    for (final t in tracks.values) {
      await t.close();
    }
  });

  Future<void> settle() => pumpEventQueue();

  /// Confirm for the item and review version on screen (what the confirm
  /// sheet captures when it opens).
  Future<void> confirmShown(UploadReviewControls c,
          {required bool writeTags}) =>
      c.confirm(
        itemUuid: c.current!.itemUuid,
        reviewVersion: c.current!.reviewVersion,
        writeTags: writeTags,
      );

  Future<UploadReviewControls> started({String? at,
      List<UploadIntentRecord>? local}) async {
    final c = container.read(uploadReviewControllerFactoryProvider)();
    await c.start('b-1', startAt: at);
    intents.add(local ??
        [_intent('a', 'review_ready'), _intent('b', 'review_ready'),
          _intent('c', 'review_ready')]);
    await settle();
    return c;
  }

  void local(Map<String, (String, String?)> states) {
    intents.add([
      for (final MapEntry(:key, :value) in states.entries)
        _intent(key, value.$1, code: value.$2),
    ]);
  }

  group('snapshot and position', () {
    test('1/X from the snapshot, at the item asked for', () async {
      final c = await started(at: 'b');
      expect(c.load, ReviewLoad.ready);
      expect(c.total, 3);
      expect(c.positionText, '2/3');
      expect(c.current!.itemUuid, 'b');
      expect(c.canPrevious, isTrue);
      expect(c.canNext, isTrue);
      c.dispose();
    });

    test('X stays put while new items get ready; Refresh adds them and '
        'keeps the current item', () async {
      final c = await started(at: 'b');
      local({
        'a': ('review_ready', null),
        'b': ('review_ready', null),
        'c': ('review_ready', null),
        'd': ('review_ready', null),
      });
      await settle();
      expect(c.total, 3);
      expect(c.moreItemsReady, isTrue);

      review.snap = [..._abc(), _item('d', index: 3)];
      await c.refresh();
      await settle();

      expect(review.lastKeep, {'a', 'b', 'c'});
      expect(c.total, 4);
      expect(c.current!.itemUuid, 'b');
      expect(c.positionText, '2/4');
      expect(c.moreItemsReady, isFalse);
      c.dispose();
    });

    test('a snapshot that fails to load says so; starting again works',
        () async {
      review.snapshotError = Exception('down');
      final c = container.read(uploadReviewControllerFactoryProvider)();
      await c.start('b-1');
      expect(c.load, ReviewLoad.failed);
      review.snapshotError = null;
      await c.start('b-1');
      expect(c.load, ReviewLoad.ready);
      c.dispose();
    });

    test('nothing ready: no current item, no position', () async {
      review.snap = [];
      final c = await started();
      expect(c.total, 0);
      expect(c.current, isNull);
      expect(c.positionText, '');
      c.dispose();
    });
  });

  // A failed load says why, and offers Try again only where it
  // can help (a different server or a sign-out is cleared by the banner).
  group('a failed load names its reason', () {
    Future<UploadReviewControls> failedWith(Object error,
        {ServerBlockedReason block = ServerBlockedReason.none,
        String? at}) async {
      container.read(blocked.notifier).state = block;
      review.snapshotError = error;
      final c = container.read(uploadReviewControllerFactoryProvider)();
      await c.start('b-1', startAt: at);
      expect(c.load, ReviewLoad.failed);
      return c;
    }

    test('a different server: that reason, Try again does not help',
        () async {
      final c = await failedWith(
        const BindingNotVerified(BindingRefusal.differentServer),
        block: ServerBlockedReason.differentServer,
      );
      expect(c.loadUnreachable, LibraryToolsUnreachable.differentServer);
      expect(c.loadRetryHelps, isFalse);
      c.dispose();
    });

    test('signed out: that reason, Try again does not help', () async {
      final c = await failedWith(
        const BindingNotVerified(BindingRefusal.noSession),
        block: ServerBlockedReason.signedOut,
      );
      expect(c.loadUnreachable, LibraryToolsUnreachable.signedOut);
      expect(c.loadRetryHelps, isFalse);
      c.dispose();
    });

    test('not verified yet, a withheld token or a network error: needs a '
        'connection, Try again helps', () async {
      for (final error in <Object>[
        const BindingNotVerified(),
        const TokenWithheldException(),
        NetworkException('down', attemptsMade: 1),
      ]) {
        final c = await failedWith(error);
        expect(c.loadUnreachable, LibraryToolsUnreachable.needsConnection,
            reason: '$error');
        expect(c.loadRetryHelps, isTrue, reason: '$error');
        c.dispose();
      }
    });

    test('any other failure: no reason, Try again helps', () async {
      final c = await failedWith(StateError('broken'));
      expect(c.loadUnreachable, isNull);
      expect(c.loadRetryHelps, isTrue);
      c.dispose();
    });

    // While the session is blocked, the banner's reason is the page's
    // reason, whatever made the load fail: Try again cannot clear a block.
    test('any other failure while the session is blocked: the block\'s '
        'reason, Try again does not help', () async {
      final c = await failedWith(
        StateError('broken'),
        block: ServerBlockedReason.signedOut,
      );
      expect(c.loadUnreachable, LibraryToolsUnreachable.signedOut);
      expect(c.loadRetryHelps, isFalse);
      c.dispose();
    });

    test('any other failure, then the session signs out: the block\'s '
        'reason, Try again does not help', () async {
      final c = await failedWith(StateError('broken'));
      var notified = 0;
      c.addListener(() => notified++);
      container.read(blocked.notifier).state = ServerBlockedReason.signedOut;
      await settle();
      expect(notified, greaterThan(0));
      expect(c.loadUnreachable, LibraryToolsUnreachable.signedOut);
      expect(c.loadRetryHelps, isFalse);
      c.dispose();
    });

    test('the session blocking after the failure changes the reason and '
        'takes Try again away; a load that then succeeds has no reason',
        () async {
      final c = await failedWith(const BindingNotVerified());
      var notified = 0;
      c.addListener(() => notified++);
      container.read(blocked.notifier).state = ServerBlockedReason.signedOut;
      await settle();
      expect(notified, greaterThan(0));
      expect(c.loadUnreachable, LibraryToolsUnreachable.signedOut);
      expect(c.loadRetryHelps, isFalse);

      container.read(blocked.notifier).state = ServerBlockedReason.none;
      review.snapshotError = null;
      await c.start('b-1');
      expect(c.load, ReviewLoad.ready);
      expect(c.loadUnreachable, isNull);
      c.dispose();
    });
  });

  // The review: a load refused while the session shows a different
  // server does not keep the different-server sentence once the bound
  // server answers again (the block clears): the page then shows the
  // generic failure with Try again. It does not reload by itself.
  group('the review forgets a different-server reason when the '
      'server block clears', () {
    int snapshots() =>
        review.calls.where((c) => c.startsWith('snapshot')).length;

    Future<UploadReviewControls> refusedAsDifferentServer(
        {Object error =
            const BindingNotVerified(BindingRefusal.differentServer)}) async {
      container.read(blocked.notifier).state =
          ServerBlockedReason.differentServer;
      review.snapshotError = error;
      final c = container.read(uploadReviewControllerFactoryProvider)();
      await c.start('b-1', startAt: 'b');
      expect(c.loadUnreachable, LibraryToolsUnreachable.differentServer);
      expect(c.loadRetryHelps, isFalse);
      return c;
    }

    /// The bound server answers again: the session's block clears.
    Future<void> blockClears() async {
      container.read(blocked.notifier).state = ServerBlockedReason.none;
      await settle();
    }

    test('the block clears: the generic failure with Try again, nothing read',
        () async {
      final c = await refusedAsDifferentServer();
      var notified = 0;
      c.addListener(() => notified++);
      await blockClears();
      expect(notified, greaterThan(0));
      expect(c.load, ReviewLoad.failed);
      expect(c.loadUnreachable, isNull);
      expect(c.loadRetryHelps, isTrue);
      expect(snapshots(), 1);
      c.dispose();
    });

    test('also when the load had failed for want of a connection while the '
        'block showed', () async {
      final c = await refusedAsDifferentServer(
        error: NetworkException('down', attemptsMade: 1),
      );
      await blockClears();
      expect(c.loadUnreachable, isNull);
      expect(c.loadRetryHelps, isTrue);
      c.dispose();
    });

    test('then Try again shows the files, at the item asked for', () async {
      final c = await refusedAsDifferentServer();
      await blockClears();
      review.snapshotError = null;
      await c.start('b-1', startAt: 'b');
      expect(c.load, ReviewLoad.ready);
      expect(c.current!.itemUuid, 'b');
      c.dispose();
    });

    test('while the server is still different, the reason stays', () async {
      final c = await refusedAsDifferentServer();
      await settle();
      expect(c.loadUnreachable, LibraryToolsUnreachable.differentServer);
      expect(c.loadRetryHelps, isFalse);
      c.dispose();
    });

    test('a closed page hears nothing when the block clears', () async {
      final c = await refusedAsDifferentServer();
      var notified = 0;
      c.addListener(() => notified++);
      c.dispose();
      await blockClears();
      expect(notified, 0);
      expect(snapshots(), 1);
    });

    test('a block that returns after clearing takes Try again away again',
        () async {
      final c = await refusedAsDifferentServer();
      await blockClears();
      expect(c.loadRetryHelps, isTrue);
      container.read(blocked.notifier).state = ServerBlockedReason.signedOut;
      await settle();
      expect(c.loadUnreachable, LibraryToolsUnreachable.signedOut);
      expect(c.loadRetryHelps, isFalse);
      expect(snapshots(), 1);
      c.dispose();
    });

    test('a failure that needed a connection while signed out: once the '
        'sign-out clears, the generic failure with Try again, and nothing '
        'reloads by itself', () async {
      container.read(blocked.notifier).state = ServerBlockedReason.signedOut;
      review.snapshotError = const BindingNotVerified();
      final c = container.read(uploadReviewControllerFactoryProvider)();
      await c.start('b-1');
      expect(c.loadUnreachable, LibraryToolsUnreachable.signedOut);
      expect(c.loadRetryHelps, isFalse);
      await blockClears();
      expect(snapshots(), 1);
      expect(c.load, ReviewLoad.failed);
      expect(c.loadUnreachable, isNull);
      expect(c.loadRetryHelps, isTrue);
      c.dispose();
    });
  });

  group('drafts and navigation', () {
    test("Next and Previous restore each item's own values and nulls",
        () async {
      review.drafts['b'] = const MetadataEdit.empty().set('title', 'Bee');
      final c = await started();
      expect(c.detectedValue('title'), 'Title of a');

      final aEdit = const MetadataEdit.empty().set('title', null);
      c.editChanged(aEdit);
      await settle();
      expect(review.saved.last, ('a', aEdit));

      await c.next();
      expect(c.current!.itemUuid, 'b');
      expect(c.edit, const MetadataEdit.empty().set('title', 'Bee'));
      expect(c.detectedValue('title'), 'Title of b');

      await c.next();
      expect(c.edit, const MetadataEdit.empty());
      expect(c.canNext, isFalse);

      await c.previous();
      await c.previous();
      expect(c.current!.itemUuid, 'a');
      expect(c.edit.isTouched('title'), isTrue);
      expect(c.edit.values['title'], isNull);
      expect(c.canPrevious, isFalse);
      c.dispose();
    });

    test('moving to an item reads it again (current version)', () async {
      final c = await started();
      review.server['b'] = _item('b', index: 1, version: 5);
      await c.next();
      expect(review.calls, contains('item b'));
      expect(c.current!.reviewVersion, 5);
      c.dispose();
    });

    test('a failed re-read on Next still moves, showing the item as last '
        'read, and is never thrown', () async {
      review.drafts['b'] = const MetadataEdit.empty().set('title', 'Bee');
      final c = await started();
      review.itemError = Exception('offline');
      await c.next();
      expect(c.current!.itemUuid, 'b');
      expect(c.positionText, '2/3');
      expect(c.edit, const MetadataEdit.empty().set('title', 'Bee'));
      c.dispose();
    });

    test('the preview stops when the item changes and when the page closes',
        () async {
      final c = await started();
      await c.next();
      expect(preview.calls, contains('close'));
      preview.calls.clear();
      c.dispose();
      expect(preview.calls, contains('close'));
    });

    test('the form fields are the server\'s editable track fields, else '
        'the built-in list', () async {
      final c = await started();
      expect([for (final f in c.fields) f.key], contains('title'));
      expect(c.fields, isNotEmpty);
      c.dispose();
    });

    test('suggestions come from the model', () async {
      final c = await started();
      expect(await c.suggestions('artist', 'Ra'), ['Ra-1']);
      c.dispose();
    });
  });

  group('submit', () {
    test('Confirm sends the current draft and the write-tags choice at the '
        "item's version", () async {
      final c = await started();
      final edit = const MetadataEdit.empty().set('album', 'X');
      c.editChanged(edit);
      await confirmShown(c, writeTags: true);
      expect(review.confirmed.single, ('a', 1, edit, true));
      c.dispose();
    });

    test('Skip goes to the model skip (empty edits, no tag writing)',
        () async {
      final c = await started();
      c.editChanged(const MetadataEdit.empty().set('title', 'ignored'));
      await c.skip();
      expect(review.calls, contains('skip a v1'));
      expect(review.confirmed, isEmpty);
      c.dispose();
    });

    test('one submit at a time: a second tap while sending sends nothing',
        () async {
      review.submitGate = Completer<void>();
      final c = await started();
      final first = confirmShown(c, writeTags: false);
      await settle();
      expect(c.busy, isTrue);
      await confirmShown(c, writeTags: false);
      await c.skip();
      review.submitGate!.complete();
      await first;
      expect(review.calls.where((x) => x.startsWith('confirm') ||
          x.startsWith('skip')), hasLength(1));
      expect(c.busy, isFalse);
      c.dispose();
    });

    // Refactor APP-UPLOAD, section 6 #4 (owner 2026-11-17): Cancel and the
    // duplicate choice wait for a review submit, like Confirm and Skip.
    test('while a submit is being sent, Cancel and the duplicate choice do '
        'nothing; Cancel works again once the submit ended', () async {
      review.submitGate = Completer<void>();
      final c = await started();
      final first = confirmShown(c, writeTags: false);
      await settle();
      expect(c.busy, isTrue);
      expect(c.current!.canCancel, isTrue);
      expect(c.current!.canDecideDuplicates, isTrue);

      await c.cancelItem();
      c.chooseDuplicates(DuplicateGroup.library);
      expect(
        review.calls.where(
            (x) => x.startsWith('cancel') || x.startsWith('choose')),
        isEmpty,
      );
      expect(review.chosen, isEmpty);

      review.submitGate!.complete();
      await first;
      expect(c.busy, isFalse);
      await c.cancelItem();
      expect(review.calls, contains('cancel a'));
      c.dispose();
    });

    test('offline: Confirm, Skip and Cancel send nothing', () async {
      final c = await started();
      container.read(overview.notifier).state = fakeUploadsOverview(const [],
          availability: UploadsAvailability.offline);
      await settle();
      expect(c.current!.canConfirm, isFalse);
      await confirmShown(c, writeTags: false);
      await c.skip();
      await c.cancelItem();
      expect(review.confirmed, isEmpty);
      expect(review.calls.where((x) => x.startsWith('skip') ||
          x.startsWith('cancel')), isEmpty);
      c.dispose();
    });

    test('a changed request under the same version is explained', () async {
      review.submitError = SubmissionConflict('op');
      final c = await started();
      await confirmShown(c, writeTags: false);
      expect(c.notice, 'This file is already being imported.');
      c.dispose();
    });

    test('an unexpected failure is explained, never thrown', () async {
      review.submitError = Exception('boom');
      final c = await started();
      await c.skip();
      expect(c.notice, 'Something went wrong. Try again.');
      c.dispose();
    });

    test('Cancel this item cancels the current item', () async {
      final c = await started(at: 'c');
      await c.cancelItem();
      expect(review.calls, contains('cancel c'));
      c.dispose();
    });
  });

  // Refactor APP-UPLOAD (sign-off s7-app-texts, cascade-8 review #1): the
  // review page reads the same other-device check as the Uploads page.
  group('another device is sending the upload', () {
    test('a waiting row reads as being sent while the upload is seen '
        'arriving, and as not found here once it is not', () async {
      final c = await started(local: [
        _intent('a', 'on_other_device'),
        _intent('b', 'review_ready'),
        _intent('c', 'review_ready'),
      ]);
      container.read(overview.notifier).state =
          fakeUploadsOverview(const [], otherDeviceSending: {'b-1'});
      await settle();
      expect(c.current!.statusText, 'Waiting for the file');
      expect(c.current!.errorText, 'Another device is sending this upload.');

      container.read(overview.notifier).state = fakeUploadsOverview(const []);
      await settle();
      expect(
        c.current!.errorText,
        "This device cannot find this file, so it can't send it. Cancel it "
        'and add it again.',
      );
      c.dispose();
    });

    test('a row being received from another device reads as such; paused '
        'transfers read Paused, as on the Uploads page', () async {
      final c = await started(local: [
        _intent('a', 'receiving'),
        _intent('b', 'review_ready'),
        _intent('c', 'review_ready'),
      ]);
      expect(c.current!.statusText, 'Uploading from another device');
      container.read(overview.notifier).state =
          fakeUploadsOverview(const [], transfersPaused: true);
      await settle();
      expect(c.current!.statusText, 'Paused');
      c.dispose();
    });
  });

  group('outcomes', () {
    test('a durable import advances, asks for a library sync and remembers '
        'what was imported', () async {
      final c = await started();
      await confirmShown(c, writeTags: false);
      local({'a': ('review_submitted', null), 'b': ('review_ready', null)});
      await settle();
      expect(c.current!.inFlight, isTrue);
      expect(c.current!.itemUuid, 'a');

      review.server['a'] = _item('a', state: 'imported', result: 't-1');
      local({'a': ('imported', null), 'b': ('review_ready', null)});
      await settle();

      expect(c.current!.itemUuid, 'b');
      expect(c.positionText, '2/3');
      expect(c.lastImported!.displayName, 'a.flac');
      c.dispose();
    });

    test('closed as a duplicate also advances', () async {
      final c = await started();
      local({'a': ('committing', null)});
      await settle();
      review.server['a'] = _item('a', state: 'duplicate', result: 't-9');
      local({'a': ('duplicate', null)});
      await settle();
      expect(c.current!.itemUuid, 'b');
      c.dispose();
    });

    // 7B.2d review r1 #1: closed as a duplicate is not "imported".
    test('r1 (7B.2d) #1 closed as a duplicate is reported as already in the '
        'library; an import is not', () async {
      final c = await started();
      local({'a': ('committing', null)});
      await settle();
      review.server['a'] = _item('a', state: 'duplicate', result: 't-9');
      local({'a': ('duplicate', null)});
      await settle();
      expect(c.lastImported!.alreadyInLibrary, isTrue);

      local({'a': ('duplicate', null), 'b': ('committing', null)});
      await settle();
      review.server['b'] = _item('b', state: 'imported', result: 't-2');
      local({'a': ('duplicate', null), 'b': ('imported', null)});
      await settle();
      expect(c.lastImported!.displayName, 'b.flac');
      expect(c.lastImported!.alreadyInLibrary, isFalse);
      c.dispose();
    });

    test('a failed import does not advance; the item stays reviewable at '
        'its new version with the reason', () async {
      final c = await started();
      local({'a': ('review_submitted', null)});
      await settle();
      review.server['a'] = _item('a', version: 2);
      local({'a': ('review_ready', 'upload_commit_failed')});
      await settle();

      expect(c.current!.itemUuid, 'a');
      expect(c.current!.reviewable, isTrue);
      expect(c.current!.reviewVersion, 2);
      expect(c.current!.errorText, isNotNull);

      await confirmShown(c, writeTags: false);
      expect(review.confirmed.single.$2, 2);
      c.dispose();
    });

    test('a stale version (409) keeps the item reviewable with the error '
        'and the next Confirm uses the server version', () async {
      final c = await started();
      local({'a': ('review_submitted', null)});
      await settle();
      review.server['a'] = _item('a', version: 3);
      local({'a': ('review_ready', 'upload_review_version_conflict')});
      await settle();

      expect(c.current!.itemUuid, 'a');
      expect(c.current!.errorText,
          'This file changed on the server since you opened it. Check it '
          'and confirm again.');
      await confirmShown(c, writeTags: false);
      expect(review.confirmed.single.$2, 3);
      c.dispose();
    });

    test('a conflict or an expiry never advances', () async {
      final c = await started();
      for (final s in ['duplicate_conflict', 'expired']) {
        local({'a': ('committing', null)});
        await settle();
        local({'a': (s, null)});
        await settle();
        expect(c.current!.itemUuid, 'a', reason: s);
      }
      expect(c.current!.canConfirm, isFalse);
      c.dispose();
    });

    test('an item imported elsewhere while the user is on another item does '
        'not move the user', () async {
      final c = await started(at: 'b');
      local({'a': ('committing', null), 'b': ('review_ready', null)});
      await settle();
      review.server['a'] = _item('a', state: 'imported', result: 't-1');
      local({'a': ('imported', null), 'b': ('review_ready', null)});
      await settle();
      expect(c.current!.itemUuid, 'b');
      c.dispose();
    });

    test('the last item imported: the review stays on it, done', () async {
      final c = await started(at: 'c');
      local({'c': ('committing', null)});
      await settle();
      review.server['c'] = _item('c', state: 'imported', result: 't-3');
      local({'c': ('imported', null)});
      await settle();
      expect(c.current!.itemUuid, 'c');
      expect(c.current!.done, isTrue);
      c.dispose();
    });
  });

  // 8B.2b (D27; spec §6 last paragraph: "Remove converted/uploaded receipt
  // navigation actions when the referenced track no longer resolves, but
  // preserve historical outcome records"; 8-C05 unit half), over real Drift:
  // the imported track resolves through the local mirror, and a sync
  // tombstone deleting it takes View track away; the outcome stays.
  group('View track after a tombstone (real Drift)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final seed = CatalogSeed(db);
      await seed.artist(1, 'Aria');
      await seed.album(1, artistId: 1, name: 'One');
      await seed.track('t-3', artistId: 1, albumId: 1);
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          uploadReviewProvider.overrideWithValue(review),
          appInfoProvider.overrideWith((ref) async => defaultAppInfo()),
          previewControlsProvider.overrideWithValue(preview),
          uploadIntentsProvider.overrideWith((ref) => intents.stream),
          uploadsOverviewProvider.overrideWith((ref) => ref.watch(overview)),
        ],
      );
    });

    Future<void> drain() async {
      for (var i = 0; i < 5; i++) {
        await settle();
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('resolves while the track exists; a tombstone removes it and the '
        'imported outcome stays', () async {
      final c = await started(at: 'c');
      local({'c': ('committing', null)});
      await settle();
      review.server['c'] = _item('c', state: 'imported', result: 't-3');
      local({'c': ('imported', null)});
      await drain();
      expect(c.currentTrack?.uuidId, 't-3');
      expect(c.lastImported?.track?.uuidId, 't-3');
      final status = c.current!.statusText;

      // What `SyncService._deleteTracks` does to the row (child first).
      await (db.delete(db.trackmetadata)
            ..where((t) => t.uuidId.equals('t-3')))
          .go();
      await (db.delete(db.tracks)..where((t) => t.uuidId.equals('t-3'))).go();
      await drain();

      expect(c.currentTrack, isNull, reason: 'no View track on the item');
      expect(c.lastImported!.track, isNull,
          reason: 'no View track on the imported line');
      expect(c.lastImported!.displayName, 'c.flac');
      expect(c.current!.itemUuid, 'c');
      expect(c.current!.done, isTrue);
      expect(c.current!.statusText, status, reason: 'the outcome is kept');
      c.dispose();
    });
  });

  // U32-FE-UPL-REVIEW-B-01: the import already succeeded on the server (the
  // intent turned imported / duplicate); a failed follow-up read of the item
  // must not lose the advance or the note (spec §7: advance after the durable
  // result); the read is tried again, so View track still appears. The
  // library sync itself is the model's (upload_import_sync_test.dart).
  group('U32-FE-UPL-REVIEW-B-01 a failed read at the import', () {
    test('still advances and notes the import', () async {
      final c = await started();
      local({'a': ('committing', null), 'b': ('review_ready', null)});
      await settle();
      review.itemError = Exception('offline');
      local({'a': ('imported', null), 'b': ('review_ready', null)});
      await settle();

      expect(c.current!.itemUuid, 'b');
      expect(c.positionText, '2/3');
      expect(c.lastImported!.displayName, 'a.flac');
      expect(c.lastImported!.alreadyInLibrary, isFalse);
      expect(c.lastImported!.track, isNull);
      c.dispose();
    });

    test('closed as a duplicate: advances and says already in the library',
        () async {
      final c = await started();
      local({'a': ('committing', null)});
      await settle();
      review.itemError = Exception('offline');
      local({'a': ('duplicate', null)});
      await settle();

      expect(c.current!.itemUuid, 'b');
      expect(c.lastImported!.displayName, 'a.flac');
      expect(c.lastImported!.alreadyInLibrary, isTrue);
      c.dispose();
    });

    test('the read is tried again on the next intent change; View track '
        'appears once it lands and the track resolves; then no more reads',
        () async {
      final c = await started(at: 'c');
      local({'c': ('committing', null)});
      await settle();
      review.itemError = Exception('offline');
      local({'c': ('imported', null)});
      await settle();
      expect(c.current!.itemUuid, 'c');
      expect(c.current!.done, isTrue);
      expect(c.lastImported!.displayName, 'c.flac');
      expect(c.currentTrack, isNull);

      // Still failing: tried again, nothing thrown, nothing lost.
      review.calls.clear();
      local({'c': ('imported', null), 'b': ('review_ready', null)});
      await settle();
      expect(review.calls, contains('item c'));
      expect(c.lastImported!.displayName, 'c.flac');

      review.itemError = null;
      review.server['c'] = _item('c', state: 'imported', result: 't-3');
      review.calls.clear();
      local({'c': ('imported', null), 'b': ('committing', null)});
      await settle();
      expect(review.calls, contains('item c'));

      tracks['t-3']!.add(_track('t-3'));
      await settle();
      expect(c.currentTrack!.uuidId, 't-3');
      expect(c.lastImported!.track!.uuidId, 't-3');

      review.calls.clear();
      local({'c': ('imported', null), 'b': ('review_ready', null)});
      await settle();
      expect(review.calls, isNot(contains('item c')));
      c.dispose();
    });
  });

  // Review r1 of 7-fix-r3-fe (rev-1 #2, #3) on the U32-FE-UPL-REVIEW-B-01 fix.
  group('U32-FE-UPL-REVIEW-B-01 review r1', () {
    Future<UploadReviewControls> importedWithFailedRead() async {
      final c = await started(at: 'c');
      local({'c': ('committing', null)});
      await settle();
      review.itemError = Exception('offline');
      local({'c': ('imported', null)});
      await settle();
      review.itemError = null;
      return c;
    }

    test('#2 a retry read still under way is not started again', () async {
      final c = await importedWithFailedRead();
      review.holdEachRead = true;
      review.calls.clear();
      for (var i = 0; i < 3; i++) {
        local({'c': ('imported', null), 'b': ('review_ready', null)});
        await settle();
      }
      expect(review.calls.where((x) => x == 'item c'), hasLength(1));

      final (uuid, read) = review.heldReads.single;
      expect(uuid, 'c');
      read.complete(_item('c', index: 2, state: 'imported', result: 't-3'));
      await settle();
      tracks['t-3']!.add(_track('t-3'));
      await settle();
      expect(c.lastImported!.track!.uuidId, 't-3');
      c.dispose();
    });

    test('#3 a Refresh after the failed read fills View track; no more '
        'retry reads', () async {
      final c = await importedWithFailedRead();
      review.snap = [
        _item('a', index: 0),
        _item('b', index: 1),
        _item('c', index: 2, state: 'imported', result: 't-3'),
      ];
      await c.refresh();
      await settle();
      tracks['t-3']!.add(_track('t-3'));
      await settle();
      expect(c.currentTrack!.uuidId, 't-3');
      expect(c.lastImported!.track!.uuidId, 't-3');

      review.calls.clear();
      local({'c': ('imported', null), 'b': ('review_ready', null)});
      await settle();
      expect(review.calls, isNot(contains('item c')));
      c.dispose();
    });

    // DR-332-FE-B-07: every intent write (each draft save on the next item)
    // re-asked a read the server refuses for good (a pruned item answers
    // 404). A definitive refusal ends the retries; anything else is retried.
    Future<UploadReviewControls> importedWithRefusedRead(Object error) async {
      final c = await started(at: 'c');
      local({'c': ('committing', null)});
      await settle();
      review.itemError = error;
      local({'c': ('imported', null)});
      await settle();
      expect(c.lastImported!.displayName, 'c.flac');
      review.calls.clear();
      return c;
    }

    test('B-07 a read refused for good is not asked again on later changes',
        () async {
      final c = await importedWithRefusedRead(ApiException(
          404, '{"detail": {"error": "upload_item_not_found"}}'));
      for (var i = 0; i < 2; i++) {
        local({'c': ('imported', null), 'b': ('review_ready', null)});
        await settle();
        local({'c': ('imported', null), 'b': ('committing', null)});
        await settle();
      }
      expect(review.calls, isNot(contains('item c')));
      c.dispose();
    });

    for (final (name, error) in [
      ('429', ApiException(429, '{"detail": {"error": "rate_limited"}}')),
      (
        'retryable 409',
        ApiException(409, '{"detail": {"error": "busy", "retryable": true}}'),
      ),
    ]) {
      test('B-07 a refusal that may change ($name) is still asked again',
          () async {
        final c = await importedWithRefusedRead(error);
        local({'c': ('imported', null), 'b': ('review_ready', null)});
        await settle();
        expect(review.calls, contains('item c'));
        c.dispose();
      });
    }
  });

  group('View track', () {
    test('offered only once the imported track resolves after the sync',
        () async {
      final c = await started(at: 'c');
      local({'c': ('committing', null)});
      await settle();
      review.server['c'] = _item('c', state: 'imported', result: 't-3');
      local({'c': ('imported', null)});
      await settle();
      expect(c.currentTrack, isNull);
      expect(c.lastImported!.track, isNull);

      tracks['t-3']!.add(_track('t-3'));
      await settle();

      expect(c.currentTrack!.uuidId, 't-3');
      expect(c.lastImported!.track!.uuidId, 't-3');
      c.dispose();
    });

    test('a ready item has no track to view', () async {
      final c = await started();
      expect(c.currentTrack, isNull);
      expect(c.lastImported, isNull);
      c.dispose();
    });
  });

  group('review r1', () {
    // 7-R1-20 changed how: the move no longer waits for the re-read, so the
    // screen, the draft and the submit are on the new item at once and stay
    // together while the re-read is out.
    test('#4 while Next re-reads the next item, the screen, the draft and '
        'the submit stay on the item shown', () async {
      final c = await started();
      review.itemGate = Completer<void>();
      final moving = c.next();
      await settle();

      expect(c.current!.itemUuid, 'b');
      final typed = const MetadataEdit.empty().set('title', 'for b');
      c.editChanged(typed);
      expect(review.saved.last, ('b', typed));
      await confirmShown(c, writeTags: false);
      expect(review.confirmed.single.$1, 'b');

      review.itemGate!.complete();
      await moving;
      expect(c.current!.itemUuid, 'b');
      expect(c.edit, typed);
      c.dispose();
    });

    // 7-R1-20: navigation never waits on a gated network read.
    test('7-R1-20 a held re-read never blocks Next or Previous', () async {
      final c = await started();
      review.itemGate = Completer<void>();
      var moved = false;
      unawaited(c.next().then((_) => moved = true));
      await settle();
      expect(moved, isTrue);
      expect(c.current!.itemUuid, 'b');
      expect(c.positionText, '2/3');

      var back = false;
      unawaited(c.previous().then((_) => back = true));
      await settle();
      expect(back, isTrue);
      expect(c.current!.itemUuid, 'a');
      review.itemGate!.complete();
      await settle();
      expect(c.current!.itemUuid, 'a');
      c.dispose();
    });

    test('7-R1-20 the re-read lands later and updates the item it read',
        () async {
      final c = await started();
      review.itemGate = Completer<void>();
      review.server['b'] = _item('b', index: 1, version: 5);
      unawaited(c.next());
      await settle();
      expect(c.current!.itemUuid, 'b');
      expect(c.current!.reviewVersion, 1);

      review.itemGate!.complete();
      await settle();
      expect(c.current!.itemUuid, 'b');
      expect(c.current!.reviewVersion, 5);
      c.dispose();
    });

    test('7-R1-20 a re-read that lands after the user moved on does not move '
        'the review back', () async {
      final c = await started();
      review.itemGate = Completer<void>();
      review.server['b'] = _item('b', index: 1, version: 5);
      unawaited(c.next());
      await settle();
      unawaited(c.next());
      await settle();
      expect(c.current!.itemUuid, 'c');

      review.itemGate!.complete();
      await settle();
      expect(c.current!.itemUuid, 'c');
      expect(c.positionText, '3/3');
      c.dispose();
    });

    test('7-R1-20 leaving the page while a re-read is held is quiet',
        () async {
      final c = await started();
      review.itemGate = Completer<void>();
      unawaited(c.next());
      await settle();
      c.dispose();
      review.itemGate!.complete();
      await settle();
    });

    // 7-R1-01: the confirm sheet acts on the item and review version it was
    // opened for.
    test('7-R1-01 a confirm for an item the review has moved away from '
        'sends nothing', () async {
      final c = await started();
      final target = (c.current!.itemUuid, c.current!.reviewVersion);
      c.editChanged(const MetadataEdit.empty().set('title', 'for a'));
      await c.next();
      expect(c.current!.itemUuid, 'b');

      await c.confirm(
          itemUuid: target.$1, reviewVersion: target.$2, writeTags: true);
      await settle();
      expect(review.confirmed, isEmpty);
      c.dispose();
    });

    test('7-R1-01 a confirm for an older review version of the item sends '
        'nothing; the current version still can', () async {
      final c = await started();
      final opened = c.current!.reviewVersion;
      review.server['a'] = _item('a', version: 2);
      local({'a': ('validating', null), 'b': ('review_ready', null),
        'c': ('review_ready', null)});
      await settle();
      local({'a': ('review_ready', null), 'b': ('review_ready', null),
        'c': ('review_ready', null)});
      await settle();
      expect(c.current!.itemUuid, 'a');
      expect(c.current!.reviewVersion, 2);

      await c.confirm(itemUuid: 'a', reviewVersion: opened, writeTags: true);
      await settle();
      expect(review.confirmed, isEmpty);

      await c.confirm(itemUuid: 'a', reviewVersion: 2, writeTags: false);
      await settle();
      expect(review.confirmed.single.$1, 'a');
      expect(review.confirmed.single.$2, 2);
      expect(review.confirmed.single.$4, isFalse);
      c.dispose();
    });

    test('7-R1-01 a confirm after the item was imported and the review '
        'advanced never imports the next item', () async {
      final c = await started();
      review.server['a'] = _item('a', state: 'imported', result: 't-1');
      local({'a': ('committing', null), 'b': ('review_ready', null),
        'c': ('review_ready', null)});
      await settle();
      local({'a': ('imported', null), 'b': ('review_ready', null),
        'c': ('review_ready', null)});
      await settle();
      expect(c.current!.itemUuid, 'b');

      await c.confirm(itemUuid: 'a', reviewVersion: 1, writeTags: false);
      await settle();
      expect(review.confirmed, isEmpty);
      c.dispose();
    });

    // 7-R1-29 (M5): a move whose draft load lands after a newer move is
    // dropped; the newer move's item stays.
    test('7-R1-29 at b, Next to c held, then Previous to a: the review '
        'stays at a when c finally loads', () async {
      final c = await started(at: 'b');
      review.draftGates['c'] = Completer<void>();
      unawaited(c.next());
      await settle();
      expect(c.current!.itemUuid, 'b');

      await c.previous();
      expect(c.current!.itemUuid, 'a');

      review.draftGates['c']!.complete();
      await settle();
      expect(c.current!.itemUuid, 'a');
      expect(c.positionText, '1/3');
      c.dispose();
    });

    // Review (7-fix-r1-fe) R-3: background re-reads of one item can land
    // out of order; the newest read wins.
    test('R-3 an older re-read of an item landing last does not undo a newer '
        'one', () async {
      final c = await started();
      review.holdEachRead = true;
      await c.next(); // read #1 of b
      await c.previous(); // read of a
      await c.next(); // read #2 of b
      final reads = [
        for (final (uuid, done) in review.heldReads)
          if (uuid == 'b') done,
      ];
      expect(reads, hasLength(2));
      reads[1].complete(_item('b', index: 1, version: 2));
      await settle();
      reads[0].complete(_item('b', index: 1, version: 1));
      await settle();
      expect(c.current!.itemUuid, 'b');
      expect(c.current!.reviewVersion, 2);
      for (final (uuid, done) in review.heldReads) {
        if (uuid == 'a') done.complete(_item('a'));
      }
      await settle();
      c.dispose();
    });

    // 7-R2-04: a snapshot load (Refresh) replaces the items too: it goes
    // through the same order as the per-item re-reads, so the newest read
    // of an item wins whichever kind it is.
    test('7-R2-04 a Refresh started before a newer re-read and landing '
        'after it does not undo it', () async {
      final c = await started();
      review.snapshotGate = Completer<void>();
      final refreshing = c.refresh(); // reads b at v1
      review.server['b'] = _item('b', index: 1, version: 2);
      await c.next(); // re-read of b: v2
      await settle();
      expect(c.current!.reviewVersion, 2);

      review.snapshotGate!.complete();
      await refreshing;
      await settle();
      expect(c.current!.itemUuid, 'b');
      expect(c.current!.reviewVersion, 2);
      c.dispose();
    });

    test('7-R2-04 an older re-read landing after a newer Refresh does not '
        'undo it', () async {
      final c = await started();
      review.holdEachRead = true;
      await c.next(); // re-read of b held (it will answer v1)
      review.snap = [..._abc().take(1), _item('b', index: 1, version: 2),
        ..._abc().skip(2)];
      await c.refresh(); // newer: b at v2
      await settle();
      expect(c.current!.reviewVersion, 2);

      review.heldReads.single.$2.complete(_item('b', index: 1, version: 1));
      await settle();
      expect(c.current!.itemUuid, 'b');
      expect(c.current!.reviewVersion, 2);
      c.dispose();
    });

    // Review of 7-fix-r2-fe, F1: which items the review holds comes from a
    // snapshot too: an older Refresh landing after a newer one changes
    // nothing.
    test('7-R2-04 an older Refresh landing after a newer one does not undo '
        'its list', () async {
      final c = await started();
      final first = Completer<void>();
      review.snapshotGate = first;
      final older = c.refresh(); // sees a, b, c
      review.snapshotGate = null;
      review.snap = [..._abc(), _item('d', index: 3)];
      await c.refresh(); // newer: a, b, c, d
      await settle();
      expect(c.total, 4);

      first.complete();
      await older;
      await settle();
      expect(c.total, 4);
      c.dispose();
    });

    test('#4 a second tap while moving: the latest move wins', () async {
      final c = await started();
      review.itemGate = Completer<void>();
      final first = c.next();
      await settle();
      final second = c.next();
      await settle();
      review.itemGate!.complete();
      await Future.wait([first, second]);
      expect(c.current!.itemUuid, isIn(['b', 'c']));
      expect(c.positionText, c.current!.itemUuid == 'b' ? '2/3' : '3/3');
      c.dispose();
    });

    // TR-UPLOAD-06: the sync is no longer the controller's (no gate here);
    // the advance and a later move still hold.
    test('#5 moving after the import advance: the review stays where the '
        'user went', () async {
      final c = await started();
      local({'a': ('committing', null)});
      await settle();
      review.server['a'] = _item('a', state: 'imported', result: 't-1');
      local({'a': ('imported', null)});
      await settle();
      // The advance must not wait for the sync.
      expect(c.current!.itemUuid, 'b');
      await c.next();
      expect(c.current!.itemUuid, 'c');
      await settle();
      expect(c.current!.itemUuid, 'c');
      c.dispose();
    });

    test('#6 a draft that cannot be saved is not an uncaught error',
        () async {
      review.saveError = Exception('fenced');
      final c = await started();
      c.editChanged(const MetadataEdit.empty().set('title', 'x'));
      await settle();
      expect(c.edit, const MetadataEdit.empty().set('title', 'x'));
      c.dispose();
    });

    test('#7 a draft that cannot be read still moves, with no edits',
        () async {
      final c = await started();
      review.draftError = Exception('reset');
      await c.next();
      expect(c.current!.itemUuid, 'b');
      expect(c.edit, const MetadataEdit.empty());
      c.dispose();
    });

    test('#9 a Refresh that changes the current item stops the preview',
        () async {
      final c = await started(at: 'b');
      preview.calls.clear();
      review.snap = [_item('a', index: 0), _item('c', index: 2)];
      await c.refresh();
      expect(c.current!.itemUuid, isNot('b'));
      expect(preview.calls, contains('close'));
      c.dispose();
    });
  });

  // 7B.2d S7: the duplicate inputs (SC-26: the controller forwards to the
  // model; the rules and words come from the model). Spec §7 Duplicate UX:
  // batch summary over the snapshot; Import as separate / Import both
  // unlock Confirm and Skip; Use existing / Don't import resolve to the
  // model's target; `duplicate_conflict`: Use existing or Back to review
  // (retry, which refreshes the report). A refusal or failure keeps the
  // item where it was, with plain words.
  group('duplicates', () {
    final exact = duplicateCheckJson(matches: [libraryMatchJson('t-1')]);
    final fingerprint = duplicateCheckJson(matches: [
      libraryMatchJson('fp-low', kind: 'fingerprint', score: 0.6),
      libraryMatchJson('fp-best', kind: 'fingerprint', band: 'strong',
          score: 0.9),
    ]);

    test('the batch summary is computed over the snapshot', () async {
      review.snap = [
        reviewItem('a', index: 0, check: exact),
        reviewItem('b', index: 1, check: duplicateCheckJson()),
        reviewItem('c', index: 2),
      ];
      final c = await started();
      expect(c.duplicateSummary?.line,
          '1 of 3 files may already be in your library · '
          '1 file not checked for duplicates yet');
      c.dispose();
    });

    test('an exact match: Confirm is off until Import as separate track; '
        'then Confirm sends', () async {
      review.snap = [reviewItem('a', check: exact)];
      final c = await started(local: [_intent('a', 'review_ready')]);
      expect(c.current!.canConfirm, isFalse);
      await confirmShown(c, writeTags: false);
      expect(review.confirmed, isEmpty);

      c.chooseDuplicates(DuplicateGroup.library);
      expect(review.calls, contains('choose a v1 library'));
      expect(c.current!.canConfirm, isTrue);
      expect(c.current!.duplicates.needsChoice, isFalse);
      await confirmShown(c, writeTags: false);
      expect(review.confirmed.single.$1, 'a');
      c.dispose();
    });

    test('a choice is not taken while the item is not reviewable', () async {
      review.snap = [reviewItem('a', check: exact)];
      final c = await started(local: [_intent('a', 'review_submitted')]);
      c.chooseDuplicates(DuplicateGroup.library);
      expect(review.calls.where((x) => x.startsWith('choose')), isEmpty);
      c.dispose();
    });

    test('Use existing resolves to the exact match', () async {
      review.snap = [reviewItem('a', version: 2, check: exact)];
      final c = await started(local: [_intent('a', 'review_ready')]);
      await c.useExisting();
      expect(review.calls, contains('resolve a v2 t-1'));
      c.dispose();
    });

    test("Don't import resolves to the best fingerprint match", () async {
      review.snap = [reviewItem('a', check: fingerprint)];
      final c = await started(local: [_intent('a', 'review_ready')]);
      expect(c.current!.canConfirm, isTrue);
      await c.dontImport();
      expect(review.calls, contains('resolve a v1 fp-best'));
      c.dispose();
    });

    test('nothing to resolve to, or offline: nothing is sent', () async {
      review.snap = [reviewItem('a', check: duplicateCheckJson())];
      final c = await started(local: [_intent('a', 'review_ready')]);
      await c.useExisting();
      await c.dontImport();
      review.snap = [reviewItem('a', check: exact)];
      await c.refresh();
      container.read(overview.notifier).state = fakeUploadsOverview(const [],
          availability: UploadsAvailability.offline);
      await settle();
      await c.useExisting();
      expect(review.calls.where((x) => x.startsWith('resolve')), isEmpty);
      c.dispose();
    });

    test('one resolve at a time', () async {
      review.snap = [reviewItem('a', check: exact)];
      final c = await started(local: [_intent('a', 'review_ready')]);
      review.submitGate = Completer<void>();
      final first = c.useExisting();
      await settle();
      expect(c.busy, isTrue);
      await c.useExisting();
      review.submitGate!.complete();
      await first;
      expect(review.calls.where((x) => x.startsWith('resolve')), hasLength(1));
      expect(c.busy, isFalse);
      c.dispose();
    });

    test('a failed resolve keeps the item, with plain words', () async {
      review.snap = [reviewItem('a', check: exact)];
      final c = await started(local: [_intent('a', 'review_ready')]);
      review.submitError = Exception('down');
      await c.useExisting();
      expect(c.notice, 'Something went wrong. Try again.');
      expect(c.current!.itemUuid, 'a');
      c.dispose();
    });

    test('a resolved item (duplicate) advances like an import', () async {
      review.snap = [
        reviewItem('a', index: 0, check: exact),
        reviewItem('b', index: 1),
      ];
      final c = await started(local: [_intent('a', 'review_ready'),
        _intent('b', 'review_ready')]);
      local({'a': ('review_submitted', null), 'b': ('review_ready', null)});
      await settle();
      review.server['a'] =
          reviewItem('a', state: 'duplicate', check: exact);
      local({'a': ('duplicate', null), 'b': ('review_ready', null)});
      await settle();
      expect(c.current!.itemUuid, 'b');
      c.dispose();
    });

    group('duplicate_conflict', () {
      UploadItem conflicted() => reviewItem('a',
          state: 'duplicate_conflict',
          version: 3,
          check: duplicateCheckJson(),
          conflicts: [libraryMatchJson('t-new')]);

      test('Use existing resolves to the new match at the item version',
          () async {
        review.snap = [conflicted()];
        final c = await started(local: [_intent('a', 'duplicate_conflict')]);
        expect(c.current!.conflict, isNotNull);
        await c.useExisting();
        expect(review.calls, contains('resolve a v3 t-new'));
        c.dispose();
      });

      test('Back to review retries and reads the item again', () async {
        review.snap = [conflicted()];
        final c = await started(local: [_intent('a', 'duplicate_conflict')]);
        review.calls.clear();
        review.server['a'] =
            reviewItem('a', state: 'validating', version: 4);
        await c.backToReview();
        expect(review.calls, ['backToReview a', 'item a']);
        expect(c.current!.reviewVersion, 4);
        expect(c.notice, isNull);
        c.dispose();
      });

      test('Back to review refused or failed: plain words, item kept',
          () async {
        review.snap = [conflicted()];
        final c = await started(local: [_intent('a', 'duplicate_conflict')]);
        review.retryOutcome = RetryOutcome.notRetryable;
        await c.backToReview();
        expect(c.notice, "This file can't be retried.");
        review.retryOutcome = RetryOutcome.changed;
        await c.backToReview();
        expect(c.notice,
            'This file changed on the server. Check its status and try '
            'again.');
        review.retryError = Exception('down');
        await c.backToReview();
        expect(c.notice, 'Something went wrong. Try again.');
        expect(c.current!.itemUuid, 'a');
        c.dispose();
      });

      test('offline: Back to review sends nothing', () async {
        review.snap = [conflicted()];
        final c = await started(local: [_intent('a', 'duplicate_conflict')]);
        container.read(overview.notifier).state = fakeUploadsOverview(
            const [], availability: UploadsAvailability.offline);
        await settle();
        await c.backToReview();
        expect(review.calls.where((x) => x.startsWith('backToReview')),
            isEmpty);
        c.dispose();
      });
    });
  });
}

List<UploadItem> _abc() =>
    [_item('a', index: 0), _item('b', index: 1), _item('c', index: 2)];
