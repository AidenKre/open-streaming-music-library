// Refactor APP-DUP (A.9 leftover, the owner: "follow the recommendation"):
// characterization of the Possible duplicates page's "reload when the
// connection is verified again", before the block it shares with Manage
// library becomes one helper. A read that fails fast as not connected waits
// once (no polling) for the binding to verify; then only what needs it is
// read again. The rest of this behaviour is in duplicates_controller_test
// ("binding unverified") and duplicates_quiet_reread_test.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../../helpers/fake_library_tools_api.dart';
import 'duplicates_test_support.dart';

/// Counts the page's waits for verification; the test ends each one.
class _CountedWaits extends FakeLibraryToolsApi {
  final waits = <Completer<void>>[];

  @override
  Future<void> whenVerified() {
    final w = Completer<void>();
    waits.add(w);
    return w.future;
  }

  /// The binding verifies: fail-fast reads pass, and every wait ends.
  void verify() {
    bindingVerified = true;
    for (final w in waits) {
      if (!w.isCompleted) w.complete();
    }
  }
}

void main() {
  late DupHarness h;
  late _CountedWaits api;

  setUp(() {
    api = _CountedWaits();
    h = DupHarness(api: api);
    h.pages['open']![null] = dupPage([dupPair('a1', 'b1')]);
  });

  tearDown(() => h.dispose());

  test('two refused reads wait once; once verified each is read again once',
      () async {
    api.bindingVerified = false;
    await h.open();
    expect(h.dup.summaryLoad, DuplicatesLoad.needsConnection);
    expect(h.dup.listLoad, DuplicatesLoad.needsConnection);
    // A Retry while waiting is refused again and adds no wait.
    await h.dup.refresh();
    await pumpEventQueue();
    expect(api.waits, hasLength(1));
    expect(api.calls, isEmpty);

    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('duplicateSummary'), hasLength(1));
    expect(api.callsOf('listDuplicates'), hasLength(1));
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);
    expect(h.dup.listLoad, DuplicatesLoad.loaded);
  });

  test('only the list was refused: only the list is read again', () async {
    await h.open();
    expect(api.callsOf('duplicateSummary'), hasLength(1));
    api.bindingVerified = false;
    h.dup.setFilter(DuplicatesFilter.dismissed);
    await pumpEventQueue();
    expect(h.dup.listLoad, DuplicatesLoad.needsConnection);
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);

    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('duplicateSummary'), hasLength(1));
    expect(api.callsOf('listDuplicates'), [
      'listDuplicates open null',
      'listDuplicates dismissed null',
    ]);
    expect(h.dup.listLoad, DuplicatesLoad.loaded);
  });

  test('a refused quiet re-read keeps the header and reads it again, '
      'quietly, once verified', () async {
    await h.open();
    final shown = h.dup.header;
    expect(shown, isNotNull);
    api.bindingVerified = false;
    h.sync.runOnce();
    await pumpEventQueue();
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);
    expect(identical(h.dup.header, shown), isTrue);
    expect(api.waits, hasLength(1));

    final loads = <DuplicatesLoad>[];
    h.dup.addListener(() => loads.add(h.dup.summaryLoad));
    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('duplicateSummary'), hasLength(2));
    expect(api.callsOf('listDuplicates'), hasLength(1));
    expect(loads, isNot(contains(DuplicatesLoad.loading)));
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);
  });

  test('offline when the binding verifies: nothing is read (coming back '
      'online reloads)', () async {
    api.bindingVerified = false;
    await h.open();
    h.offline.set(true);
    await pumpEventQueue();
    api.verify();
    await pumpEventQueue();
    expect(api.calls, isEmpty);

    h.offline.set(false);
    await pumpEventQueue();
    expect(api.callsOf('duplicateSummary'), hasLength(1));
    expect(api.callsOf('listDuplicates'), hasLength(1));
  });

  test('a wait that ends in an error (the gate closed) reloads nothing; the '
      'next refused read waits again', () async {
    api.bindingVerified = false;
    await h.open();
    expect(api.waits, hasLength(1));
    api.waits.single.completeError(StateError('gate closed'));
    await pumpEventQueue();
    expect(api.calls, isEmpty);

    await h.dup.refresh();
    await pumpEventQueue();
    expect(api.waits, hasLength(2));
    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('duplicateSummary'), hasLength(1));
    expect(api.callsOf('listDuplicates'), hasLength(1));
  });
}
