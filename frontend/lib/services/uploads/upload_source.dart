/// Phase 7 §7: the source of one upload (a file the user selected).
///
/// Model code: imports nothing from `ui/`. Nothing here buffers a whole
/// file; every read is a stream of bounded chunks.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// One selected file, readable as many times as needed.
abstract interface class UploadSource {
  /// What the user sees (the file name). Never a path.
  String get displayName;

  /// The length in bytes when the source was selected or reopened.
  int get length;

  /// A new stream over the whole content on every call, in bounded chunks.
  /// A read failure (gone, no permission) is an [UploadSourceUnavailable].
  Stream<List<int>> openRead();
}

/// The source can't be opened or read (deleted, moved, no permission, or the
/// macOS sandbox no longer grants access after a relaunch).
class UploadSourceUnavailable implements Exception {
  const UploadSourceUnavailable();

  @override
  String toString() => 'UploadSourceUnavailable';
}

/// What differs from the selected source.
enum SourceChange { length, digest }

/// The source's content no longer matches what was selected and hashed.
class UploadSourceChanged implements Exception {
  const UploadSourceChanged(this.change);
  final SourceChange change;

  @override
  String toString() => 'UploadSourceChanged(${change.name})';
}

/// A file on the local file system.
class FileUploadSource implements UploadSource {
  FileUploadSource({
    required this.path,
    required this.displayName,
    required this.length,
  });

  /// Stats [path]. [displayName] defaults to the path's last segment.
  /// Throws [UploadSourceUnavailable] when the file can't be opened.
  static Future<FileUploadSource> open(
    String path, {
    String? displayName,
  }) async {
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const UploadSourceUnavailable();
      }
      return FileUploadSource(
        path: path,
        displayName: displayName ?? p.basename(path),
        length: stat.size,
      );
    } on FileSystemException {
      throw const UploadSourceUnavailable();
    }
  }

  /// Local only: never sent to the server and never logged.
  final String path;

  @override
  final String displayName;

  @override
  final int length;

  @override
  Stream<List<int>> openRead() => File(path).openRead().transform(
    StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleError: (error, stackTrace, sink) {
        if (error is FileSystemException) {
          sink.addError(const UploadSourceUnavailable(), stackTrace);
        } else {
          sink.addError(error, stackTrace);
        }
      },
    ),
  );

  @override
  String toString() => 'FileUploadSource($displayName, $length bytes)';
}

/// A source's SHA-256 (lower-case hex) and the bytes actually read.
class SourceDigest {
  const SourceDigest({required this.sha256, required this.length});
  final String sha256;
  final int length;
}

/// Streams [source] once through SHA-256 (no whole-file buffer).
///
/// Throws [UploadSourceUnavailable] when the read fails and
/// [UploadSourceChanged] (`length`) when the bytes read differ from
/// [UploadSource.length].
Future<SourceDigest> digestUploadSource(UploadSource source) async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  var count = 0;
  try {
    await for (final chunk in source.openRead()) {
      count += chunk.length;
      if (count > source.length) break; // cancels the subscription
      input.add(chunk);
    }
  } on FileSystemException {
    throw const UploadSourceUnavailable();
  }
  if (count != source.length) {
    throw const UploadSourceChanged(SourceChange.length);
  }
  input.close();
  return SourceDigest(sha256: out.digest.toString(), length: count);
}

class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

/// What is persisted about a selected source (plan O7, DEV-7-04): its path,
/// length and digest. No security-scoped bookmark: after a relaunch the
/// macOS sandbox usually refuses the path, and the user reselects the file.
///
/// [locationJson] goes into `upload_intents.source_descriptor_json`; the
/// length and digest go into `expected_length` / `expected_sha256`. The
/// display name is stored separately (`display_name`). The path is local
/// only: never sent to the server, never logged.
class UploadSourceDescriptor {
  const UploadSourceDescriptor({
    required this.path,
    required this.length,
    required this.sha256,
  });

  /// Hashes [source] (streamed) and describes it.
  static Future<UploadSourceDescriptor> of(FileUploadSource source) async {
    final digest = await digestUploadSource(source);
    return UploadSourceDescriptor(
      path: source.path,
      length: digest.length,
      sha256: digest.sha256,
    );
  }

  /// The descriptor stored in the three columns, or null when any of them is
  /// missing or unreadable (the source must be selected again).
  static UploadSourceDescriptor? fromColumns({
    required String? locationJson,
    required int? expectedLength,
    required String? expectedSha256,
  }) {
    if (locationJson == null ||
        expectedLength == null ||
        expectedSha256 == null) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(locationJson);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['v'] != 1 || decoded['v'] is! int) {
      return null;
    }
    final path = decoded['path'];
    if (path is! String || path.isEmpty) return null;
    return UploadSourceDescriptor(
      path: path,
      length: expectedLength,
      sha256: expectedSha256,
    );
  }

  final String path;
  final int length;
  final String sha256;

  /// `{"v": 1, "path": ...}`.
  String locationJson() => jsonEncode({'v': 1, 'path': path});

  @override
  String toString() => 'UploadSourceDescriptor($length bytes)';
}

/// The content PUT body for [source]: its bytes, checked against the
/// allocation's [expectedLength] and [expectedSha256] while they stream.
///
/// The last chunk is held back until the source has ended and its digest is
/// known, so a source that changed after it was hashed fails with
/// [UploadSourceChanged] before the server has received a complete body (the
/// server then sees an interrupted transfer and keeps the allocation, rather
/// than failing the item on a digest mismatch). More bytes than expected
/// stop the read at once. Lazy (nothing is read before a listener), bounded
/// (one chunk held), and pause / cancel reach the source read.
Stream<List<int>> verifiedUploadBody(
  UploadSource source, {
  required int expectedLength,
  required String expectedSha256,
}) async* {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  var count = 0;
  List<int>? held;
  try {
    await for (final chunk in source.openRead()) {
      count += chunk.length;
      if (count > expectedLength) break; // cancels the source read
      input.add(chunk);
      final previous = held;
      held = chunk;
      if (previous != null) yield previous;
    }
  } on FileSystemException {
    throw const UploadSourceUnavailable();
  }
  if (count != expectedLength) {
    throw const UploadSourceChanged(SourceChange.length);
  }
  input.close();
  if (out.digest.toString() != expectedSha256.toLowerCase()) {
    throw const UploadSourceChanged(SourceChange.digest);
  }
  if (held != null) yield held;
}
