// Sign-off s7-app-texts item 2: the session event lines are also kept in a
// small file in the app's own support folder, so a release build keeps them:
// one timestamped line per event, the newest 200 lines, a failing write never
// affects the app, and a local reset removes the file.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/session_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late DateTime clock;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('osml-session-log-');
    clock = DateTime.utc(2026, 11, 17, 9, 30);
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  SessionEventLogFile log([Directory? at]) =>
      SessionEventLogFile(at ?? dir, now: () => clock);
  File logFile() => File(p.join(dir.path, 'session_events.log'));

  test('each event is one line: a UTC timestamp, a space, the message',
      () async {
    final l = log();
    await l.append('Stored sign-in dropped at launch: reason=no_binding');
    clock = clock.add(const Duration(seconds: 5));
    await l.append('Stored sign-in dropped at launch: reason=no_saved_address');
    expect(await logFile().readAsLines(), [
      '2026-11-17T09:30:00.000Z Stored sign-in dropped at launch: '
          'reason=no_binding',
      '2026-11-17T09:30:05.000Z Stored sign-in dropped at launch: '
          'reason=no_saved_address',
    ]);
  });

  test('a local clock reading is written in UTC', () async {
    clock = DateTime(2026, 11, 17, 9, 30);
    await log().append('event');
    final line = (await logFile().readAsLines()).single;
    expect(line, '${clock.toUtc().toIso8601String()} event');
    expect(line.split(' ').first, endsWith('Z'));
  });

  test('the next app start appends to the same file', () async {
    await log().append('first launch');
    await log().append('second launch');
    expect(await logFile().readAsLines(), [
      '2026-11-17T09:30:00.000Z first launch',
      '2026-11-17T09:30:00.000Z second launch',
    ]);
  });

  test('a message with a line break stays one line', () async {
    await log().append('one\ntwo\r\nthree\rfour');
    expect(await logFile().readAsLines(),
        ['2026-11-17T09:30:00.000Z one two three four']);
  });

  group('the cap', () {
    test('keeps the newest 200 lines, the oldest dropped', () async {
      final l = log();
      for (var i = 0; i < 205; i++) {
        await l.append('event $i');
      }
      final lines = await logFile().readAsLines();
      expect(lines, hasLength(200));
      expect(lines.first, '2026-11-17T09:30:00.000Z event 5');
      expect(lines.last, '2026-11-17T09:30:00.000Z event 204');
    });

    test('a full file from an earlier start drops its oldest line', () async {
      await logFile().writeAsString(
        [for (var i = 0; i < 200; i++) 'old $i'].join('\n'),
      );
      await log().append('new');
      final lines = await logFile().readAsLines();
      expect(lines, hasLength(200));
      expect(lines.first, 'old 1');
      expect(lines.last, '2026-11-17T09:30:00.000Z new');
    });
  });

  group('a failing write never affects the app', () {
    // A folder where the file should be: every write fails.
    Future<SessionEventLogFile> blocked() async {
      await Directory(logFile().path).create();
      return log();
    }

    test('append completes and throws nothing', () async {
      final l = await blocked();
      await expectLater(l.append('event'), completes);
      await expectLater(l.append('another'), completes);
      await expectLater(l.idle(), completes);
    });

    test('the session event sink throws nothing', () async {
      final l = await blocked();
      final c = ProviderContainer(
        overrides: [sessionEventLogFileProvider.overrideWithValue(l)],
      );
      addTearDown(c.dispose);
      expect(() => c.read(sessionEventLogProvider)('event'), returnsNormally);
      await expectLater(l.idle(), completes);
    });
  });

  group('the session event sink', () {
    test('writes each event to the file as well', () async {
      final l = log();
      final c = ProviderContainer(
        overrides: [sessionEventLogFileProvider.overrideWithValue(l)],
      );
      addTearDown(c.dispose);
      c.read(sessionEventLogProvider)(
        'Stored sign-in dropped at launch: reason=no_binding',
      );
      await l.idle();
      expect(await logFile().readAsLines(), [
        '2026-11-17T09:30:00.000Z Stored sign-in dropped at launch: '
            'reason=no_binding',
      ]);
    });

    test('without a log file (tests, previews) writes no file', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(() => c.read(sessionEventLogProvider)('event'), returnsNormally);
      expect(await dir.list().toList(), isEmpty);
    });
  });

  group('a local reset', () {
    test('removes the file', () async {
      final l = log();
      await l.append('event');
      expect(logFile().existsSync(), isTrue);
      expect(l.resetPriority, ResetPriority.deleteFiles);
      await l.resetLocalState();
      expect(logFile().existsSync(), isFalse);
    });

    test('with no file yet does nothing and throws nothing', () async {
      await expectLater(log().resetLocalState(), completes);
      expect(logFile().existsSync(), isFalse);
    });

    test('a write queued before the reset does not bring the file back',
        () async {
      final l = log();
      final pending = l.append('event');
      await l.resetLocalState();
      await pending;
      expect(logFile().existsSync(), isFalse);
    });

    // Review r1 #6/#8: an undeletable log must not fail the wipe (a failed
    // wipe keeps the pending-reset marker and blocks every connect); the
    // file holds nothing that names a user, so it is left, and later
    // events are still written.
    test('a delete that fails is ignored, and later events are written',
        () async {
      final l = log();
      await l.append('before');
      await Process.run('chmod', ['555', dir.path]);
      addTearDown(() => Process.run('chmod', ['755', dir.path]));
      await expectLater(l.resetLocalState(), completes);
      expect(logFile().existsSync(), isTrue, reason: 'the delete was refused');
      await Process.run('chmod', ['755', dir.path]);
      await l.append('after');
      await expectLater(l.idle(), completes);
      expect(await logFile().readAsLines(), [
        '2026-11-17T09:30:00.000Z before',
        '2026-11-17T09:30:00.000Z after',
      ]);
    });

    test('an event after the reset starts a new file', () async {
      final l = log();
      await l.append('before');
      await l.resetLocalState();
      await l.append('after');
      expect(await logFile().readAsLines(),
          ['2026-11-17T09:30:00.000Z after']);
    });
  });
}
