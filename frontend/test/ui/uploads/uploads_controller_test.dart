// Phase 7 §7 para 3 / SC-26: the Uploads page controller forwards each
// input to the model (upload manager, picker, ZIP children projection,
// visibility seam) and holds only presentation state. Leaving the page
// (dispose) stops polling but never cancels or quiesces a transfer.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_source.dart';
import 'package:frontend/services/uploads/upload_source_picker.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/services/uploads/uploads_visibility.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';

class _FakeManager implements UploadManager {
  final calls = <String>[];
  final added = <List<String>>[];
  AddFilesResult addResult = const AddFilesResult(
    batchUuids: ['b'],
    leftOut: [],
  );
  Object? addError;
  Object? cancelError;
  Object? reselectError;
  ReselectOutcome reselectOutcome = ReselectOutcome.accepted;
  Completer<void>? addGate;

  @override
  Future<AddFilesResult> addFiles(List<FileUploadSource> sources) async {
    calls.add('addFiles');
    added.add([for (final s in sources) s.displayName]);
    await addGate?.future;
    if (addError != null) throw addError!;
    return addResult;
  }

  @override
  Future<void> cancel(String itemUuid) async {
    calls.add('cancel $itemUuid');
    if (cancelError != null) throw cancelError!;
  }

  @override
  Future<ReselectOutcome> reselect(
    String itemUuid,
    FileUploadSource source,
  ) async {
    calls.add('reselect $itemUuid ${source.displayName}');
    if (reselectError != null) throw reselectError!;
    return reselectOutcome;
  }

  @override
  Future<void> quiesce() async => calls.add('quiesce');

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('unexpected ${invocation.memberName}');
    return super.noSuchMethod(invocation);
  }
}

class _FakePicker implements UploadSourcePicker {
  final queue = <UploadSelection>[];
  int picks = 0;
  Object? error;
  Completer<void>? gate;
  @override
  Future<UploadSelection> pick() async {
    picks++;
    await gate?.future;
    if (error != null) throw error!;
    return queue.isEmpty
        ? const UploadSelection(sources: [], unavailable: [])
        : queue.removeAt(0);
  }
}

