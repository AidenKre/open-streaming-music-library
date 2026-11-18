// Phase 7 §7: "implement native file picker through a maintained plugin";
// "Tests fake picker boundary, not the entire upload flow." The native picker
// wraps file_selector's openFiles (the seam faked here); each picked file
// becomes a FileUploadSource with the panel's name as its display name.
// FakeUploadSourcePicker is the plainly named stand-in the live gate injects
// (plan §5: no native panel is driven in this run).
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_source_picker.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('osml_upload_picker_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<String> write(String name, int bytes) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(List<int>.filled(bytes, 1));
    return file.path;
  }

  group('NativeUploadSourcePicker', () {
    test('each picked file becomes a source with its name and length',
        () async {
      final a = await write('a.flac', 10);
      final b = await write('b.mp3', 20);
      final picker = NativeUploadSourcePicker(
        // On dart:io XFile.name is the path's last segment (cross_file
        // ignores the name argument there); the panel's name is used as is.
        openFiles: () async => [XFile(a), XFile(b)],
      );

      final selection = await picker.pick();

      expect(selection.sources.map((s) => s.displayName),
          ['a.flac', 'b.mp3']);
      expect(selection.sources.map((s) => s.length), [10, 20]);
      expect(selection.sources.map((s) => s.path), [a, b]);
      expect(selection.unavailable, isEmpty);
      expect(selection.isEmpty, isFalse);
    });

    test('a cancelled panel is an empty selection', () async {
      final picker = NativeUploadSourcePicker(openFiles: () async => []);

      final selection = await picker.pick();

      expect(selection.sources, isEmpty);
      expect(selection.unavailable, isEmpty);
      expect(selection.isEmpty, isTrue);
    });

    test('a picked file that cannot be opened is named, not dropped silently',
        () async {
      final a = await write('a.flac', 10);
      final picker = NativeUploadSourcePicker(
        openFiles: () async => [
          XFile(a),
          XFile('${dir.path}/vanished.flac', name: 'vanished.flac'),
        ],
      );

      final selection = await picker.pick();

      expect(selection.sources.single.displayName, 'a.flac');
      expect(selection.unavailable, ['vanished.flac']);
    });

    test('the selection order is kept (it becomes the selection index)',
        () async {
      final paths = [
        for (final n in ['c', 'a', 'b']) await write('$n.flac', 1),
      ];
      final picker = NativeUploadSourcePicker(
        openFiles: () async => [for (final p in paths) XFile(p)],
      );

      final selection = await picker.pick();

      expect(selection.sources.map((s) => s.displayName),
          ['c.flac', 'a.flac', 'b.flac']);
    });
  });

  group('FakeUploadSourcePicker', () {
    test('answers queued real files in order, then empty selections',
        () async {
      final a = await write('a.flac', 3);
      final b = await write('b.flac', 4);
      final picker = FakeUploadSourcePicker()
        ..enqueue([a, b])
        ..enqueue([b]);

      final first = await picker.pick();
      final second = await picker.pick();
      final third = await picker.pick();

      expect(first.sources.map((s) => s.length), [3, 4]);
      expect(second.sources.single.displayName, 'b.flac');
      expect(third.isEmpty, isTrue);
      expect(picker.picks, 3);
    });

    test('a queued path that does not exist is reported unavailable',
        () async {
      final picker = FakeUploadSourcePicker()
        ..enqueue(['${dir.path}/missing.flac']);

      final selection = await picker.pick();

      expect(selection.sources, isEmpty);
      expect(selection.unavailable, ['missing.flac']);
    });
  });

  test('the scope picker is the native one; tests and the gate override it',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(uploadSourcePickerProvider), isA<NativeUploadSourcePicker>());

    final fake = FakeUploadSourcePicker();
    final overridden = ProviderContainer(
      overrides: [uploadSourcePickerProvider.overrideWithValue(fake)],
    );
    addTearDown(overridden.dispose);
    expect(overridden.read(uploadSourcePickerProvider), same(fake));
  });
}
