// Phase 8B.1b S5: the deletion preview (spec §4 para 3; DEV-8-06).
//  * The preview distinguishes missing master (confirmable, "Remove
//    missing-file catalog entry"), unknown UUID (not confirmable), existing
//    tombstone (already deleted) and conflicts/busy (refresh or remove
//    before confirming).
//  * A selected track whose revision is unknown (null, never 0) is never
//    confirmable until an explicit refresh takes the server's revision; the
//    server's `conflict` flag is not trusted for it.
//  * A target is ready only when the server's revision equals the base the
//    app selected (both known): the model does not take the server's word
//    "no conflict" for a revision that differs.
//  * The preview needs a live `library_tools` block with `server_delete`
//    (a cached block, an absent one, the switch off, offline or no session:
//    nothing is sent), and 1–100 distinct tracks.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/server_binding_gate.dart';

import '../../helpers/delete_jobs_harness.dart';

DeletionPreview _fromServer(
  List<DeletionCandidate> candidates,
  List<Map<String, dynamic>> targets,
) => DeletionPreview.fromServer(
  candidates,
  DeletionPreviewDto.fromJson({'targets': targets}),
);

void main() {
  group('verdicts (pure rules)', () {
    test('a live track at the selected revision is ready', () {
      final p = _fromServer(
        [const DeletionCandidate('a', 7)],
        [previewTargetJson('a', 7)],
      );
      final t = p.targets.single;
      expect(t.verdict, PreviewVerdict.ready);
      expect(t.confirmable, isTrue);
      expect(t.refreshed, isNull);
      expect(t.uuid, 'a');
      expect(t.baseRevision, 7);
      expect(t.serverRevision, 7);
      expect(t.title, 'Title a');
      expect(t.masterExists, isTrue);
      expect(t.masterSize, 1000);
      expect(p.confirmable, isTrue);
      expect(p.count, 1);
    });

    test('a missing master is confirmable (catalog entry removal)', () {
      final t = _fromServer(
        [const DeletionCandidate('a', 3)],
        [previewTargetJson('a', 3, missingMaster: true)],
      ).targets.single;
      expect(t.verdict, PreviewVerdict.missingMaster);
      expect(t.confirmable, isTrue);
      expect(t.masterExists, isFalse);
      expect(t.masterSize, isNull);
    });

    test('a file the server could not check has its own verdict, never '
        '"ready" and never "missing", and stays confirmable (sign-off '
        'OPEN-8-07 row 2)', () {
      final p = _fromServer(
        [const DeletionCandidate('a', 3)],
        [previewTargetJson('a', 3, fileUnchecked: true)],
      );
      final t = p.targets.single;
      expect(t.verdict, PreviewVerdict.fileStatusUnknown);
      expect(t.confirmable, isTrue, reason: 'the server decides');
      expect(t.masterExists, isNull);
      expect(t.masterSize, isNull);
      expect(t.refreshed, isNull);
      expect(p.confirmable, isTrue);
    });

    test('a busy or changed track whose file could not be checked is busy or '
        'a conflict first', () {
      final p = _fromServer(
        const [DeletionCandidate('b', 1), DeletionCandidate('c', 1)],
        [
          previewTargetJson('b', 1, fileUnchecked: true, busy: true),
          previewTargetJson('c', 1, revision: 2, fileUnchecked: true, conflict: true),
        ],
      );
      expect(p.targets.map((t) => t.verdict), [
        PreviewVerdict.busy,
        PreviewVerdict.conflict,
      ]);
    });

    test('unknown, already deleted and busy are not confirmable and offer no '
        'refresh', () {
      final p = _fromServer(
        const [
          DeletionCandidate('u', 1),
          DeletionCandidate('d', 1),
          DeletionCandidate('b', 1),
        ],
        [
          previewTargetJson('u', 1, unknown: true),
          previewTargetJson('d', 1, revision: 9, alreadyDeleted: true),
          previewTargetJson('b', 1, busy: true),
        ],
      );
      expect(p.targets.map((t) => t.verdict), [
        PreviewVerdict.unknownTrack,
        PreviewVerdict.alreadyDeleted,
        PreviewVerdict.busy,
      ]);
      expect(p.targets.map((t) => t.confirmable), everyElement(isFalse));
      expect(p.targets.map((t) => t.refreshed), everyElement(isNull));
      expect(p.targets.first.serverRevision, isNull);
      expect(p.targets[1].serverRevision, 9);
      expect(p.confirmable, isFalse);
    });

    test('a conflict offers a refresh to the server revision', () {
      final t = _fromServer(
        [const DeletionCandidate('a', 3)],
        [previewTargetJson('a', 3, revision: 5, conflict: true)],
      ).targets.single;
      expect(t.verdict, PreviewVerdict.conflict);
      expect(t.confirmable, isFalse);
      expect(t.refreshed, const DeletionCandidate('a', 5));
    });

    test('a revision that differs is a conflict even if the server says none',
        () {
      final t = _fromServer(
        [const DeletionCandidate('a', 3)],
        [previewTargetJson('a', 3, revision: 4)],
      ).targets.single;
      expect(t.verdict, PreviewVerdict.conflict);
      expect(t.confirmable, isFalse);
      expect(t.refreshed, const DeletionCandidate('a', 4));
    });

    test('an unknown selected revision is never confirmable, whatever the '
        'server says; a refresh takes the server revision', () {
      for (final conflict in [false, true]) {
        final t = _fromServer(
          [const DeletionCandidate('a', null)],
          [previewTargetJson('a', 0, revision: 0, conflict: conflict)],
        ).targets.single;
        expect(t.verdict, PreviewVerdict.revisionUnknown, reason: '$conflict');
        expect(t.confirmable, isFalse);
        expect(t.baseRevision, isNull);
        expect(t.refreshed, const DeletionCandidate('a', 0));
      }
    });

    test('an unknown track with an unknown selected revision is unknown', () {
      final t = _fromServer(
        [const DeletionCandidate('a', null)],
        [previewTargetJson('a', 0, unknown: true)],
      ).targets.single;
      expect(t.verdict, PreviewVerdict.unknownTrack);
      expect(t.refreshed, isNull);
    });

    test('one target that is not confirmable blocks the whole preview', () {
      final p = _fromServer(
        const [DeletionCandidate('a', 1), DeletionCandidate('b', 2)],
        [previewTargetJson('a', 1), previewTargetJson('b', 2, busy: true)],
      );
      expect(p.targets.first.confirmable, isTrue);
      expect(p.confirmable, isFalse);
    });

    test('targets keep the selection order even if the server reorders them',
        () {
      final p = _fromServer(
        const [DeletionCandidate('a', 1), DeletionCandidate('b', 2)],
        [previewTargetJson('b', 2), previewTargetJson('a', 1)],
      );
      expect(p.targets.map((t) => t.uuid), ['a', 'b']);
      expect(p.targets.map((t) => t.serverRevision), [1, 2]);
    });

    test('an answer that does not name exactly the requested tracks is a '
        'FormatException', () {
      const candidates = [DeletionCandidate('a', 1), DeletionCandidate('b', 2)];
      for (final targets in [
        [previewTargetJson('a', 1)],
        [previewTargetJson('a', 1), previewTargetJson('c', 2)],
        [
          previewTargetJson('a', 1),
          previewTargetJson('b', 2),
          previewTargetJson('b', 2),
        ],
      ]) {
        expect(
          () => _fromServer(candidates, targets),
          throwsFormatException,
          reason: '$targets',
        );
      }
    });
  });

  group('8B.1c: isFor (a preview belongs to exactly one selection)', () {
    final p = _fromServer(
      [const DeletionCandidate('a', 1), const DeletionCandidate('b', null)],
      [previewTargetJson('a', 1), previewTargetJson('b', 0, revision: 5)],
    );

    test('the same tracks, order and revisions: yes', () {
      expect(
        p.isFor(const [DeletionCandidate('a', 1), DeletionCandidate('b', null)]),
        isTrue,
      );
    });

    test('another order, revision, or one track more or fewer: no', () {
      for (final other in const [
        [DeletionCandidate('b', null), DeletionCandidate('a', 1)],
        [DeletionCandidate('a', 2), DeletionCandidate('b', null)],
        [DeletionCandidate('a', 1), DeletionCandidate('b', 5)],
        [DeletionCandidate('a', 1)],
        [
          DeletionCandidate('a', 1),
          DeletionCandidate('b', null),
          DeletionCandidate('c', 1),
        ],
        <DeletionCandidate>[],
      ]) {
        expect(p.isFor(other), isFalse, reason: '$other');
      }
    });
  });

  group('DeleteJobsManager.preview', () {
    late DeleteJobsHarness h;
    setUp(() async => h = await DeleteJobsHarness.create());
    tearDown(() => h.dispose());

    test('sends the selection once the gate verifies; an unknown revision '
        'goes out as the placeholder 0 and comes back revisionUnknown',
        () async {
      await h.verify();
      final p = await h.preview([('a', 7), ('b', null)]);

      expect(h.api.calls, ['preview a,b']);
      expect(h.api.previews.single, {
        'targets': [
          {'uuid_id': 'a', 'base_revision': 7},
          {'uuid_id': 'b', 'base_revision': 0},
        ],
      });
      expect(p.targets.map((t) => t.verdict), [
        PreviewVerdict.ready,
        PreviewVerdict.revisionUnknown,
      ]);
      expect(p.confirmable, isFalse);
      expect(await h.submissions(), isEmpty, reason: 'a preview writes nothing');
    });

    final unavailable = <String, (void Function(DeleteJobsHarness), DeleteJobsUnavailableReason)>{
      'no block': ((h) => h.feature = null, DeleteJobsUnavailableReason.notAdvertised),
      'a cached block': (
        (h) => h.feature = const AdvertisedFeature(
          LibraryToolsFeature(version: 1, serverDelete: true, duplicateReview: false),
          fromCache: true,
        ),
        DeleteJobsUnavailableReason.notConfirmedLive,
      ),
      'the switch off': (
        (h) => h.feature = const AdvertisedFeature(
          LibraryToolsFeature(version: 1, serverDelete: false, duplicateReview: true),
          fromCache: false,
        ),
        DeleteJobsUnavailableReason.switchedOff,
      ),
      'offline': ((h) => h.offline = true, DeleteJobsUnavailableReason.offline),
    };
    for (final MapEntry(key: name, value: (setup, reason)) in unavailable.entries) {
      test('$name: unavailable (${reason.name}), nothing sent', () async {
        await h.verify();
        setup(h);
        await expectLater(
          h.preview([('a', 1)]),
          throwsA(isA<DeleteJobsUnavailable>()
              .having((e) => e.reason, 'reason', reason)),
        );
        expect(h.api.calls, isEmpty);
      });
    }

    // U22-FE-LIFECYCLE-B-08 (Phase 8 tail): every app resume (each window
    // refocus on the desktop) re-checks the server. A preview the person
    // asks for meanwhile waits for that check (bounded) instead of failing
    // "not connected" at once.
    group('a server check in flight (app resume)', () {
      Future<void> recheck() async {
        await h.verify();
        unawaited(h.gate.gate.startConnection('http://test'));
        await h.pump();
        expect(h.gate.gate.state, isA<BindingVerifying>());
      }

      DeleteJobsUnavailableReason? reasonOf(Object? e) =>
          e is DeleteJobsUnavailable ? e.reason : null;

      test('the preview waits for the check, then is sent', () async {
        await recheck();
        Object? error;
        DeletionPreview? result;
        final pending = h.preview([('a', 1)]).then(
          (p) => result = p,
          onError: (Object e) => error = e,
        );
        await h.pump();
        expect(error, isNull, reason: 'no "not connected" while it checks');
        expect(h.api.calls, isEmpty);
        h.gate.respond(h.instanceId);
        await pending;
        expect(error, isNull);
        expect(result, isNotNull);
        expect(h.api.calls, ['preview a']);
      });

      test('a failed check answers at once, as today: not connected',
          () async {
        await recheck();
        h.gate.fail(const SocketException('down'));
        await h.pump();
        expect(h.gate.gate.state, isA<BindingUnverified>());
        final error = await h
            .preview([('a', 1)])
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(reasonOf(error), DeleteJobsUnavailableReason.notConnected);
        expect(h.api.calls, isEmpty);
      });

      test('offline answers at once, as today', () async {
        await recheck();
        h.offline = true;
        final error = await h
            .preview([('a', 1)])
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(reasonOf(error), DeleteJobsUnavailableReason.offline);
        expect(h.api.calls, isEmpty);
        h.gate.respond(h.instanceId);
        await h.pump();
      });
    });

    test('no session binding: unavailable, nothing sent', () async {
      await h.verify();
      await h.binding.fence();
      await expectLater(
        h.preview([('a', 1)]),
        throwsA(isA<DeleteJobsUnavailable>().having(
          (e) => e.reason,
          'reason',
          DeleteJobsUnavailableReason.noSession,
        )),
      );
      expect(h.api.calls, isEmpty);
    });

    test('an empty, oversized or repeated selection is refused before '
        'anything is sent', () async {
      await h.verify();
      for (final selection in <List<(String, int?)>>[
        [],
        [for (var i = 0; i < 101; i++) ('t$i', 1)],
        [('a', 1), ('a', 2)],
      ]) {
        await expectLater(
          h.preview(selection),
          throwsArgumentError,
          reason: '${selection.length}',
        );
      }
      expect(h.api.calls, isEmpty);

      await h.preview([for (var i = 0; i < 100; i++) ('t$i', 1)]);
      expect(h.api.calls, hasLength(1), reason: '100 is the limit, allowed');
    });

    test('a 403 library_delete_disabled from the server is passed on as is',
        () async {
      await h.verify();
      h.api.onPreview = (_) async =>
          throw apiError(403, 'library_delete_disabled', retryable: false);
      await expectLater(
        h.preview([('a', 1)]),
        throwsA(isA<ApiException>()
            .having((e) => e.errorCode, 'code', 'library_delete_disabled')),
      );
      expect(h.api.calls, ['preview a']);
    });
  });
}
