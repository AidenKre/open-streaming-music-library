// SC-05/SC-26 (Phase 6 §5, 6-U10): the playback model never resolves
// membership. PlayCollection carries resolved, ordered UUIDs; nothing under
// lib/playback/ reaches the library through BrowseRepository or the database.
// And there is one click emit site: PlaybackRequests.submit.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _playbackFiles() => Directory('lib/playback')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

/// [source] without line comments, so docs that name a symbol don't count.
String _code(File file) => file
    .readAsLinesSync()
    .map((line) => line.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

void main() {
  test('lib/playback is not empty', () {
    expect(_playbackFiles().length, greaterThan(10));
  });

  test('no library or membership query in lib/playback', () {
    final forbidden = [
      RegExp(r'\bBrowseRepository\b'),
      RegExp(r'\bbrowseRepositoryProvider\b'),
      RegExp(r'\bgetTracksForScope\b'),
      RegExp(r'\bgetTracksByUuids\b'),
      RegExp(r'\bgetTracks\('),
      RegExp(r'\bwatchTracks\b'),
      RegExp(r'\bwatchAlbums\b'),
      RegExp(r'\bwatchArtists\b'),
      RegExp(r'repositories/browse_repository\.dart'),
    ];
    final hits = [
      for (final file in _playbackFiles())
        for (final pattern in forbidden)
          if (pattern.hasMatch(_code(file))) '${file.path}: ${pattern.pattern}',
    ];
    expect(hits, isEmpty);
  });

  test('the database is read in lib/playback only by the failure '
      'classifier\'s single-track check', () {
    // 5B.0d: SourceFailureClassifier asks whether one track is still known
    // locally before calling a failure "gone". It is not a membership query.
    const allowed = 'lib/playback/source_failure_classifier.dart';
    final readers = [
      for (final file in _playbackFiles())
        if (RegExp(r'\bdatabaseProvider\b').hasMatch(_code(file))) file.path,
    ];
    expect(readers, [allowed]);
    final uses = RegExp(r'databaseProvider\)\.(\w+)\(')
        .allMatches(_code(File(allowed)))
        .map((m) => m.group(1))
        .toSet();
    expect(uses, {'getTrackByUuid'});
  });

  test('the click recorder is used only in PlaybackRequests.submit', () {
    final users = [
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')))
        if (!file.path.startsWith('lib/services/history/') &&
            RegExp(r'\bclickRecorderProvider\b').hasMatch(_code(file)))
          file.path,
    ];
    expect(users, ['lib/playback/playback_requests.dart']);
    final source = _code(File('lib/playback/playback_requests.dart'));
    expect(RegExp(r'\bclickRecorderProvider\b').allMatches(source),
        hasLength(1));
    final submit = source.indexOf('Future<PlaybackOutcome> submit(');
    final nextMethod =
        source.indexOf('Future<PlaybackOutcome> _submit(', submit);
    final use = source.indexOf('clickRecorderProvider');
    expect(submit, greaterThanOrEqualTo(0));
    expect(use, inExclusiveRange(submit, nextMethod),
        reason: 'inside submit, after the outcome is known');
  });
}
