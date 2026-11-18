// Phase 9 §6 (9C.2): the recap controller's export intents (SC-26). The
// view hands over the PNG bytes it rendered from the controller's one
// recap; the JSON is built from that same recap. The recap service is
// faked; the export service is real over a fake platform and a real
// temporary directory. 9-U06 (export cancellation / overwrite / temporary
// clean-up), unit halves of 9-Y02 and 9-Y03.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/annual_recap_service.dart';
import 'package:frontend/services/recap_export_platform.dart';
import 'package:frontend/services/recap_export_service.dart';
import 'package:frontend/ui/annual_recap_controller.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_recap_export_platform.dart';
import '../helpers/listening_stats_builder.dart' show utc;
import '../helpers/recap_service_fake.dart' show FakeRecapService, token;

/// Waits in real time, at most [limit], until [done] holds: for work started
/// without being awaited that goes through real file I/O, which a fixed
/// number of event-queue turns does not bound. The expect after it reports a
/// condition that never came.
Future<void> _eventually(bool Function() done,
    {Duration limit = const Duration(seconds: 5)}) async {
  final elapsed = Stopwatch()..start();
  while (!done() && elapsed.elapsed < limit) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root;
  late Directory tempRoot;
  late Directory dest;
  late FakeRecapExportPlatform platform;
  late FakeRecapService service;
  late ProviderContainer container;
  late AnnualRecapControls controller;
  late int notifications;
  var disposed = false;

  final now = utc(2026, 3, 15, 12);
  final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 9, 9]);

  List<String> tempFiles() => [
    for (final f in tempRoot.listSync(recursive: true))
      if (f is File) f.path,
  ];

  /// Opens the recap (the snapshot answers with 2025) and lets it load.
  Future<void> openLoaded() async {
    controller = container.read(annualRecapControllerFactoryProvider)();
    controller.addListener(() => notifications++);
    service.answer(token(19, now), year: 2025, years: [2025], seconds: 3600);
    await pumpEventQueue();
    expect(controller.recap, isNotNull);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('recap_export_controller_');
    tempRoot = Directory(p.join(root.path, 'tmp'))..createSync();
    dest = Directory(p.join(root.path, 'chosen'))..createSync();
    platform = FakeRecapExportPlatform(tempRoot);
    service = FakeRecapService();
    notifications = 0;
    disposed = false;
    container = ProviderContainer(
      overrides: [
        annualRecapServiceProvider.overrideWithValue(service),
        recapExportPlatformProvider.overrideWithValue(platform),
      ],
    );
  });

  tearDown(() {
    if (!disposed) controller.dispose();
    container.dispose();
    root.deleteSync(recursive: true);
  });

  test('the platform\'s save and share abilities are shown', () async {
    platform
      ..canSave = false
      ..canShare = true;
    await openLoaded();

    expect(controller.canSave, isFalse);
    expect(controller.canShare, isTrue);
  });

  test('Save image writes the rendered bytes under a name carrying only '
      'the year, busy while the panel is open', () async {
    await openLoaded();
    final target = p.join(dest.path, 'recap.png');
    platform.nextSaveLocation = () => target;
    bool? busyDuringPanel;
    platform.whilePanelOpen = () async {
      busyDuringPanel = controller.exporting;
    };

    final message = await controller.savePng(png);

    expect(message, 'Image saved');
    expect(File(target).readAsBytesSync(), png);
    expect(platform.saveRequests, [
      ('osml-year-in-music-2025.png', RecapExportType.png),
    ]);
    expect(busyDuringPanel, isTrue);
    expect(controller.exporting, isFalse);
    expect(tempFiles(), isEmpty);
  });

  test('Save JSON writes the JSON of the same recap', () async {
    await openLoaded();
    final target = p.join(dest.path, 'recap.json');
    platform.nextSaveLocation = () => target;

    final message = await controller.saveJson();

    expect(message, 'JSON saved');
    expect(
      File(target).readAsStringSync(),
      const RecapExportService().buildJson(controller.recap!),
    );
    expect(
      jsonDecode(File(target).readAsStringSync())['year'],
      2025,
    );
    expect(platform.saveRequests, [
      ('osml-year-in-music-2025.json', RecapExportType.json),
    ]);
  });

  test('a cancelled save says nothing and leaves no file', () async {
    await openLoaded();
    platform.nextSaveLocation = () => null;

    expect(await controller.savePng(png), isNull);

    expect(dest.listSync(), isEmpty);
    expect(tempFiles(), isEmpty);
    expect(controller.exporting, isFalse);
  });

  test('an existing file left in place is reported', () async {
    await openLoaded();
    platform.confirmsReplace = false;
    final target = File(p.join(dest.path, 'recap.png'))
      ..writeAsStringSync('mine');
    platform.nextSaveLocation = () => target.path;

    expect(
      await controller.savePng(png),
      'A file with that name already exists; nothing was saved',
    );
    expect(target.readAsStringSync(), 'mine');
  });

  test('save failures and platform limitations are reported', () async {
    await openLoaded();
    platform.panelError = StateError('broke');
    expect(await controller.savePng(png), 'Could not save the export');

    platform.canSave = false;
    expect(
      await controller.saveJson(),
      'Saving files is not available on this device',
    );
  });

  test('Share image hands the bytes to the share sheet only when called; '
      'its outcome is quiet unless it failed', () async {
    await openLoaded();
    expect(platform.shareRequests, isEmpty);
    const origin = Rect.fromLTWH(5, 6, 7, 8);

    expect(await controller.sharePng(png, origin: origin), isNull);

    final (path, type, at, bytes) = platform.shareRequests.single;
    expect(p.basename(path), 'osml-year-in-music-2025.png');
    expect(type, RecapExportType.png);
    expect(at, origin);
    expect(bytes, png);

    platform.shareStatus = RecapShareStatus.dismissed;
    expect(await controller.sharePng(png), isNull);

    platform.shareError = StateError('broke');
    expect(await controller.sharePng(png), 'Could not share the image');

    platform.canShare = false;
    expect(
      await controller.sharePng(png),
      'Sharing files is not available on this device',
    );
  });

  test('a second export while one is open is ignored', () async {
    await openLoaded();
    final open = Completer<void>();
    final answer = Completer<void>();
    platform.nextSaveLocation = () => null;
    platform.whilePanelOpen = () async {
      open.complete();
      await answer.future;
    };
    final first = controller.savePng(png);
    await open.future;

    expect(await controller.sharePng(png), isNull);
    expect(await controller.saveJson(), isNull);

    answer.complete();
    await first;
    expect(platform.saveRequests, hasLength(1));
    expect(platform.shareRequests, isEmpty);
  });

  test('nothing is exported before a recap is shown', () async {
    controller = container.read(annualRecapControllerFactoryProvider)();

    expect(await controller.savePng(png), isNull);
    expect(await controller.saveJson(), isNull);
    expect(await controller.sharePng(png), isNull);
    expect(platform.saveRequests, isEmpty);
    expect(platform.shareRequests, isEmpty);
  });

  test('leaving the page removes the file kept for a share', () async {
    await openLoaded();
    await controller.sharePng(png);
    expect(tempFiles(), hasLength(1));

    controller.dispose();
    disposed = true;
    // dispose() starts the release without awaiting it, and the delete runs
    // on real file I/O: wait for it in real time, bounded.
    await _eventually(() => tempFiles().isEmpty);

    expect(tempFiles(), isEmpty);
  });

  test('leaving the page while the save panel is open finishes the save '
      'quietly and leaves no temporary file', () async {
    await openLoaded();
    final open = Completer<void>();
    final answer = Completer<void>();
    final target = p.join(dest.path, 'recap.png');
    platform.nextSaveLocation = () => target;
    platform.whilePanelOpen = () async {
      open.complete();
      await answer.future;
    };
    final saving = controller.savePng(png);
    await open.future;

    controller.dispose();
    disposed = true;
    final before = notifications;
    answer.complete();
    await saving;
    await pumpEventQueue();

    expect(File(target).readAsBytesSync(), png);
    expect(notifications, before);
    expect(tempFiles(), isEmpty);
  });
}
