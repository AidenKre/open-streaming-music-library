// Phase 7 §7 para 3 and its offline paragraph: what the Uploads page shows
// per item (bytes, progress, status, error), the overall counts, and which
// actions each item offers in each state, online and not (SC-26: these rules
// are model rules, the page only renders them).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

const _mb = 1024 * 1024;

UploadIntentRecord _intent(
  String uuid,
  String state, {
  String? code,
  String? message,
  int? length = 10 * _mb,
  String name = 'song.flac',
  String batch = 'b-1',
  String? sha256,
}) => UploadIntentRecord(
  itemUuid: uuid,
  batchUuid: batch,
  parentItemUuid: null,
  selectionIndex: 0,
  displayName: name,
  lastState: state,
  lastErrorCode: code,
  lastErrorMessage: message,
  operationUuid: null,
  transferOperationUuid: null,
  reviewGeneration: null,
  draftJson: null,
  localBindingId: 'bind-1',
  createdAtMs: 0,
  updatedAtMs: 0,
  expectedLength: length,
  expectedSha256: sha256,
  descriptor: null,
);

UploadRow _row(
  String state, {
  String? code,
  UploadsAvailability availability = UploadsAvailability.available,
  Set<String> otherDeviceSending = const {},
  String? sha256,
}) => UploadsOverview.of(
  intents: [_intent('i', state, code: code, sha256: sha256)],
  progress: const {},
  availability: availability,
  otherDeviceSending: otherDeviceSending,
).rows.single;

const _allStates = [
  'allocating', 'allocated', 'transferring', 'receiving', 'validating',
  'review_ready', 'committing', 'imported', 'duplicate', 'expanded',
  'failed', 'duplicate_conflict', 'expired', 'cancelled', 'cancelling',
  'source_changed', 'needs_reselect', 'rejected', 'teleporting',
];

