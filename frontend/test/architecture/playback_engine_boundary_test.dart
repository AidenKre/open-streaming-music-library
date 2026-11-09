// SC-27: the PlaybackEngine API is free of just_audio types. Only the
// adapter (JustAudioEngine) talks to the plugin; the playback core and
// everything else in lib/ depend on the engine interface.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _adapter = 'lib/playback/just_audio_engine.dart';
const _interface = 'lib/playback/playback_engine.dart';
const _sessionAdapter = 'lib/playback/audio_session_port.dart';

/// Files in lib/ that import or export [package] (either quote style).
List<String> _referencing(String package, {required String except}) {
  final pattern = RegExp('^\\s*(import|export)\\s+[\'"]package:$package/',
      multiLine: true);
  return [
    for (final file in _dartFiles('lib'))
      if (file.path != except && pattern.hasMatch(file.readAsStringSync()))
        file.path,
  ];
}

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));

void main() {
  test('only the JustAudioEngine adapter imports just_audio', () {
    expect(File(_adapter).existsSync(), isTrue,
        reason: 'the adapter lives at $_adapter');
    expect(_referencing('just_audio', except: _adapter), isEmpty);
  });

  test('only the session port adapter imports audio_session', () {
    expect(File(_sessionAdapter).existsSync(), isTrue);
    expect(_referencing('audio_session', except: _sessionAdapter), isEmpty);
  });

  test('the engine interface declares an abstract interface class', () {
    expect(File(_interface).existsSync(), isTrue,
        reason: 'the interface lives at $_interface');
    final source = File(_interface).readAsStringSync();
    expect(source, contains('abstract interface class PlaybackEngine'));
    expect(source, isNot(contains('just_audio')));
    expect(source, isNot(contains('audio_session')));
  });

  // SC-05 (5B.1, D34): playback starts only through PlaybackRequests.submit;
  // the playback model has no request entry points of its own.
  test('the playback model declares none of the old entry points', () {
    final source =
        File('lib/playback/queue_player.dart').readAsStringSync();
    for (final legacy in [
      RegExp(r'Future<void> play\('),
      RegExp(r'\bplayFromQueue\('),
      RegExp(r'\bplayFromTrackList\('),
      RegExp(r'\bplayNext\('),
      RegExp(r'\baddToQueue\('),
    ]) {
      expect(legacy.hasMatch(source), isFalse, reason: legacy.pattern);
    }
  });

  // SC-05 invariant 9: one emit site; one admission path.
  test('only PlaybackRequests emits clicks and drives admission', () {
    const owner = 'lib/playback/playback_requests.dart';
    final allowed = {
      'clickRecorderProvider': {owner, 'lib/services/history/click_recorder.dart'},
      'ClickRecorder(': {'lib/services/history/click_recorder.dart'},
      'admitReplacement(': {owner, 'lib/playback/queue_player.dart'},
      'activatePreparedSession(': {owner, 'lib/playback/queue_player.dart'},
    };
    final offenders = [
      for (final file in _dartFiles('lib'))
        for (final MapEntry(key: pattern, value: owners) in allowed.entries)
          if (!owners.contains(file.path) &&
              file.readAsStringSync().contains(pattern))
            '${file.path}: $pattern',
    ];
    expect(offenders, isEmpty);
  });
}
