// Phase 9 §6 (9C.2): a recap export goes through an owned temporary file to
// the place the user chose, or to the share sheet. Only the platform (save
// panel, share sheet, temporary directory) is faked; the files are real.
// Cases: exit proof (cancel leaves no file, an existing name is not
// overwritten, the temporary file is removed on every path), 9-U06 export
// cancellation / overwrite / temporary clean-up, 9-Y03 unit half.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/recap_export_files.dart';
import 'package:frontend/services/recap_export_platform.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_recap_export_platform.dart';
import '../helpers/chmod_denial.dart';

void main() {
  late Directory root;
  late Directory tempRoot;
  late Directory dest;
  late FakeRecapExportPlatform platform;
  late List<String> logs;
  late RecapExportFiles files;

  final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);
  const name = 'osml-year-in-music-2025.png';

  setUp(() {
    root = Directory.systemTemp.createTempSync('recap_export_files_');
    tempRoot = Directory(p.join(root.path, 'tmp'))..createSync();
    dest = Directory(p.join(root.path, 'chosen'))..createSync();
    platform = FakeRecapExportPlatform(tempRoot);
    logs = [];
    files = RecapExportFiles(platform: platform, log: logs.add);
  });

  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+rwx', root.path]);
    root.deleteSync(recursive: true);
  });

  /// Every regular file under the temporary directory.
  List<String> tempFiles() => [
    for (final f in tempRoot.listSync(recursive: true))
      if (f is File) f.path,
  ];

  List<String> destNames() => [
    for (final f in dest.listSync()) p.basename(f.path),
  ];

  Future<RecapSaveOutcome> save([Uint8List? bytes]) => files.save(
    bytes ?? png,
    suggestedName: name,
    type: RecapExportType.png,
  );

  group('save', () {
    test('writes the bytes where the user chose, through a temporary '
        'file that is gone afterwards', () async {
      final target = p.join(dest.path, 'my recap.png');
      platform.nextSaveLocation = () => target;

      expect(await save(), RecapSaveOutcome.saved);

      expect(File(target).readAsBytesSync(), png);
      expect(platform.saveRequests, [(name, RecapExportType.png)]);
      // The bytes were in an owned temporary file while the panel was open.
      final during = platform.filesWhileOpen.single;
      expect(during, hasLength(1));
      expect(
        p.isWithin(p.join(tempRoot.path, RecapExportFiles.folderName), during.single),
        isTrue,
      );
      expect(tempFiles(), isEmpty);
    });

    test('a cancelled panel leaves no file anywhere', () async {
      final existing = File(p.join(dest.path, name))..writeAsStringSync('old');
      platform.nextSaveLocation = () => null;

      expect(await save(), RecapSaveOutcome.cancelled);

      expect(destNames(), [name]);
      expect(existing.readAsStringSync(), 'old');
      expect(tempFiles(), isEmpty);
    });

    test('an existing file is not overwritten when the platform did not '
        'confirm replacing it', () async {
      platform.confirmsReplace = false;
      final target = File(p.join(dest.path, name))..writeAsStringSync('mine');
      platform.nextSaveLocation = () => target.path;

      expect(await save(), RecapSaveOutcome.destinationExists);

      expect(target.readAsStringSync(), 'mine');
      expect(destNames(), [name]);
      expect(tempFiles(), isEmpty);
    });

    test('an existing file the save panel confirmed replacing is '
        'replaced', () async {
      final target = File(p.join(dest.path, name))..writeAsStringSync('old');
      platform.nextSaveLocation = () => target.path;

      expect(await save(), RecapSaveOutcome.saved);

      expect(target.readAsBytesSync(), png);
      expect(destNames(), [name]);
      expect(tempFiles(), isEmpty);
    });

    test('a save panel error fails and leaves no file', () async {
      platform.panelError = StateError('panel broke');

      expect(await save(), RecapSaveOutcome.failed);

      expect(destNames(), isEmpty);
      expect(tempFiles(), isEmpty);
    });

    test('a write error at the destination fails and leaves no file', () async {
      final target = p.join(dest.path, 'missing-folder', name);
      platform.nextSaveLocation = () => target;

      expect(await save(), RecapSaveOutcome.failed);

      expect(File(target).existsSync(), isFalse);
      expect(destNames(), isEmpty);
      expect(tempFiles(), isEmpty);
    });

    test('a temporary file that cannot be written fails before the panel '
        'opens', skip: skipUnlessChmodDenies, () async {
      Process.runSync('chmod', ['555', tempRoot.path]);
      platform.nextSaveLocation = () => p.join(dest.path, name);

      expect(await save(), RecapSaveOutcome.failed);

      expect(platform.saveRequests, isEmpty);
      expect(destNames(), isEmpty);
    });

    test('a platform without a save panel writes nothing', () async {
      platform.canSave = false;

      expect(await save(), RecapSaveOutcome.unavailable);

      expect(platform.saveRequests, isEmpty);
      expect(platform.temporaryDirectoryCalls, 0);
      expect(tempRoot.listSync(), isEmpty);
    });

    test('leftovers in the owned folder are removed; nothing outside it '
        'is touched', () async {
      final owned = Directory(p.join(tempRoot.path, RecapExportFiles.folderName));
      final stale = File(p.join(owned.path, 'old-export', 'x.png'))
        ..createSync(recursive: true);
      final foreign = File(p.join(tempRoot.path, 'someone-else.txt'))
        ..writeAsStringSync('keep');
      platform.nextSaveLocation = () => null;

      await save();

      expect(stale.existsSync(), isFalse);
      expect(foreign.readAsStringSync(), 'keep');
    });

    test('a temporary file that cannot be removed is logged without its '
        'path and removed by the next export',
        skip: skipUnlessChmodDenies, () async {
      final owned = p.join(tempRoot.path, RecapExportFiles.folderName);
      platform.nextSaveLocation = () => p.join(dest.path, name);
      platform.whilePanelOpen = () async {
        Process.runSync('chmod', ['555', owned]);
      };

      expect(await save(), RecapSaveOutcome.saved);
      // The export's own folder could not be removed: something is left.
      expect(Directory(owned).listSync(), isNotEmpty);
      expect(logs, isNotEmpty);
      for (final line in logs) {
        expect(line, isNot(contains(root.path)));
      }

      Process.runSync('chmod', ['755', owned]);
      platform.whilePanelOpen = null;
      platform.nextSaveLocation = () => null;
      await save();

      expect(Directory(owned).listSync(), isEmpty);
    });

    // Review r1 F4: under the macOS sandbox (or across volumes) the move
    // from the temporary folder can fail; the bytes are then written in
    // place. Here the move fails because the export's own folder is made
    // read-only while the panel is open.
    for (final existing in [false, true]) {
      test('when the move fails the bytes are written in place '
          '(${existing ? 'confirmed replace' : 'new file'})',
          skip: skipUnlessChmodDenies, () async {
        final target = File(p.join(dest.path, name));
        if (existing) target.writeAsStringSync('old');
        platform.nextSaveLocation = () => target.path;
        String? exportDir;
        platform.whilePanelOpen = () async {
          exportDir = p.dirname(platform.filesWhileOpen.last.single);
          Process.runSync('chmod', ['555', exportDir!]);
        };

        expect(await save(), RecapSaveOutcome.saved);

        expect(target.readAsBytesSync(), png);
        expect(destNames(), [name]);
        Process.runSync('chmod', ['755', exportDir!]);
        platform.whilePanelOpen = null;
        platform.nextSaveLocation = () => null;
        await save();
        expect(tempFiles(), isEmpty);
      });
    }

    test('an owned folder that is a symbolic link is refused, and nothing '
        'it points to is removed (review r1 F2)', () async {
      final elsewhere = Directory(p.join(root.path, 'elsewhere'))..createSync();
      final precious = File(p.join(elsewhere.path, 'precious.txt'))
        ..writeAsStringSync('keep');
      Link(p.join(tempRoot.path, RecapExportFiles.folderName))
          .createSync(elsewhere.path);
      platform.nextSaveLocation = () => p.join(dest.path, name);

      expect(await save(), RecapSaveOutcome.failed);
      expect(
        await files.share(png, suggestedName: name, type: RecapExportType.png),
        RecapShareOutcome.failed,
      );

      expect(precious.readAsStringSync(), 'keep');
      expect(elsewhere.listSync(), hasLength(1));
      expect(platform.saveRequests, isEmpty);
      expect(platform.shareRequests, isEmpty);
      expect(destNames(), isEmpty);
    });

    test('two saves at once each write their own bytes and leave no '
        'temporary file', () async {
      final firstOpen = Completer<void>();
      final releaseFirst = Completer<void>();
      final first = p.join(dest.path, 'first.png');
      final second = p.join(dest.path, 'second.png');
      platform.nextSaveLocation = () => first;
      platform.whilePanelOpen = () async {
        firstOpen.complete();
        await releaseFirst.future;
      };
      final firstSave = save(Uint8List.fromList([1, 1, 1]));
      await firstOpen.future;

      platform.whilePanelOpen = null;
      platform.nextSaveLocation = () => second;
      expect(await save(Uint8List.fromList([2, 2])), RecapSaveOutcome.saved);
      platform.nextSaveLocation = () => first;
      releaseFirst.complete();
      expect(await firstSave, RecapSaveOutcome.saved);

      expect(File(first).readAsBytesSync(), [1, 1, 1]);
      expect(File(second).readAsBytesSync(), [2, 2]);
      expect(tempFiles(), isEmpty);
    });
  });

  group('share', () {
    Future<RecapShareOutcome> share([Uint8List? bytes]) => files.share(
      bytes ?? png,
      suggestedName: name,
      type: RecapExportType.png,
      origin: const Rect.fromLTWH(10, 20, 30, 40),
    );

    test('hands the share sheet a temporary file with the bytes and the '
        'suggested name; it is kept until released', () async {
      expect(await share(), RecapShareOutcome.shared);

      final (path, type, origin, bytes) = platform.shareRequests.single;
      expect(p.basename(path), name);
      expect(
        p.isWithin(p.join(tempRoot.path, RecapExportFiles.folderName), path),
        isTrue,
      );
      expect(type, RecapExportType.png);
      expect(origin, const Rect.fromLTWH(10, 20, 30, 40));
      expect(bytes, png);
      // A chosen share target may still be reading the file.
      expect(File(path).existsSync(), isTrue);

      await files.release();

      expect(tempFiles(), isEmpty);
    });

    test('a dismissed sheet keeps the file until the next export, which '
        'removes it', () async {
      platform.shareStatus = RecapShareStatus.dismissed;
      expect(await share(), RecapShareOutcome.dismissed);
      final first = platform.shareRequests.single.$1;
      expect(File(first).existsSync(), isTrue);

      platform.nextSaveLocation = () => null;
      await files.save(png, suggestedName: name, type: RecapExportType.png);

      expect(File(first).existsSync(), isFalse);
      expect(tempFiles(), isEmpty);
    });

    test('an unknown answer is reported as unknown and the file kept until '
        'released', () async {
      platform.shareStatus = RecapShareStatus.unknown;

      expect(await share(), RecapShareOutcome.unknown);
      expect(tempFiles(), hasLength(1));

      await files.release();
      expect(tempFiles(), isEmpty);
    });

    test('a second share removes the first one\'s file', () async {
      await share(Uint8List.fromList([1]));
      final first = platform.shareRequests.single.$1;

      await share(Uint8List.fromList([2]));

      expect(File(first).existsSync(), isFalse);
      final second = platform.shareRequests.last;
      expect(second.$4, [2]);
      expect(tempFiles(), [second.$1]);
    });

    test('a share sheet error fails and removes the file', () async {
      platform.shareError = StateError('sheet broke');

      expect(await share(), RecapShareOutcome.failed);

      expect(platform.shareRequests, hasLength(1));
      expect(tempFiles(), isEmpty);
    });

    test('a platform that cannot share files writes nothing', () async {
      platform.canShare = false;

      expect(await share(), RecapShareOutcome.unavailable);

      expect(platform.shareRequests, isEmpty);
      expect(platform.temporaryDirectoryCalls, 0);
      expect(tempRoot.listSync(), isEmpty);
    });

    test('a temporary file that cannot be written fails before the sheet '
        'opens', skip: skipUnlessChmodDenies, () async {
      Process.runSync('chmod', ['555', tempRoot.path]);

      expect(await share(), RecapShareOutcome.failed);

      expect(platform.shareRequests, isEmpty);
    });

    test('released while the sheet is open (page left mid-export): the file '
        'is removed once the sheet answers', () async {
      final open = Completer<void>();
      final answer = Completer<void>();
      platform.whileShareOpen = () async {
        open.complete();
        await answer.future;
      };
      final sharing = share();
      await open.future;

      await files.release();
      answer.complete();
      await sharing;

      expect(tempFiles(), isEmpty);
    });

    test('released while the share is still being prepared (page left '
        'early): nothing is kept afterwards (review r1 F6)', () async {
      final asked = Completer<void>();
      final answer = Completer<void>();
      platform.whileTemporaryDirectoryRequested = () async {
        asked.complete();
        await answer.future;
      };
      final sharing = share();
      await asked.future;

      await files.release();
      platform.whileTemporaryDirectoryRequested = null;
      answer.complete();
      await sharing;

      expect(tempFiles(), isEmpty);
    });

    test('a save while a shared file is kept leaves the save\'s own file '
        'alone and removes the shared one', () async {
      await share();
      final shared = platform.shareRequests.single.$1;
      final target = p.join(dest.path, 'saved.png');
      platform.nextSaveLocation = () => target;

      expect(
        await files.save(png, suggestedName: name, type: RecapExportType.png),
        RecapSaveOutcome.saved,
      );

      expect(File(shared).existsSync(), isFalse);
      expect(File(target).readAsBytesSync(), png);
      expect(tempFiles(), isEmpty);
    });
  });

  // Pre-merge review C2-03: a local reset (Disconnect, a user switch)
  // removes the owned folder, so the previous person's shared recap does not
  // stay on the device until the next export. Only that folder; never what a
  // link points to.
  group('a local reset', () {
    String owned() => p.join(tempRoot.path, RecapExportFiles.folderName);
    Future<RecapShareOutcome> share() =>
        files.share(png, suggestedName: name, type: RecapExportType.png);

    test('is a file-deleting wipe step', () {
      expect(files.resetPriority, ResetPriority.deleteFiles);
    });

    test('removes a held share and left-over exports', () async {
      expect(await share(), RecapShareOutcome.shared);
      final held = platform.shareRequests.single.$1;
      expect(File(held).existsSync(), isTrue);
      final leftover = Directory(p.join(owned(), 'export-crashed'))
        ..createSync(recursive: true);
      File(p.join(leftover.path, name)).writeAsBytesSync(png);

      await files.resetLocalState();

      expect(tempFiles(), isEmpty);
      expect(Directory(owned()).existsSync(), isFalse);
      // Nothing else under the temporary directory is touched.
      expect(tempRoot.existsSync(), isTrue);
    });

    test('is a no-op without the folder, and can run again', () async {
      final other = File(p.join(tempRoot.path, 'not-ours.txt'))
        ..writeAsStringSync('keep');
      await files.resetLocalState();
      await files.resetLocalState();
      expect(other.readAsStringSync(), 'keep');
    });

    test('an owned folder that is a link: the link goes, never what it '
        'points to', () async {
      final elsewhere = Directory(p.join(root.path, 'elsewhere'))..createSync();
      final precious = File(p.join(elsewhere.path, 'precious.txt'))
        ..writeAsStringSync('keep');
      Link(owned()).createSync(elsewhere.path);

      await files.resetLocalState();

      expect(precious.readAsStringSync(), 'keep');
      expect(FileSystemEntity.typeSync(owned(), followLinks: false),
          FileSystemEntityType.notFound);
    });

    // Pre-merge review r1 R-1: a folder that cannot be removed is logged and
    // left for the next export's sweep; it never fails the reset (which
    // would keep the reset marker and refuse every connect).
    test('a folder that cannot be removed is logged, not a reset failure',
        skip: skipUnlessChmodDenies, () async {
      final leftover = Directory(p.join(owned(), 'export-crashed'))
        ..createSync(recursive: true);
      File(p.join(leftover.path, name)).writeAsBytesSync(png);
      Process.runSync('chmod', ['555', leftover.path]);

      await files.resetLocalState();

      expect(logs, isNotEmpty);
      for (final line in logs) {
        expect(line, isNot(contains(root.path)));
      }
      Process.runSync('chmod', ['755', leftover.path]);
    });

    test('a later share after the reset still works', () async {
      expect(await share(), RecapShareOutcome.shared);
      await files.resetLocalState();
      expect(await share(), RecapShareOutcome.shared);
      expect(File(platform.shareRequests.last.$1).existsSync(), isTrue);
    });
  });

  // Other-issues row 75: a failed save or share writes one log line with the
  // step and the error's type, never its message or a path.
  group('failures are logged with the step and the error type only', () {
    void expectOneLine(String step, String type, List<String> secrets) {
      expect(logs, hasLength(1), reason: '$logs');
      final line = logs.single;
      expect(line, contains(step));
      expect(line, contains(type));
      for (final secret in [root.path, ...secrets]) {
        expect(line, isNot(contains(secret)));
      }
    }

    test('the save panel', () async {
      platform.panelError = StateError('panel broke at /secret/place');
      expect(await save(), RecapSaveOutcome.failed);
      expectOneLine('recap save: the save panel failed', 'StateError',
          ['panel broke', '/secret/place']);
    });

    test('placing the file', () async {
      final target = p.join(dest.path, 'missing-folder', name);
      platform.nextSaveLocation = () => target;
      expect(await save(), RecapSaveOutcome.failed);
      expectOneLine('recap save: placing the file failed', 'Exception',
          ['missing-folder', name]);
    });

    test('the temporary file cannot be written', () async {
      expect(
        await files.save(png,
            suggestedName: p.join('no-such-folder', name),
            type: RecapExportType.png),
        RecapSaveOutcome.failed,
      );
      expect(platform.saveRequests, isEmpty);
      expectOneLine('recap save: writing the temporary file failed',
          'Exception', ['no-such-folder', name]);
    });

    test('the export folder cannot be prepared',
        skip: skipUnlessChmodDenies, () async {
      Process.runSync('chmod', ['555', tempRoot.path]);
      expect(await save(), RecapSaveOutcome.failed);
      expectOneLine('recap save: preparing the export failed', 'Exception',
          [RecapExportFiles.folderName]);
    });

    test('the share sheet', () async {
      platform.shareError = StateError('sheet broke at /secret/place');
      expect(
        await files.share(png, suggestedName: name, type: RecapExportType.png),
        RecapShareOutcome.failed,
      );
      expectOneLine('recap share failed', 'StateError',
          ['sheet broke', '/secret/place']);
    });
  });
}
