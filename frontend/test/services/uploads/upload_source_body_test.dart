import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/memory_upload_source.dart';

// Independent fixture (Python hashlib): sha256("abcdef").
const _abcdefSha256 =
    'bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721';

/// Listens to [body] to the end; returns the bytes received and the error.
Future<({List<int> bytes, Object? error})> _drain(Stream<List<int>> body) async {
  final bytes = <int>[];
  Object? error;
  try {
    await for (final chunk in body) {
      bytes.addAll(chunk);
    }
  } catch (e) {
    error = e;
  }
  return (bytes: bytes, error: error);
}

Matcher _changed(SourceChange change) =>
    isA<UploadSourceChanged>().having((e) => e.change, 'change', change);

void main() {
  test('an unchanged source yields exactly its bytes, then ends', () async {
    final source = MemoryUploadSource(
      ['ab'.codeUnits, 'cd'.codeUnits, 'ef'.codeUnits],
    );

    final result = await _drain(
      verifiedUploadBody(source, expectedLength: 6, expectedSha256: _abcdefSha256),
    );

    expect(result.error, isNull);
    expect(String.fromCharCodes(result.bytes), 'abcdef');
    expect(source.openStreams, 0);
  });

  test('the expected digest is compared case-insensitively', () async {
    final source = MemoryUploadSource(['abcdef'.codeUnits]);

    final result = await _drain(
      verifiedUploadBody(
        source,
        expectedLength: 6,
        expectedSha256: _abcdefSha256.toUpperCase(),
      ),
    );

    expect(result.error, isNull);
    expect(result.bytes.length, 6);
  });

  test('other bytes of the same length: digest change, last chunk withheld',
      () async {
    final source = MemoryUploadSource(
      ['ab'.codeUnits, 'cd'.codeUnits, 'eX'.codeUnits],
    );

    final result = await _drain(
      verifiedUploadBody(source, expectedLength: 6, expectedSha256: _abcdefSha256),
    );

    expect(result.error, _changed(SourceChange.digest));
    // The server never receives a complete body, so it can't fail the
    // allocation on a digest mismatch.
    expect(result.bytes.length, lessThan(6));
  });

  test('a single-chunk changed source sends nothing', () async {
    final source = MemoryUploadSource(['abcdeX'.codeUnits]);

    final result = await _drain(
      verifiedUploadBody(source, expectedLength: 6, expectedSha256: _abcdefSha256),
    );

    expect(result.error, _changed(SourceChange.digest));
    expect(result.bytes, isEmpty);
  });

  test('a longer source stops before the excess and is cancelled', () async {
    final source = MemoryUploadSource(
      ['abc'.codeUnits, 'def'.codeUnits, 'g'.codeUnits, 'h'.codeUnits],
    );

    final result = await _drain(
      verifiedUploadBody(source, expectedLength: 6, expectedSha256: _abcdefSha256),
    );

    expect(result.error, _changed(SourceChange.length));
    expect(result.bytes.length, lessThan(6));
    expect(source.cancels, 1);
    expect(source.openStreams, 0);
  });

  test('a shorter source is a length change and the body stays short',
      () async {
    final source = MemoryUploadSource(['abc'.codeUnits, 'de'.codeUnits]);

    final result = await _drain(
      verifiedUploadBody(source, expectedLength: 6, expectedSha256: _abcdefSha256),
    );

    expect(result.error, _changed(SourceChange.length));
    expect(result.bytes.length, lessThan(5));
  });

  test('a read failure surfaces as UploadSourceUnavailable', () async {
    final source = MemoryUploadSource(
      ['ab'.codeUnits, 'cd'.codeUnits, 'ef'.codeUnits],
      failAfterChunks: 2,
    );

    final result = await _drain(
      verifiedUploadBody(source, expectedLength: 6, expectedSha256: _abcdefSha256),
    );

    expect(result.error, isA<UploadSourceUnavailable>());
  });

  test('nothing is read until the body is listened to', () async {
    final source = MemoryUploadSource(['abcdef'.codeUnits]);

    verifiedUploadBody(source, expectedLength: 6, expectedSha256: _abcdefSha256);
    await pumpEventQueue();

    expect(source.opens, 0);
  });

  test('cancelling the body cancels the source read', () async {
    final source = MemoryUploadSource(
      [for (var i = 0; i < 6; i++) 'x'.codeUnits],
    );
    final body = verifiedUploadBody(
      source,
      expectedLength: 6,
      expectedSha256: _abcdefSha256,
    );

    final first = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = body.listen((_) {
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    await sub.cancel();
    await pumpEventQueue();

    expect(source.openStreams, 0);
    expect(source.cancels, 1);
  });
}