class _FakeChildren implements UploadZipChildren {
  final requests = <String>[];
  Completer<ZipChildren> answer = Completer();
  @override
  Future<ZipChildren> load(String batchUuid, String parentItemUuid) {
    requests.add('$batchUuid/$parentItemUuid');
    return answer.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _emptyOverview = UploadsOverview(
  availability: UploadsAvailability.available,
  rows: [],
  counts: UploadCounts(
    total: 0,
    inProgress: 0,
    readyForReview: 0,
    needsAttention: 0,
    done: 0,
    cancelled: 0,
    expired: 0,
  ),
  limitsText: null,
);

const _offlineOverview = UploadsOverview(
  availability: UploadsAvailability.offline,
  rows: [],
  counts: UploadCounts(
    total: 0,
    inProgress: 0,
    readyForReview: 0,
    needsAttention: 0,
    done: 0,
    cancelled: 0,
    expired: 0,
  ),
  limitsText: null,
);

const _zip = ZipChildren(
  children: [],
  valid: 2,
  failed: 1,
  checking: 0,
  cancelled: 0,
  skipped: null,
);

void main() {
  late _FakeManager manager;
  late _FakePicker picker;
  late _FakeChildren children;
  late NotifierUploadsVisibility visibility;
  late StateProvider<UploadsOverview?> overviewState;
  late ProviderContainer container;
  late Directory dir;

  setUp(() {
    manager = _FakeManager();
    picker = _FakePicker();
    children = _FakeChildren();
    visibility = NotifierUploadsVisibility();
    overviewState = StateProvider<UploadsOverview?>((ref) => _emptyOverview);
    container = ProviderContainer(
      overrides: [
        uploadManagerProvider.overrideWithValue(manager),
        uploadSourcePickerProvider.overrideWithValue(picker),
        uploadZipChildrenProvider.overrideWithValue(children),
        uploadsVisibilityProvider.overrideWithValue(visibility),
        uploadsOverviewProvider.overrideWith(
          (ref) => ref.watch(overviewState),
        ),
      ],
    );
    dir = Directory.systemTemp.createTempSync('uploads_controller_test');
  });
  tearDown(() {
    container.dispose();
    visibility.dispose();
    dir.deleteSync(recursive: true);
  });

  UploadsControls create() =>
      container.read(uploadsControllerFactoryProvider)();

  Future<FileUploadSource> file(String name, {int bytes = 4}) async {
    final f = File('${dir.path}/$name')..writeAsBytesSync(List.filled(bytes, 1));
    return FileUploadSource.open(f.path);
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('state and visibility', () {
    test('forwards the model overview, live', () async {
      final c = create();
      var notified = 0;
      c.addListener(() => notified++);
      expect(c.overview, same(_emptyOverview));
      container.read(overviewState.notifier).state = _offlineOverview;
      await settle();
      expect(c.overview, same(_offlineOverview));
      expect(notified, greaterThan(0));
      c.dispose();
    });

    test('page visibility drives the polling seam; leaving clears it', () {
      final c = create();
      expect(visibility.visible.value, isFalse);
      c.setPageVisible(true);
      expect(visibility.visible.value, isTrue);
      c.setPageVisible(false);
      expect(visibility.visible.value, isFalse);
      c.setPageVisible(true);
      c.dispose();
      expect(visibility.visible.value, isFalse);
    });

    test('leaving the page cancels nothing and quiesces nothing', () {
      final c = create();
      c.setPageVisible(true);
      c.dispose();
      expect(manager.calls, isEmpty);
    });

    test('a disposed controller no longer follows the model', () async {
      final c = create();
      c.dispose();
      container.read(overviewState.notifier).state = _offlineOverview;
      await settle();
      expect(c.overview, same(_emptyOverview));
    });
  });

  group('row actions', () {
    test('cancel forwards to the manager', () async {
      final c = create();
      await c.cancel('i-1');
      expect(manager.calls, ['cancel i-1']);
      c.dispose();
    });

    test('Review tags opens the review flow and sends nothing (7B.2c)', () {
      final c = create();
      expect(c.reviewTags('i-1'), ReviewTagsOutcome.open);
      expect(manager.calls, isEmpty);
      c.dispose();
    });

    test('reselect picks a file and offers it for the item', () async {
      final c = create();
      picker.queue.add(
        UploadSelection(sources: [await file('again.flac')], unavailable: []),
      );
      await c.reselect('i-1');
      expect(manager.calls, ['reselect i-1 again.flac']);
      expect(c.notice, isNull);
      c.dispose();
    });

    test('a different file on reselect is explained', () async {
      final c = create();
      manager.reselectOutcome = ReselectOutcome.differentFile;
      picker.queue.add(
        UploadSelection(sources: [await file('other.flac')], unavailable: []),
      );
      await c.reselect('i-1');
      expect(
        c.notice?.title,
        "That's a different file. Pick the same file that was added.",
      );
      c.dismissNotice();
      expect(c.notice, isNull);
      c.dispose();
    });

    test('a cancelled reselect pick does nothing', () async {
      final c = create();
      await c.reselect('i-1');
      expect(picker.picks, 1);
      expect(manager.calls, isEmpty);
      expect(c.notice, isNull);
      c.dispose();
    });

    test('a reselect pick that cannot be opened is explained', () async {
      final c = create();
      picker.queue.add(
        const UploadSelection(sources: [], unavailable: ['gone.flac']),
      );
      await c.reselect('i-1');
      expect(manager.calls, isEmpty);
      expect(c.notice?.title, "That file couldn't be read.");
      c.dispose();
    });
  });

  group('Add files', () {
    test('picked files go to the manager in pick order', () async {
      final c = create();
      picker.queue.add(
        UploadSelection(
          sources: [await file('b.flac'), await file('a.mp3')],
          unavailable: [],
        ),
      );
      await c.addFiles();
      expect(manager.added, [
        ['b.flac', 'a.mp3'],
      ]);
      expect(c.notice, isNull);
      c.dispose();
    });

    test('busy while picking and hashing, then not', () async {
      final c = create();
      picker.queue.add(
        UploadSelection(sources: [await file('a.flac')], unavailable: []),
      );
      manager.addGate = Completer();
      final done = c.addFiles();
      await settle();
      expect(c.adding, isTrue);
      manager.addGate!.complete();
      await done;
      expect(c.adding, isFalse);
      c.dispose();
    });

    test('a second tap while adding does not pick again', () async {
      final c = create();
      picker.queue.add(
        UploadSelection(sources: [await file('a.flac')], unavailable: []),
      );
      manager.addGate = Completer();
      final first = c.addFiles();
      await settle();
      await c.addFiles();
      manager.addGate!.complete();
      await first;
      expect(picker.picks, 1);
      c.dispose();
    });

    test('a cancelled pick sends nothing', () async {
      final c = create();
      await c.addFiles();
      expect(manager.calls, isEmpty);
      expect(c.notice, isNull);
      c.dispose();
    });

    test('left-out files are named with the reason (zero-byte rule)',
        () async {
      final c = create();
      picker.queue.add(
        UploadSelection(
          sources: [await file('empty.flac', bytes: 0), await file('ok.flac')],
          unavailable: ['locked.flac'],
        ),
      );
      manager.addResult = const AddFilesResult(
        batchUuids: ['b'],
        leftOut: [LeftOutFile('empty.flac', LeftOutReason.empty)],
      );
      await c.addFiles();
      expect(c.notice?.title, '2 files were left out');
      expect(c.notice?.lines, [
        'locked.flac: The file couldn\'t be read.',
        'empty.flac: The file is empty.',
      ]);
      c.dispose();
    });

    test('one left-out file, singular', () async {
      final c = create();
      picker.queue.add(
        UploadSelection(sources: [await file('big.flac')], unavailable: []),
      );
      manager.addResult = const AddFilesResult(
        batchUuids: [],
        leftOut: [LeftOutFile('big.flac', LeftOutReason.tooLarge)],
      );
      await c.addFiles();
      expect(c.notice?.title, '1 file was left out');
      expect(c.notice?.lines, [
        'big.flac: The file is larger than the server accepts.',
      ]);
      c.dispose();
    });

    test('only unopenable files: the manager is not called', () async {
      final c = create();
      picker.queue.add(
        const UploadSelection(sources: [], unavailable: ['x.flac']),
      );
      await c.addFiles();
      expect(manager.calls, isEmpty);
      expect(c.notice?.title, '1 file was left out');
      c.dispose();
    });

    test('uploads not available: explained, nothing thrown', () async {
      final c = create();
      picker.queue.add(
        UploadSelection(sources: [await file('a.flac')], unavailable: []),
      );
      manager.addError = const UploadsUnavailable();
      await c.addFiles();
      expect(c.notice?.title, "Uploads aren't available right now");
      expect(c.adding, isFalse);
      c.dispose();
    });

    test('when the model says Add files is off, nothing is picked', () async {
      container.read(overviewState.notifier).state = _offlineOverview;
      final c = create();
      await c.addFiles();
      expect(picker.picks, 0);
      c.dispose();
    });
  });

  group('ZIP children', () {
    test('loading, then loaded', () async {
      final c = create();
      expect(c.childrenOf('zip'), isNull);
      final done = c.loadChildren('b-1', 'zip');
      expect(c.childrenOf('zip'), isA<ChildListLoading>());
      children.answer.complete(_zip);
      await done;
      final state = c.childrenOf('zip');
      expect(state, isA<ChildListLoaded>());
      expect((state! as ChildListLoaded).children, same(_zip));
      expect(children.requests, ['b-1/zip']);
      c.dispose();
    });

    test('a failure shows as failed; loading again retries', () async {
      final c = create();
      final done = c.loadChildren('b-1', 'zip');
      children.answer.completeError(Exception('network'));
      await done;
      expect(c.childrenOf('zip'), isA<ChildListFailed>());
      children.answer = Completer()..complete(_zip);
      await c.loadChildren('b-1', 'zip');
      expect(c.childrenOf('zip'), isA<ChildListLoaded>());
      expect(children.requests, hasLength(2));
      c.dispose();
    });

    test('an answer after dispose is dropped', () async {
      final c = create();
      final done = c.loadChildren('b-1', 'zip');
      c.dispose();
      children.answer.complete(_zip);
      await done; // no notify-after-dispose error
    });
  });

  // ---- Review r1 #2, #3 ----------------------------------------------------

  group('review r1', () {
    const failed = "Something went wrong. Try again.";

    test('a late answer of an older child load never replaces a newer one',
        () async {
      final c = create();
      final first = children.answer;
      final a = c.loadChildren('b-1', 'zip');
      children.answer = Completer();
      final b = c.loadChildren('b-1', 'zip');
      children.answer.complete(_zip);
      await b;
      first.completeError(Exception('late'));
      await a;
      expect(c.childrenOf('zip'), isA<ChildListLoaded>());
      c.dispose();
    });

    test('a picker failure on Add files is explained, never thrown', () async {
      final c = create();
      picker.error = StateError('panel');
      await c.addFiles();
      expect(c.notice?.title, failed);
      expect(c.adding, isFalse);
      c.dispose();
    });

    test('an unexpected manager failure on Add files is explained', () async {
      final c = create();
      picker.queue.add(
        UploadSelection(sources: [await file('a.flac')], unavailable: []),
      );
      manager.addError = StateError('db');
      await c.addFiles();
      expect(c.notice?.title, failed);
      expect(c.adding, isFalse);
      c.dispose();
    });

    test('a reselect failure (picker or manager) is explained', () async {
      final c = create();
      picker.error = StateError('panel');
      await c.reselect('i-1');
      expect(c.notice?.title, failed);
      c.dismissNotice();
      picker.error = null;
      picker.queue.add(
        UploadSelection(sources: [await file('a.flac')], unavailable: []),
      );
      manager.reselectError = StateError('db');
      await c.reselect('i-1');
      expect(c.notice?.title, failed);
      c.dispose();
    });

    test('a second reselect while one is picking does not pick again',
        () async {
      final c = create();
      picker.gate = Completer();
      final first = c.reselect('i-1');
      await settle();
      await c.reselect('i-1');
      picker.gate!.complete();
      await first;
      expect(picker.picks, 1);
      c.dispose();
    });

    test('a cancel failure is explained, never thrown', () async {
      final c = create();
      manager.cancelError = StateError('db');
      await c.cancel('i-1');
      expect(c.notice?.title, failed);
      c.dispose();
    });
  });
}
