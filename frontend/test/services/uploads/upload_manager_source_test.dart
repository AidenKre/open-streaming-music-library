// 7B.1d S7: the selected file between selection and transfer (spec §7
// para 1–2; plan O7 / DEV-7-04; 7B.1c traps 1 and 5). Before each PUT the
// file is opened again: one that can't be read needs to be selected again
// ("Reselect file to retry"), one whose length changed can't match the
// allocation (`source_changed`); neither sends anything. A source that
// changes or disappears during the PUT ends that transfer for good (the
// last chunk is withheld, so the server keeps the allocation) and is never
// sent again on its own. `reselect` accepts only the same bytes (length and
// digest), and a deliberate re-send gets a fresh transfer operation id.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/upload_manager_harness.dart';

void main() {
  late UploadHarness h;

  setUp(() async {
    h = await UploadHarness.create();
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: false,
    );
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> row(String item) async =>
      (await h.intents()).firstWhere((r) => r['item_uuid'] == item);

  /// Adds a.flac (u-2) and b.flac (u-3) while the gate is unverified.
  Future<(FileUploadSource, FileUploadSource)> addTwo() async {
    final a = await h.file('a.flac', 'abc');
    final b = await h.file('b.flac', 'abcd');
    await h.manager.addFiles([a, b]);
    return (a, b);
  }

  test('a file that can no longer be read needs reselecting; nothing is '
      'sent for it and the next file takes the slot', () async {
    final (a, _) = await addTwo();
    File(a.path).deleteSync();
    await h.verify();

    expect((await row('u-2'))['last_state'], UploadIntentState.needsReselect);
    expect(h.api.calls.where((c) => c.endsWith(' u-2') && !c.startsWith('allocate')),
        isEmpty);
    expect([for (final p in h.api.openPuts) p.itemUuid], ['u-3']);
  });

  test('a file whose length changed is a changed source; nothing is sent',
      () async {
    final (a, _) = await addTwo();
    File(a.path).writeAsStringSync('abcdef');
    await h.verify();

    expect((await row('u-2'))['last_state'], UploadIntentState.sourceChanged);
    expect(h.api.puts.where((p) => p.itemUuid == 'u-2'), isEmpty);
  });

  test('a source that changes during the PUT ends the transfer for good; it '
      'is not sent again on its own', () async {
    await addTwo();
    await h.verify();
    final op = (await row('u-2'))['transfer_operation_uuid'];
    h.api.openPuts.single.fail(const UploadSourceChanged(SourceChange.digest));
    await h.pump();

    expect((await row('u-2'))['last_state'], UploadIntentState.sourceChanged);
    final sub = (await h.submissions())
        .firstWhere((s) => s['operation_uuid'] == op);
    expect(sub['state'], 'rejected');

    h.clock.advance(const Duration(hours: 1));
    h.timers.fire();
    await h.pump();
    expect(h.api.puts.where((p) => p.itemUuid == 'u-2'), hasLength(1));
  });

  test('a source that disappears during the PUT needs reselecting',
      () async {
    await addTwo();
    await h.verify();
    h.api.openPuts.single.fail(const UploadSourceUnavailable());
    await h.pump();

    expect((await row('u-2'))['last_state'], UploadIntentState.needsReselect);
    h.clock.advance(const Duration(hours: 1));
    h.timers.fire();
    await h.pump();
    expect(h.api.puts.where((p) => p.itemUuid == 'u-2'), hasLength(1));
  });

  test('reselecting the same bytes (another path) resumes the upload under '
      'a fresh transfer operation id', () async {
    await addTwo();
    await h.verify();
    final oldOp = (await row('u-2'))['transfer_operation_uuid'];
    h.api.openPuts.single.fail(const UploadSourceUnavailable());
    await h.pump();
    h.api.openPuts.single.complete(); // u-3 finishes, the slot is free

    final copy = await h.file('copy-of-a.flac', 'abc');
    final outcome = await h.manager.reselect('u-2', copy);
    await h.pump();

    expect(outcome, ReselectOutcome.accepted);
    final r = await row('u-2');
    expect(r['last_state'], isIn({'allocated', 'transferring'}));
    expect(r['transfer_operation_uuid'], isNot(oldOp));
    expect(r['transfer_operation_uuid'], isNotNull);
    expect([for (final p in h.api.openPuts) p.itemUuid], ['u-2']);
    final stored = await h.db
        .customSelect(
          "SELECT source_descriptor_json FROM upload_intents "
          "WHERE item_uuid = 'u-2'",
        )
        .getSingle();
    expect(stored.data['source_descriptor_json'] as String,
        contains('copy-of-a.flac'));
  });

  test('reselecting different bytes is refused and leaves the row as it '
      'was', () async {
    final (a, _) = await addTwo();
    File(a.path).deleteSync();
    await h.verify();
    final before = await row('u-2');

    final other = await h.file('other.flac', 'xyz');
    expect(await h.manager.reselect('u-2', other),
        ReselectOutcome.differentFile);
    final longer = await h.file('longer.flac', 'abcd');
    expect(await h.manager.reselect('u-2', longer),
        ReselectOutcome.differentFile);
    expect(await row('u-2'), before);
  });

  test('reselect is only for a file that needs it', () async {
    await addTwo();
    await h.verify();
    h.api.openPuts.single.complete(state: 'validating');
    await h.pump();

    final copy = await h.file('copy.flac', 'abc');
    expect(await h.manager.reselect('u-2', copy), ReselectOutcome.notNeeded);
    expect((await row('u-2'))['last_state'], 'validating');
  });

  test('a changed source can be replaced by reselecting the original bytes',
      () async {
    final (a, _) = await addTwo();
    File(a.path).writeAsStringSync('abcdef');
    await h.verify();
    expect((await row('u-2'))['last_state'], UploadIntentState.sourceChanged);

    final original = await h.file('restored.flac', 'abc');
    expect(await h.manager.reselect('u-2', original), ReselectOutcome.accepted);
  });
}
