import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/playback/playback_issue_bus.dart';

void main() {
  test('published issues reach every listener in order', () async {
    final bus = PlaybackIssueBus();
    addTearDown(bus.dispose);
    final a = <PlaybackIssue>[];
    final b = <PlaybackIssue>[];
    bus.issues.listen(a.add);
    bus.issues.listen(b.add);
    bus
      ..publish(const LocalFileMissing('t1', '/one'))
      ..publish(const LocalFileMissing('t2', '/two'));
    await pumpEventQueue();
    expect(a, const [LocalFileMissing('t1', '/one'), LocalFileMissing('t2', '/two')]);
    expect(b, a);
  });

  test('issues are not buffered for later listeners or after dispose',
      () async {
    final bus = PlaybackIssueBus();
    bus.publish(const LocalFileMissing('early', '/x'));
    final seen = <PlaybackIssue>[];
    bus.issues.listen(seen.add);
    await pumpEventQueue();
    expect(seen, isEmpty);
    bus.dispose();
    bus.publish(const LocalFileMissing('late', '/y'));
    await pumpEventQueue();
    expect(seen, isEmpty);
  });
}
