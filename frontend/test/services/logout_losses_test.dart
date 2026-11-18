// signoff-8-logout-warning (DEV-7-22 + DEV-8-14, user 2026-11-14: "warn
// first"). Logging out gives the sign-in a new local token; the upload and
// deletion work kept under the old token is never sent afterwards. Before the
// token changes, one rule counts that work for the current sign-in:
//  * uploads picked on this device whose bytes the server doesn't have yet
//    (the Disconnect rule: allocating, allocated, transferring, receiving,
//    needs_reselect, source_changed);
//  * not a failed upload: the server keeps its file, and Retry works after
//    signing in again (review R2-1);
//  * review tags typed but not confirmed (a draft with a touched field on a
//    reviewable row: review_ready, duplicate_conflict);
//  * confirmed reviews not yet answered (review_submitted);
//  * cancels not yet answered (cancelling);
//  * deletions not yet answered (the Disconnect rule: the targets of this
//    sign-in's prepared / sent / ambiguous track_deletion submissions), split
//    into never sent (prepared: the user deletes again) and maybe received
//    (sent / ambiguous: the server may still run them).
// Round 3 (user 2026-11-14): short lines naming the things, no instructions.
// A count that cannot be read is unknown, never zero.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';

const _draft = '{"v":1,"edits":{"title":"Typed"}}';
const _emptyDraft = '{"v":1,"edits":{}}';
const _uncounted = 'Some unsent changes could not be counted.';

String _deletion(List<String> uuids) =>
    '{"targets":['
    '${uuids.map((u) => '{"uuid_id":"$u","base_revision":1}').join(',')}'
    '],"confirmed_count":${uuids.length}}';

class _UnreadableBinding extends ServerBindingRepository {
  _UnreadableBinding(super.db);
  @override
  Future<ServerBindingRecord?> current() async =>
      throw StateError('database is locked');
}

class _UnreadableSubmissions extends DurableSubmission {
  _UnreadableSubmissions({
    required super.db,
    required super.binding,
    required super.clock,
  });
  @override
  Future<List<SubmissionRecord>> unresolved({
    required String bindingToken,
    String? kind,
  }) async => throw StateError('database is locked');

  @override
  Future<List<SubmissionRecord>> unresolvedAll({String? kind}) async =>
      throw StateError('database is locked');
}

LogoutLosses _losses({
  int? uploads = 0,
  int? drafts = 0,
  int? reviews = 0,
  int? cancels = 0,
  int? deletions = 0,
  int? unconfirmed = 0,
}) => LogoutLosses(
  unsentUploads: uploads,
  reviewDrafts: drafts,
  unsentReviews: reviews,
  unsentCancels: cancels,
  unsentDeletions: deletions,
  unconfirmedDeletions: unconfirmed,
);

