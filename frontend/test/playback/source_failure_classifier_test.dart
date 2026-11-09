import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/models/dto/client_track_dto.dart';

import 'package:frontend/playback/playback_issue_bus.dart';
import 'package:frontend/playback/source_failure_classifier.dart';

void main() {
  final files = <String>{};
  final known = <String>{};
  final statuses = <String, int?>{};
  var offline = false;
  var probes = 0;
  late SourceFailureClassifier classifier;

  setUp(() {
    files.clear();
    known
      ..clear()
      ..add('t');
    statuses.clear();
    offline = false;
    probes = 0;
    classifier = SourceFailureClassifier(
      fileExists: (path) async => files.contains(path),
      trackKnownLocally: (uuid) async => known.contains(uuid),
      fetchTrackStatus: (uuid) async {
        probes++;
        return statuses[uuid];
      },
      isOffline: () => offline,
    );
  });

  Future<SourceFailureKind> classify({String? path, bool uncertain = false}) =>
      classifier.classify(trackUuid: 't', filePath: path, uncertain: uncertain);

  test('a recorded file that is not on disk is missingLocalFile', () async {
    expect(await classify(path: '/gone'), SourceFailureKind.missingLocalFile);
  });

  // Decision 6 (user, 2026-11-07): a file that is on disk but fails to play
  // is a damaged download, not unknown (it was never skipped as gone).
  test('a present file that fails is a damaged download, never gone',
      () async {
    files.add('/here');
    expect(await classify(path: '/here'), SourceFailureKind.damagedLocalFile);
    expect(probes, 0);
  });

  test('an uncertain failure of a present file stays unknown', () async {
    files.add('/here');
    expect(await classify(path: '/here', uncertain: true),
        SourceFailureKind.unknown);
  });

  test("a track the local catalog no longer has (tombstone) is gone", () async {
    known.clear();
    expect(await classify(), SourceFailureKind.gone);
    expect(probes, 0, reason: 'the tombstone is authoritative');
  });

  test('a 404 or 410 from the bounded track check is gone', () async {
    statuses['t'] = 404;
    expect(await classify(), SourceFailureKind.gone);
    statuses['t'] = 410;
    expect(await classify(), SourceFailureKind.gone);
  });

  test('no answer, a server error or offline is transient', () async {
    statuses['t'] = null;
    expect(await classify(), SourceFailureKind.transient);
    statuses['t'] = 503;
    expect(await classify(), SourceFailureKind.transient);
    offline = true;
    final before = probes;
    expect(await classify(), SourceFailureKind.transient);
    expect(probes, before, reason: 'no network check while offline');
  });

  test('a track the server still has, or an uncertain failure, is unknown',
      () async {
    statuses['t'] = 200;
    expect(await classify(), SourceFailureKind.unknown);
    known.clear();
    expect(await classify(uncertain: true), SourceFailureKind.unknown,
        reason: 'identity was not settled: nothing is confirmed');
  });

  group('the bounded track check (production mapping)', () {
    test('an answer maps to 200, an HTTP rejection to its status', () async {
      expect(await trackStatusVia(_Api(() async => _dto()), 't'), 200);
      expect(await trackStatusVia(
          _Api(() async => throw ApiException(404, 'gone')), 't'), 404);
      expect(await trackStatusVia(
          _Api(() async => throw ApiException(410, 'gone')), 't'), 410);
    });

    test('no answer (network failure, timeout) is null, never gone',
        () async {
      expect(await trackStatusVia(
          _Api(() async => throw NetworkException('down', attemptsMade: 1)), 't'), isNull);
      expect(await trackStatusVia(
          _Api(() => Completer<ClientTrackDto>().future), 't',
          timeout: const Duration(milliseconds: 1)), isNull);
    });
  });
}

ClientTrackDto _dto() => ClientTrackDto.fromJson({
      'uuid_id': 't',
      'created_at': 1,
      'last_updated': 1,
      'revision': 1,
      'metadata': {'title': 'T'},
    });

class _Api extends TracksApi {
  _Api(this._get);
  final Future<ClientTrackDto> Function() _get;
  @override
  Future<ClientTrackDto> getTrack(String uuidId) => _get();
}

