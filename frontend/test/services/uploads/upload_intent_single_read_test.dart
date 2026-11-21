// An action on one upload item reads that one
// intent by its key, with the sign-in in the WHERE, not every intent of the
// sign-in. With 1,000 intents stored, Cancel and the review's draft read
// one row; a row of another sign-in is still never acted on.
import 'package:drift/drift.dart' show QueryExecutor, QueryInterceptor, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/upload_manager_harness.dart';

/// Counts the rows SELECTs on `upload_intents` return while [counting].
class _IntentRowCounter extends QueryInterceptor {
  bool counting = false;
  int rows = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runSelect(executor, statement, args);
    if (counting && statement.contains('upload_intents')) {
      rows += result.length;
    }
    return result;
  }
}

NewUploadIntent _new(String uuid) => NewUploadIntent(
  itemUuid: uuid,
  batchUuid: 'b-1',
  selectionIndex: 0,
  displayName: '$uuid.flac',
  descriptor: UploadSourceDescriptor(
    path: '/music/$uuid.flac',
    length: 3,
    sha256: 'ab' * 32,
  ),
);

void main() {
  late UploadHarness h;
  late _IntentRowCounter counter;

  setUp(() async {
    counter = _IntentRowCounter();
    h = await UploadHarness.create(interceptor: counter);
    h.offline = true; // no pass reads anything
    await h.store.insertAll(h.token, [
      for (var i = 0; i < 1000; i++) _new('i-$i'),
    ], state: 'allocated');
  });
  tearDown(() => h.dispose());

  test('Cancel on one item of 1,000 reads one intent row', () async {
    counter.counting = true;
    await h.manager.cancel('i-500');
    counter.counting = false;
    expect(counter.rows, 1);
    expect((await h.states())['i-500'], 'cancelling');
    expect((await h.states())['i-499'], 'allocated');
  });

  test("the review's draft of one item of 1,000 reads one intent row",
      () async {
    await h.store.update(
      h.token,
      ['i-500'],
      draftJson: const Value('{"v":1,"edits":{"title":"x"}}'),
    );
    final review = UploadReview(
      api: h.api,
      intents: h.store,
      binding: h.binding,
      manager: h.manager,
      decisions: UploadDuplicateDecisions(),
    );
    counter.counting = true;
    final draft = await review.draftOf('i-500');
    counter.counting = false;
    expect(counter.rows, 1);
    expect(draft.values, {'title': 'x'});
  });

  /// A row of another sign-in, with a draft.
  Future<void> insertOther() => h.db
      .into(h.db.uploadIntents)
      .insert(
        UploadIntentsCompanion.insert(
          itemUuid: 'other-1',
          batchUuid: 'b-2',
          selectionIndex: 0,
          displayName: 'other-1.flac',
          lastState: 'review_ready',
          draftJson: const Value('{"v":1,"edits":{"title":"x"}}'),
          localBindingId: 'another-sign-in',
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  test('Cancel writes nothing to a row of another sign-in', () async {
    await insertOther();
    await h.manager.cancel('other-1');
    final row = await h.db
        .customSelect(
          "SELECT last_state, updated_at FROM upload_intents "
          "WHERE item_uuid = 'other-1'",
        )
        .getSingle();
    expect(row.data, {'last_state': 'review_ready', 'updated_at': 1});
  });

  test("the review never shows the draft of another sign-in's row", () async {
    await insertOther();
    final review = UploadReview(
      api: h.api,
      intents: h.store,
      binding: h.binding,
      manager: h.manager,
      decisions: UploadDuplicateDecisions(),
    );
    expect((await review.draftOf('other-1')).isEmpty, isTrue);
  });
}