void main() {
  late AppDatabase db;
  late String token;
  final clock = FakeClock();

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
  });
  tearDown(() => db.close());

  LogoutLossCounter counter({
    ServerBindingRepository? binding,
    DurableSubmission? submissions,
  }) {
    final b = binding ?? ServerBindingRepository(db);
    return LogoutLossCounter(
      uploads: UploadLossReporter(
        intents: UploadIntentStore(db: db, binding: b, clock: clock),
        binding: b,
      ),
      deletions: DeleteJobsLossReporter(
        submissions:
            submissions ?? DurableSubmission(db: db, binding: b, clock: clock),
        binding: b,
      ),
    );
  }

  var n = 0;
  Future<void> intent(
    String state, {
    bool pickedHere = true,
    bool zipChild = false,
    String? draft,
    String? bindingToken,
  }) {
    n++;
    return db.customStatement(
      'INSERT INTO upload_intents (item_uuid, batch_uuid, parent_item_uuid, '
      'selection_index, display_name, expected_sha256, last_state, '
      'draft_json, local_binding_id, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1)',
      [
        'u-$n',
        'b-1',
        zipChild ? 'u-zip' : null,
        n,
        'f$n.flac',
        pickedHere && !zipChild ? 'abc' : null,
        state,
        draft,
        bindingToken ?? token,
      ],
    );
  }

  Future<void> deletion(
    String op,
    List<String> uuids, {
    String state = 'prepared',
    String? body,
    String? bindingToken,
  }) async {
    await db.customStatement(
      'INSERT INTO durable_submissions (operation_uuid, kind, '
      'local_binding_id, frozen_body_json, state, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, 1, 1)',
      [
        op,
        'track_deletion',
        bindingToken ?? token,
        body ?? _deletion(uuids),
        state,
      ],
    );
  }

  group('count', () {
    test('nothing pending: every count is zero and there is nothing to warn '
        'about', () async {
      final losses = await counter().count();
      expect(losses.unsentUploads, 0);
      expect(losses.reviewDrafts, 0);
      expect(losses.unsentReviews, 0);
      expect(losses.unsentCancels, 0);
      expect(losses.unsentDeletions, 0);
      expect(losses.unconfirmedDeletions, 0);
      expect(losses.isEmpty, isTrue);
      expect(losses.lines, isEmpty);
    });

    test('finished and server-held work is not counted', () async {
      for (final s in [
        'validating',
        'review_ready',
        'committing',
        'imported',
        'duplicate',
        'cancelled',
        'expired',
        'failed', // the server keeps the file; Retry needs nothing from here
        'rejected',
        'on_other_device',
      ]) {
        await intent(s);
      }
      // A failed item this device never had the file of.
      await intent('failed', pickedHere: false);
      // A reviewable row without a typed tag, or with an empty draft.
      await intent('review_ready', draft: _emptyDraft);
      await intent('duplicate_conflict');
      // A draft on an item that is no longer reviewable.
      await intent('imported', draft: _draft);
      await deletion('op-a', ['x'], state: 'accepted');
      await deletion('op-r', ['y'], state: 'rejected');
      expect((await counter().count()).isEmpty, isTrue);
    });

    test('counts unsent uploads picked on this device, by state', () async {
      for (final s in [
        'allocating',
        'allocated',
        'transferring',
        'receiving', // the server has part of it
        'needs_reselect',
        'source_changed',
      ]) {
        await intent(s);
      }
      // Bytes this device never had (an adopted item, a ZIP child).
      await intent('allocated', pickedHere: false);
      await intent('receiving', zipChild: true);
      final losses = await counter().count();
      expect(losses.unsentUploads, 6);
      expect(losses.isEmpty, isFalse);
    });

    test('counts typed review tags not yet confirmed, ZIP children and '
        'adopted items included', () async {
      await intent('review_ready', draft: _draft);
      await intent('duplicate_conflict', draft: _draft);
      await intent('review_ready', draft: _draft, zipChild: true);
      await intent('review_ready', draft: _draft, pickedHere: false);
      final losses = await counter().count();
      expect(losses.reviewDrafts, 4);
      expect(losses.unsentReviews, 0);
    });

    test('counts confirmed reviews and cancels the server has not answered',
        () async {
      await intent('review_submitted', draft: _draft); // a review, not a draft
      await intent('review_submitted', pickedHere: false);
      await intent('cancelling');
      await intent('cancelling', pickedHere: false);
      await intent('cancelling', zipChild: true);
      final losses = await counter().count();
      expect(losses.unsentReviews, 2);
      expect(losses.reviewDrafts, 0);
      expect(losses.unsentCancels, 3);
      expect(losses.unsentUploads, 0);
    });

    test('counts deletions as the Disconnect confirmation does (the tracks '
        'of unanswered deletions, an unreadable one as 1), split into never '
        'sent and maybe received', () async {
      await deletion('op-1', ['a', 'b']);
      await deletion('op-2', ['c'], state: 'sent');
      await deletion('op-3', ['d'], state: 'ambiguous');
      await deletion('op-4', [], body: 'not json');
      await deletion('op-5', ['e'], state: 'accepted');
      await deletion('op-6', ['f'], state: 'rejected');
      final losses = await counter().count();
      expect(losses.unsentDeletions, 3, reason: 'never sent: a, b, op-4');
      expect(losses.unconfirmedDeletions, 2, reason: 'maybe received: c, d');
      expect(losses.unsentUploads, 0);
    });

    // Round 3: an ended session's records are kept on this device until the
    // same user's login takes them over (or a removal or reset): they count.
    test("records kept from an ended sign-in are counted", () async {
      await intent('allocated', bindingToken: 'old-token');
      await intent('review_ready', draft: _draft, bindingToken: 'old-token');
      await intent('cancelling', bindingToken: 'old-token');
      await intent('review_submitted', bindingToken: 'old-token');
      await deletion('op-1', ['a'], bindingToken: 'old-token');
      final losses = await counter().count();
      expect(losses.unsentUploads, 1);
      expect(losses.reviewDrafts, 1);
      expect(losses.unsentCancels, 1);
      expect(losses.unsentReviews, 1);
      expect(losses.unsentDeletions, 1);
    });

    test('without a sign-in there is nothing to lose', () async {
      await intent('allocated');
      await ServerBindingRepository(db).fence();
      expect((await counter().count()).isEmpty, isTrue);
    });

    test('an unreadable sign-in is unknown, not zero', () async {
      await intent('allocated');
      final losses = await counter(binding: _UnreadableBinding(db)).count();
      expect(losses.unsentUploads, isNull);
      expect(losses.reviewDrafts, isNull);
      expect(losses.unsentReviews, isNull);
      expect(losses.unsentCancels, isNull);
      expect(losses.unsentDeletions, isNull);
      expect(losses.unconfirmedDeletions, isNull);
      expect(losses.isEmpty, isFalse);
      expect(losses.lines, [_uncounted]);
    });

    test('unreadable deletions are unknown; the uploads are still counted',
        () async {
      await intent('allocated');
      final b = ServerBindingRepository(db);
      final losses = await counter(
        binding: b,
        submissions: _UnreadableSubmissions(db: db, binding: b, clock: clock),
      ).count();
      expect(losses.unsentUploads, 1);
      expect(losses.unsentDeletions, isNull);
      expect(losses.unconfirmedDeletions, isNull);
      expect(losses.isEmpty, isFalse);
      expect(losses.lines, ["1 upload that didn't finish", _uncounted]);
    });

    test('the scope provider counts the scope database', () async {
      await intent('allocated');
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
        ],
      );
      addTearDown(c.dispose);
      final losses = await c.read(logoutLossCounterProvider).count();
      expect(losses.unsentUploads, 1);
    });
  });

  group('lines', () {
    test('one short line per kind of thing, singular', () {
      expect(
        _losses(
          uploads: 1,
          drafts: 1,
          reviews: 1,
          cancels: 1,
          deletions: 1,
          unconfirmed: 1,
        ).lines,
        [
          "1 upload that didn't finish",
          'Tags typed for 1 upload',
          '1 upload confirmed in Review, not yet answered',
          '1 upload being cancelled',
          '1 track deletion',
          "1 track deletion the server hasn't confirmed",
        ],
      );
    });

    test('plural', () {
      expect(
        _losses(
          uploads: 2,
          drafts: 4,
          reviews: 5,
          cancels: 6,
          deletions: 7,
          unconfirmed: 8,
        ).lines,
        [
          "2 uploads that didn't finish",
          'Tags typed for 4 uploads',
          '5 uploads confirmed in Review, not yet answered',
          '6 uploads being cancelled',
          '7 track deletions',
          "8 track deletions the server hasn't confirmed",
        ],
      );
    });

    test('zero kinds are left out', () {
      expect(_losses(uploads: 2, deletions: 1).lines, [
        "2 uploads that didn't finish",
        '1 track deletion',
      ]);
      expect(_losses().lines, isEmpty);
      expect(_losses().isEmpty, isTrue);
    });

    test('any unknown count adds the uncounted line once, last, and is not '
        'empty', () {
      final losses = _losses(uploads: null, unconfirmed: null, cancels: 1);
      expect(losses.lines, ['1 upload being cancelled', _uncounted]);
      expect(losses.isEmpty, isFalse);
      expect(_losses(drafts: null).isEmpty, isFalse);
      expect(_losses(deletions: null).lines, [_uncounted]);
    });
  });
}
