import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_source.dart';

// Independent fixtures (Python hashlib).
const _abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('osml_upload_reopen_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> write(String name, List<int> bytes) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  group('UploadSourceDescriptor', () {
    test('describes a source by path, length and digest', () async {
      final file = await write('song.flac', 'abc'.codeUnits);
      final source = await FileUploadSource.open(file.path);

      final descriptor = await UploadSourceDescriptor.of(source);

      expect(descriptor.path, file.path);
      expect(descriptor.length, 3);
      expect(descriptor.sha256, _abcSha256);
    });

    test('the location JSON holds the path, not the name or the digest',
        () async {
      const descriptor = UploadSourceDescriptor(
        path: '/Users/me/Music/song.flac',
        length: 3,
        sha256: _abcSha256,
      );

      final json = jsonDecode(descriptor.locationJson()) as Map;

      expect(json['path'], '/Users/me/Music/song.flac');
      expect(json.containsKey('sha256'), isFalse);
      expect(json.containsKey('length'), isFalse);
      expect(json['v'], 1);
    });

    test('round-trips through the three upload_intents columns', () {
      const descriptor = UploadSourceDescriptor(
        path: '/tmp/a b/ü.flac',
        length: 12345,
        sha256: _abcSha256,
      );

      final back = UploadSourceDescriptor.fromColumns(
        locationJson: descriptor.locationJson(),
        expectedLength: descriptor.length,
        expectedSha256: descriptor.sha256,
      );

      expect(back, isNotNull);
      expect(back!.path, descriptor.path);
      expect(back.length, descriptor.length);
      expect(back.sha256, descriptor.sha256);
    });

    test('a missing column means no descriptor (reselect), never zero', () {
      const location = '{"v":1,"path":"/tmp/x.flac"}';
      expect(
        UploadSourceDescriptor.fromColumns(
          locationJson: null,
          expectedLength: 3,
          expectedSha256: _abcSha256,
        ),
        isNull,
      );
      expect(
        UploadSourceDescriptor.fromColumns(
          locationJson: location,
          expectedLength: null,
          expectedSha256: _abcSha256,
        ),
        isNull,
      );
      expect(
        UploadSourceDescriptor.fromColumns(
          locationJson: location,
          expectedLength: 3,
          expectedSha256: null,
        ),
        isNull,
      );
    });

    test('unreadable location JSON means no descriptor', () {
      for (final bad in [
        'not json',
        '[]',
        '{"v":1}',
        '{"v":1,"path":7}',
        '{"v":1,"path":""}',
        '{"v":2,"path":"/tmp/x.flac"}',
        '{"path":"/tmp/x.flac"}',
      ]) {
        expect(
          UploadSourceDescriptor.fromColumns(
            locationJson: bad,
            expectedLength: 3,
            expectedSha256: _abcSha256,
          ),
          isNull,
          reason: bad,
        );
      }
    });

    test('toString does not carry the path', () {
      const descriptor = UploadSourceDescriptor(
        path: '/Users/me/secret/song.flac',
        length: 3,
        sha256: _abcSha256,
      );
      expect(descriptor.toString(), isNot(contains('/Users/me')));
    });
  });

  group('reopenUploadSource', () {
    test('the same file reopens as a ready source with the stored name',
        () async {
      final file = await write('song.flac', 'abc'.codeUnits);
      const name = 'Track 01.flac';

      final result = await reopenUploadSource(
        UploadSourceDescriptor(path: file.path, length: 3, sha256: _abcSha256),
        displayName: name,
      );

      expect(result, isA<SourceReopened>());
      final source = (result as SourceReopened).source;
      expect(source.displayName, name);
      expect(source.length, 3);
      expect(source.path, file.path);
    });

    test('a different length is sourceChanged (length)', () async {
      final file = await write('song.flac', 'abcd'.codeUnits);

      final result = await reopenUploadSource(
        UploadSourceDescriptor(path: file.path, length: 3, sha256: _abcSha256),
        displayName: 'song.flac',
      );

      expect(
        result,
        isA<SourceChangedSinceSelection>()
            .having((r) => r.change, 'change', SourceChange.length),
      );
    });

    test('the same length with other bytes is sourceChanged (digest)',
        () async {
      final file = await write('song.flac', 'abd'.codeUnits);

      final result = await reopenUploadSource(
        UploadSourceDescriptor(path: file.path, length: 3, sha256: _abcSha256),
        displayName: 'song.flac',
      );

      expect(
        result,
        isA<SourceChangedSinceSelection>()
            .having((r) => r.change, 'change', SourceChange.digest),
      );
    });

    test('a digest stored in upper case still matches', () async {
      final file = await write('song.flac', 'abc'.codeUnits);

      final result = await reopenUploadSource(
        UploadSourceDescriptor(
          path: file.path,
          length: 3,
          sha256: _abcSha256.toUpperCase(),
        ),
        displayName: 'song.flac',
      );

      expect(result, isA<SourceReopened>());
    });

    test('a missing file needs reselect, not "changed"', () async {
      final result = await reopenUploadSource(
        UploadSourceDescriptor(
          path: '${dir.path}/gone.flac',
          length: 3,
          sha256: _abcSha256,
        ),
        displayName: 'gone.flac',
      );

      expect(result, isA<SourceNeedsReselect>());
    });

    test('a file the app may no longer read needs reselect', () async {
      final file = await write('song.flac', 'abc'.codeUnits);
      await Process.run('chmod', ['000', file.path]);
      addTearDown(() => Process.run('chmod', ['600', file.path]));

      final result = await reopenUploadSource(
        UploadSourceDescriptor(path: file.path, length: 3, sha256: _abcSha256),
        displayName: 'song.flac',
      );

      expect(result, isA<SourceNeedsReselect>());
    });
  });
}
