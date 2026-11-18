import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/memory_upload_source.dart';

// Independent fixtures (computed with Python's hashlib, not with `crypto`).
const _abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

/// sha256 of bytes `i % 251` for i in 0 until 300 KiB.
const _patternSha256 =
    '10a6169813fcc0410b3d72574ff2dd1997936b90db821427136315967cff2bb9';
const _patternLength = 300 * 1024;

List<int> _pattern() => [for (var i = 0; i < _patternLength; i++) i % 251];

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('osml_upload_source_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('digestUploadSource', () {
    test('the digest of a 3-chunk stream equals the independent fixture',
        () async {
      final source = MemoryUploadSource([
        'a'.codeUnits,
        'b'.codeUnits,
        'c'.codeUnits,
      ]);

      final digest = await digestUploadSource(source);

      expect(digest.sha256, _abcSha256);
      expect(digest.length, 3);
      expect(source.opens, 1);
    });

    test('chunk boundaries do not change the digest', () async {
      final bytes = _pattern();
      final source = MemoryUploadSource([
        bytes.sublist(0, 1),
        bytes.sublist(1, 70000),
        bytes.sublist(70000, 70001),
        bytes.sublist(70001),
      ]);

      final digest = await digestUploadSource(source);

      expect(digest.sha256, _patternSha256);
      expect(digest.length, _patternLength);
    });

    test('fewer bytes than the selected length is a length change', () async {
      final source = MemoryUploadSource(['abc'.codeUnits], length: 4);

      await expectLater(
        digestUploadSource(source),
        throwsA(
          isA<UploadSourceChanged>().having(
            (e) => e.change,
            'change',
            SourceChange.length,
          ),
        ),
      );
    });

    test('more bytes than the selected length is a length change', () async {
      final source = MemoryUploadSource(['abcd'.codeUnits], length: 3);

      await expectLater(
        digestUploadSource(source),
        throwsA(
          isA<UploadSourceChanged>().having(
            (e) => e.change,
            'change',
            SourceChange.length,
          ),
        ),
      );
    });

    test('a read failure mid-stream is UploadSourceUnavailable', () async {
      final source = MemoryUploadSource(
        ['a'.codeUnits, 'b'.codeUnits, 'c'.codeUnits],
        failAfterChunks: 2,
      );

      await expectLater(
        digestUploadSource(source),
        throwsA(isA<UploadSourceUnavailable>()),
      );
    });
  });

  group('FileUploadSource', () {
    test('open stats the file; the name defaults to the last path segment',
        () async {
      final file = File('${dir.path}/My Song.flac');
      await file.writeAsBytes(_pattern());

      final source = await FileUploadSource.open(file.path);

      expect(source.displayName, 'My Song.flac');
      expect(source.length, _patternLength);
      expect(source.path, file.path);
    });

    test('an explicit display name is kept apart from the path', () async {
      final file = File('${dir.path}/x.bin');
      await file.writeAsBytes([1, 2, 3]);

      final source = await FileUploadSource.open(
        file.path,
        displayName: 'Picked name.mp3',
      );

      expect(source.displayName, 'Picked name.mp3');
      expect(source.toString(), isNot(contains(dir.path)));
    });

    test('a file streams in bounded chunks, digest matches the fixture',
        () async {
      final file = File('${dir.path}/song.flac');
      await file.writeAsBytes(_pattern());
      final source = await FileUploadSource.open(file.path);

      final sizes = <int>[];
      await for (final chunk in source.openRead()) {
        sizes.add(chunk.length);
      }

      expect(sizes.fold<int>(0, (a, b) => a + b), _patternLength);
      expect(sizes.length, greaterThan(1));
      expect(sizes.every((n) => n <= 64 * 1024), isTrue);
      expect((await digestUploadSource(source)).sha256, _patternSha256);
    });

    test('every openRead is a new stream over the whole file', () async {
      final file = File('${dir.path}/song.flac');
      await file.writeAsBytes('abc'.codeUnits);
      final source = await FileUploadSource.open(file.path);

      final first = await digestUploadSource(source);
      final second = await digestUploadSource(source);

      expect(first.sha256, _abcSha256);
      expect(second.sha256, _abcSha256);
    });

    test('a missing file cannot be opened', () async {
      await expectLater(
        FileUploadSource.open('${dir.path}/missing.flac'),
        throwsA(isA<UploadSourceUnavailable>()),
      );
    });

    test('a directory is not a source', () async {
      await expectLater(
        FileUploadSource.open(dir.path),
        throwsA(isA<UploadSourceUnavailable>()),
      );
    });

    test('a file deleted after selection is unavailable when read', () async {
      final file = File('${dir.path}/song.flac');
      await file.writeAsBytes('abc'.codeUnits);
      final source = await FileUploadSource.open(file.path);
      await file.delete();

      await expectLater(
        digestUploadSource(source),
        throwsA(isA<UploadSourceUnavailable>()),
      );
    });
  });
}