void main() {
  group('availability', () {
    const block = UploadsFeature(version: 1);
    test('a live block online is available', () {
      expect(
        uploadsAvailability(
          offline: false,
          blocked: ServerBlockedReason.none,
          feature: const AdvertisedFeature(block, fromCache: false),
        ),
        UploadsAvailability.available,
      );
    });
    test('a cached block or a block still loading is not network-usable', () {
      expect(
        uploadsAvailability(
          offline: false,
          blocked: ServerBlockedReason.none,
          feature: const AdvertisedFeature(block, fromCache: true),
        ),
        UploadsAvailability.cachedOnly,
      );
      expect(
        uploadsAvailability(
          offline: false,
          blocked: ServerBlockedReason.none,
          feature: null,
          featureLoading: true,
        ),
        UploadsAvailability.cachedOnly,
      );
    });
    test('no block: not advertised', () {
      expect(
        uploadsAvailability(
          offline: false,
          blocked: ServerBlockedReason.none,
          feature: null,
        ),
        UploadsAvailability.notAdvertised,
      );
    });
    test('offline wins over the block; blocked wins over offline', () {
      expect(
        uploadsAvailability(
          offline: true,
          blocked: ServerBlockedReason.none,
          feature: const AdvertisedFeature(block, fromCache: true),
        ),
        UploadsAvailability.offline,
      );
      for (final reason in [
        ServerBlockedReason.differentServer,
        ServerBlockedReason.signedOut,
      ]) {
        expect(
          uploadsAvailability(
            offline: true,
            blocked: reason,
            feature: const AdvertisedFeature(block, fromCache: false),
          ),
          UploadsAvailability.serverBlocked,
        );
      }
    });
  });

  group('actions per state, online', () {
    test('cancel: every unfinished item the server can still cancel', () {
      const cancellable = {
        'allocating', 'allocated', 'transferring', 'receiving',
        'validating', 'review_ready', 'failed', 'duplicate_conflict',
        'source_changed', 'needs_reselect', 'rejected',
      };
      for (final s in _allStates) {
        expect(_row(s).canCancel, cancellable.contains(s), reason: s);
      }
    });
    test('reselect only when the source was lost or changed', () {
      for (final s in _allStates) {
        expect(
          _row(s).canReselect,
          s == 'needs_reselect' || s == 'source_changed',
          reason: s,
        );
      }
    });
    // 7B.2d: a duplicate_conflict item needs a decision in the review
    // (Use existing track / Back to review), also after leaving the page.
    test('Review tags for ready items and items that need a duplicate '
        'decision', () {
      for (final s in _allStates) {
        expect(_row(s).canReviewTags,
            s == 'review_ready' || s == 'duplicate_conflict', reason: s);
      }
    });
    test('an unpacked ZIP lists its files', () {
      for (final s in _allStates) {
        expect(_row(s).canOpenChildren, s == 'expanded', reason: s);
      }
    });
    test('needs attention: failed, refused, or waiting for the user', () {
      const attention = {
        'failed', 'rejected', 'needs_reselect', 'source_changed',
        'duplicate_conflict',
      };
      for (final s in _allStates) {
        expect(_row(s).needsAttention, attention.contains(s), reason: s);
      }
      expect(
        _row('allocated', code: 'upload_slots_busy').needsAttention,
        isFalse,
      );
    });
  });

  // 7-R1-22: an adopted item whose bytes the server still needs can only
  // come from the device that picked it; this device offers Cancel only.
  // Sign-off s7-app-texts follow-up (owner 2026-11-17): the app checks
  // whether another device is sending the upload (UploadArrivals) instead
  // of hedging.
  group('another device is sending the upload', () {
    const sendingText = 'Another device is sending this upload.';
    const sendingStatus = 'Uploading from another device';

    test('a waiting row of an upload being sent: says so, Cancel stays, '
        'nothing about adding it again, no attention needed', () {
      final row = _row('on_other_device', otherDeviceSending: {'b-1'});
      // Review #5: the row itself is not arriving: it still waits.
      expect(row.statusText, 'Waiting for the file');
      expect(row.detailText, sendingText);
      expect(row.offersCancel, isTrue);
      expect(row.canCancel, isTrue);
      expect(row.offersRetry, isFalse);
      expect(row.offersReselect, isFalse);
      expect(row.needsAttention, isFalse);
    });

    test('the attention count agrees with the rows', () {
      final o = UploadsOverview.of(
        intents: [
          _intent('a', 'on_other_device'),
          _intent('b', 'on_other_device', batch: 'b-2'),
        ],
        progress: const {},
        availability: UploadsAvailability.available,
        otherDeviceSending: {'b-1'},
      );
      expect(o.counts.needsAttention, 1);
    });

    test('another upload being sent changes nothing here', () {
      final row = _row('on_other_device', otherDeviceSending: {'b-2'});
      expect(row.statusText, 'Waiting for the file');
      expect(row.needsAttention, isTrue);
    });

    test('a row this device did not pick that the server is receiving: '
        'another device is sending it, whatever was seen before', () {
      final row = _row('receiving');
      expect(row.statusText, sendingStatus);
      expect(row.detailText, sendingText);
      expect(row.offersCancel, isTrue);
      expect(row.needsAttention, isFalse);
    });

    test("this device's own transfer is unchanged", () {
      final row = _row('receiving', sha256: 'abc', otherDeviceSending: {'b-1'});
      expect(row.statusText, 'Uploading');
      expect(row.detailText, isNull);
      final waiting =
          _row('allocated', sha256: 'abc', otherDeviceSending: {'b-1'});
      expect(waiting.statusText, 'Queued');
      expect(waiting.detailText, isNull);
    });
  });

  test('an item waiting for its file from another device: plain words, '
      'Cancel only, needs attention', () {
    final row = _row('on_other_device');
    expect(row.statusText, 'Waiting for the file');
    // Sign-off s7-app-texts follow-up (owner 2026-11-17): nothing of this
    // upload is arriving (no other device sending it, or this device added
    // it and lost its record), so the true step, with no hedge.
    expect(row.detailText,
        "This device cannot find this file, so it can't send it. Cancel it "
        'and add it again.');
    expect(row.offersCancel, isTrue);
    expect(row.canCancel, isTrue);
    expect(row.offersReselect, isFalse);
    expect(row.offersRetry, isFalse);
    expect(row.offersReviewTags, isFalse);
    expect(row.offersChildren, isFalse);
    expect(row.sending, isFalse);
    expect(row.needsAttention, isTrue);
    expect(
      _row('on_other_device', availability: UploadsAvailability.offline)
          .canCancel,
      isFalse,
    );
  });

  test('what a state offers does not depend on the network (shown disabled '
      'with an explanation, never hidden)', () {
    for (final a in UploadsAvailability.values) {
      for (final s in _allStates) {
        final online = _row(s);
        final row = _row(s, availability: a);
        expect(row.offersCancel, online.canCancel, reason: '$a $s');
        expect(row.offersReselect, online.canReselect, reason: '$a $s');
        expect(row.offersReviewTags, online.canReviewTags, reason: '$a $s');
        expect(row.offersChildren, online.canOpenChildren, reason: '$a $s');
      }
    }
  });

  test('without network every network action is off, in every state', () {
    for (final a in [
      UploadsAvailability.offline,
      UploadsAvailability.serverBlocked,
      UploadsAvailability.cachedOnly,
      UploadsAvailability.notAdvertised,
    ]) {
      for (final s in _allStates) {
        final row = _row(s, availability: a);
        expect(
          [row.canCancel, row.canReselect, row.canReviewTags, row.canOpenChildren],
          everyElement(isFalse),
          reason: '$a $s',
        );
        // The cached status is still shown.
        expect(row.statusText, isNotEmpty);
      }
      final overview = UploadsOverview.of(
        intents: const [],
        progress: const {},
        availability: a,
      );
      expect(overview.canAddFiles, isFalse);
      expect(overview.unavailableText, isNotNull);
    }
  });

  test('the explanation for disabled actions', () {
    String? text(UploadsAvailability a) => UploadsOverview.of(
      intents: const [],
      progress: const {},
      availability: a,
    ).unavailableText;
    expect(text(UploadsAvailability.available), isNull);
    expect(text(UploadsAvailability.offline), 'Unavailable while offline');
    expect(
      text(UploadsAvailability.serverBlocked),
      'Unavailable while network features are paused',
    );
    expect(
      text(UploadsAvailability.cachedOnly),
      'Waiting for the server to answer',
    );
    expect(
      text(UploadsAvailability.notAdvertised),
      "This server doesn't offer uploads",
    );
  });

  group('rows', () {
    test('status and detail come from the one text function', () {
      final busy = _row('allocated', code: 'upload_slots_busy');
      expect(busy.statusText, 'Waiting for the server');
      final failed = UploadsOverview.of(
        intents: [
          _intent(
            'i',
            'failed',
            code: 'upload_write_failed',
            message: 'disk /srv/music/.uploads/abc full',
          ),
        ],
        progress: const {},
        availability: UploadsAvailability.available,
      ).rows.single;
      expect(failed.statusText, 'Failed');
      expect(failed.detailText, 'The server could not store the file.');
      // The server's raw message is never shown.
      expect(failed.detailText, isNot(contains('/srv')));
    });

    test('a sending item shows bytes sent of the total and a fraction', () {
      final row = UploadsOverview.of(
        intents: [_intent('i', 'transferring')],
        progress: const {'i': 3 * _mb},
        availability: UploadsAvailability.available,
      ).rows.single;
      expect(row.sending, isTrue);
      expect(row.sentBytes, 3 * _mb);
      expect(row.totalBytes, 10 * _mb);
      expect(row.fraction, closeTo(0.3, 1e-9));
      expect(row.sizeText, '3.0 MB of 10.0 MB');
    });

    test('a sending item with no progress yet: sent is unknown, not 0', () {
      final row = _row('transferring');
      expect(row.sending, isTrue);
      expect(row.sentBytes, isNull);
      expect(row.fraction, isNull);
      expect(row.sizeText, '10.0 MB');
    });

    test('an unknown total: no fraction, no invented size', () {
      final sending = UploadsOverview.of(
        intents: [_intent('i', 'transferring', length: null)],
        progress: const {'i': 3 * _mb},
        availability: UploadsAvailability.available,
      ).rows.single;
      expect(sending.totalBytes, isNull);
      expect(sending.fraction, isNull);
      expect(sending.sizeText, '3.0 MB sent');
      final idle = UploadsOverview.of(
        intents: [_intent('i', 'validating', length: null)],
        progress: const {},
        availability: UploadsAvailability.available,
      ).rows.single;
      expect(idle.sizeText, isNull);
    });

    test('items not sending show their size and no progress', () {
      for (final s in ['allocated', 'validating', 'review_ready', 'failed']) {
        final row = UploadsOverview.of(
          intents: [_intent('i', s)],
          // A stale progress entry for an item no longer sending is ignored.
          progress: const {'i': 5 * _mb},
          availability: UploadsAvailability.available,
        ).rows.single;
        expect(row.sending, isFalse, reason: s);
        expect(row.sentBytes, isNull, reason: s);
        expect(row.sizeText, '10.0 MB', reason: s);
      }
      expect(_row('receiving').sending, isTrue);
    });

    test('rows keep the intents order and identity', () {
      final overview = UploadsOverview.of(
        intents: [
          _intent('a', 'allocated', name: 'one.flac', batch: 'b-1'),
          _intent('b', 'review_ready', name: 'two.mp3', batch: 'b-2'),
        ],
        progress: const {},
        availability: UploadsAvailability.available,
      );
      expect([for (final r in overview.rows) r.itemUuid], ['a', 'b']);
      expect([for (final r in overview.rows) r.displayName], [
        'one.flac',
        'two.mp3',
      ]);
      expect(overview.rows.last.batchUuid, 'b-2');
    });
  });

  group('counts', () {
    test('every item lands in its group; total counts everything', () {
      final overview = UploadsOverview.of(
        intents: [
          for (final (i, s) in _allStates.indexed) _intent('i$i', s),
        ],
        progress: const {},
        availability: UploadsAvailability.available,
      );
      final c = overview.counts;
      expect(c.total, _allStates.length);
      // allocating allocated transferring receiving validating committing
      // cancelling
      expect(c.inProgress, 7);
      expect(c.readyForReview, 1);
      // failed duplicate_conflict source_changed needs_reselect rejected
      expect(c.needsAttention, 5);
      // imported duplicate expanded
      expect(c.done, 3);
      expect(c.cancelled, 1);
      expect(c.expired, 1);
    });

    test('summary text leaves out empty groups', () {
      const c = UploadCounts(
        total: 5,
        inProgress: 2,
        readyForReview: 0,
        needsAttention: 1,
        done: 2,
        cancelled: 0,
        expired: 0,
      );
      expect(c.summaryText, '5 files · 2 in progress · 1 needs attention · 2 done');
      const one = UploadCounts(
        total: 1,
        inProgress: 0,
        readyForReview: 1,
        needsAttention: 0,
        done: 0,
        cancelled: 0,
        expired: 0,
      );
      expect(one.summaryText, '1 file · 1 ready for review');
      const closed = UploadCounts(
        total: 3,
        inProgress: 0,
        readyForReview: 0,
        needsAttention: 2,
        done: 0,
        cancelled: 2,
        expired: 1,
      );
      expect(
        closed.summaryText,
        '3 files · 2 need attention · 2 cancelled · 1 expired',
      );
    });
  });

  group('limits', () {
    String? limits(UploadLimits? l) => UploadsOverview.of(
      intents: const [],
      progress: const {},
      availability: UploadsAvailability.available,
      limits: l,
    ).limitsText;

    test('known limits are stated', () {
      expect(
        limits(
          const UploadLimits(maxFilesPerBatch: 100, maxFileBytes: 250 * _mb),
        ),
        'Up to 100 files at a time, each up to 250.0 MB',
      );
    });
    test('an unknown limit says nothing, never 0 or unlimited', () {
      expect(
        limits(const UploadLimits(maxFileBytes: 250 * _mb)),
        'Each file up to 250.0 MB',
      );
      expect(
        limits(const UploadLimits(maxFilesPerBatch: 100)),
        'Up to 100 files at a time',
      );
      expect(limits(const UploadLimits()), isNull);
      expect(limits(null), isNull);
    });
  });

  // Review r1 #1: a stored `transferring` state without a network is not
  // "Uploading": nothing is moving.
  test('without network a transfer reads Paused, with no progress bar', () {
    for (final a in [
      UploadsAvailability.offline,
      UploadsAvailability.serverBlocked,
      UploadsAvailability.cachedOnly,
      UploadsAvailability.notAdvertised,
    ]) {
      for (final s in ['transferring', 'receiving']) {
        final row = UploadsOverview.of(
          intents: [_intent('i', s)],
          progress: const {'i': 3 * _mb},
          availability: a,
        ).rows.single;
        expect(row.statusText, 'Paused', reason: '$a $s');
        expect(row.sending, isFalse, reason: '$a $s');
        expect(row.sentBytes, isNull, reason: '$a $s');
        expect(row.sizeText, '10.0 MB', reason: '$a $s');
      }
    }
    expect(_row('transferring').statusText, 'Uploading');
  });

  // Sign-off OPEN-M-11 (Part N): under a failed server check nothing can move
  // either: a transfer reads Paused (the offline row state), while the page's
  // availability stays what it is (no offline banner: the app is not
  // offline).
  test('transfers paused (the server check failed): a transfer reads Paused, '
      'the availability is unchanged', () {
    for (final s in ['transferring', 'receiving']) {
      final overview = UploadsOverview.of(
        intents: [_intent('i', s)],
        progress: const {'i': 3 * _mb},
        availability: UploadsAvailability.available,
        transfersPaused: true,
      );
      final row = overview.rows.single;
      expect(row.statusText, 'Paused', reason: s);
      expect(row.sending, isFalse, reason: s);
      expect(row.sentBytes, isNull, reason: s);
      expect(overview.availability, UploadsAvailability.available);
    }
  });

  // Review r1 #10: whether network actions are on is a model value the
  // views read (the file list's Try again), not a view rule.
  test('network actions are on only when uploads are available', () {
    for (final a in UploadsAvailability.values) {
      expect(
        UploadsOverview.of(
          intents: const [],
          progress: const {},
          availability: a,
        ).networkActionsEnabled,
        a == UploadsAvailability.available,
        reason: '$a',
      );
    }
  });

  // TR-UPLOAD-03 (SC-22): the server's per-item `retryable` flag decides
  // whether a failed item offers Retry; the code list is only the fallback
  // while no flag is known (before the first listing, offline).
  group('TR-UPLOAD-03 Retry follows the server retryable flag', () {
    // Picked on this device (it has the digest, so the bytes), unless
    // [picked] is false (adopted: no digest).
    UploadRow failed(String code, {bool? retryable, bool picked = true}) =>
        UploadsOverview.of(
      intents: [
        _intent('i', 'failed', code: code, sha256: picked ? 'abc' : null),
      ],
      progress: const {},
      availability: UploadsAvailability.available,
      retryable: {'i': ?retryable},
    ).rows.single;

    test('retryable on the server: Retry, whatever the code', () {
      expect(failed('user_staged_quota_exceeded', retryable: true).offersRetry,
          isTrue);
      expect(failed('a_code_this_app_does_not_know', retryable: true)
          .canRetry, isTrue);
    });

    test('not retryable on the server: no Retry, even for a listed code', () {
      expect(failed('probe_timeout', retryable: false).offersRetry, isFalse);
    });

    test('no flag known: the code list, with the storage refusals of an '
        'archive', () {
      for (final code in [
        'probe_timeout',
        'probe_unavailable',
        'upload_source_missing',
        'upload_validation_failed',
        'user_staged_quota_exceeded',
        'staged_quota_exceeded',
        'insufficient_storage',
        'free_space_unknown',
        'upload_write_failed',
      ]) {
        expect(failed(code).offersRetry, isTrue, reason: code);
      }
      expect(failed('upload_invalid_audio').offersRetry, isFalse);
    });

    // Sign-off s7-app-texts review r1 #2: the server lost the received file;
    // its Retry puts the item back to waiting for the bytes, which only a
    // device that has them can send. Retry here would strand it.
    group('the server lost the received file', () {
      test('picked on this device: Retry, and the text says to try again',
          () {
        final row = failed('upload_source_missing', retryable: true);
        expect(row.offersRetry, isTrue);
        expect(row.detailText,
            'The server no longer has the received file. Try again to send '
            'it.');
      });

      test('not on this device: no Retry, Cancel, and the true step', () {
        final row =
            failed('upload_source_missing', retryable: true, picked: false);
        expect(row.offersRetry, isFalse);
        expect(row.canRetry, isFalse);
        expect(row.offersCancel, isTrue);
        // Review-8 #3: no "unless another device retries it": the device
        // that added it often can't (it lost its record, or its row never
        // learns of the failure).
        expect(row.detailText,
            'The server no longer has the received file, and this device '
            'cannot find it. Cancel it and add it again.');
      });

      // The two rules agree: a lost file is failed, not waiting, so another
      // device sending other files of the upload changes nothing on it.
      test('while another device sends other files of the upload: still the '
          'lost-file text, Cancel, no Retry', () {
        final row = UploadsOverview.of(
          intents: [
            _intent('i', 'failed', code: 'upload_source_missing'),
            _intent('j', 'on_other_device'),
          ],
          progress: const {},
          availability: UploadsAvailability.available,
          retryable: {'i': true},
          otherDeviceSending: {'b-1'},
        ).rows.first;
        expect(row.statusText, 'Failed');
        expect(row.detailText,
            'The server no longer has the received file, and this device '
            'cannot find it. Cancel it and add it again.');
        expect(row.offersRetry, isFalse);
        expect(row.offersCancel, isTrue);
        expect(row.needsAttention, isTrue);
      });

      test('not on this device, no flag known: no Retry either', () {
        expect(
            failed('upload_source_missing', picked: false).offersRetry,
            isFalse);
      });

      test('other retryable codes still offer Retry without the bytes here',
          () {
        expect(failed('probe_timeout', retryable: true, picked: false)
            .offersRetry, isTrue);
      });
    });
  });
}
