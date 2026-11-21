import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Value, Variable;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/stream_uris.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/quality_presets.dart';

/// Why a single download attempt ended. Drives whether the caller marks the
/// job completed, re-queues it for retry, or fails it.
///
/// On [success], [sizeBytes] holds the number of bytes received. On
/// [otherFailure], [errorMessage] is the human-readable failure.
/// [authRequired] (a 401) is a wait, not a failure: the job stays queued.
class DownloadOutcome {
  final DownloadOutcomeKind kind;
  final int sizeBytes;
  final String? errorMessage;
  const DownloadOutcome._(this.kind, {this.sizeBytes = 0, this.errorMessage});

  static const cancelled = DownloadOutcome._(DownloadOutcomeKind.cancelled);
  static const networkFailure = DownloadOutcome._(
    DownloadOutcomeKind.networkFailure,
  );
  static const authRequired = DownloadOutcome._(
    DownloadOutcomeKind.authRequired,
  );
  static const notVerified = DownloadOutcome._(
    DownloadOutcomeKind.notVerified,
  );
  static DownloadOutcome success(int sizeBytes) =>
      DownloadOutcome._(DownloadOutcomeKind.success, sizeBytes: sizeBytes);
  static DownloadOutcome otherFailure(String message) => DownloadOutcome._(
    DownloadOutcomeKind.otherFailure,
    errorMessage: message,
  );
}

enum DownloadOutcomeKind {
  success,
  networkFailure,

  /// The server answered 401: signed out. No network-failure listener fires.
  authRequired,
  otherFailure,
  cancelled,

  /// The token client withheld the request because the server is not
  /// verified (sign-off OPEN-M-11); nothing was sent. A wait, not a failure.
  notVerified,
}

class _DownloadCancelled implements Exception {}

/// Runs the per-track HTTP download → file rename → DB commit pipeline.
///
/// The downloader is generation-agnostic itself: it accepts a
/// `generationCheck` callback that returns true while the work is still
/// valid (the caller bumps a generation counter when the user resets
/// downloads). The downloader bails out of the in-flight stream and any
/// commit windows whenever the check returns false.
///
/// Cancellation is also exposed via `registerCanceller` — the worker pool
/// stores the canceller so a reset can interrupt the response stream and
/// the cancel-in-flight tests can preempt before the rename.
class TrackDownloader {
  TrackDownloader({
    required AppDatabase db,
    required LocalCoverArtStore coverArtStore,
    required Future<Directory> Function() directoryProvider,
    required ApiClient apiClient,
    OwnedFileCleanup? ownedFileCleanup,
    void Function()? onOwnedCleanupPending,
    void Function()? onNetworkFailure,
  }) : _db = db,
       _ownedCleanup =
           ownedFileCleanup ??
           OwnedFileCleanup(db: db, documentsDirectory: directoryProvider),
       _onOwnedCleanupPending = onOwnedCleanupPending,
       _coverArtStore = coverArtStore,
       _directoryProvider = directoryProvider,
       _apiClient = apiClient,
       _onNetworkFailure = onNetworkFailure;

  final AppDatabase _db;
  final LocalCoverArtStore _coverArtStore;
  final Future<Directory> Function() _directoryProvider;
  final ApiClient _apiClient;
  final void Function()? _onNetworkFailure;
  final OwnedFileCleanup _ownedCleanup;
  final void Function()? _onOwnedCleanupPending;

  Directory? _downloadDir;

  /// An `X-Audio-Extension` value this downloader puts in a file name.
  static final RegExp _usableExtension = RegExp(r'^[A-Za-z0-9]{1,16}$');

  /// Test seam fired immediately before the partial→destination rename. Lets
  /// a test deterministically interleave a reset with the commit step so the
  /// rename-race fix can be regressed. Surface via
  /// [DownloadManager.testHookBeforeRename] which wraps this with
  /// `@visibleForTesting`.
  Future<void> Function(String uuidId)? testHookBeforeRename;

  /// Test seam fired between the rename and the DB write. Exercises the
  /// narrower window where a worker has produced a tracked file but not yet
  /// recorded it. Surface via [DownloadManager.testHookBeforeDbWrite] which
  /// wraps this with `@visibleForTesting`.
  Future<void> Function(String uuidId)? testHookBeforeDbWrite;

  /// Test seam fired after the row swap committed, before the commit's last
  /// check: a person's cancel landing here loses to the download.
  @visibleForTesting
  Future<void> Function(String uuidId)? testHookAfterRecord;

  /// Downloads one job. Returns the outcome.
  ///
  /// [generationCheck] is polled before each commit window; when it returns
  /// false the in-flight work is abandoned and any partial/destination files
  /// are cleaned up.
  ///
  /// [onProgress] receives fractions in [0.0, 1.0] as bytes stream in.
  ///
  /// [registerCanceller] is invoked once with a future-producing function
  /// that, when called, cancels the HTTP stream cleanly. [unregisterCanceller]
  /// is invoked once the stream has finished (regardless of outcome).
  ///
  /// [isCancelled] is the person's cancel of this job: it stops the work at
  /// every check up to the row swap; after the swap the download wins.
  Future<DownloadOutcome> download({
    required DownloadJob job,
    required bool Function() generationCheck,
    required void Function(double progress) onProgress,
    required void Function(Future<void> Function() canceller) registerCanceller,
    required void Function() unregisterCanceller,
    bool Function()? isCancelled,
  }) async {
    // Still wanted: no reset or fence, and not cancelled by the person
    // ([isCancelled], other-issues row 74). Only the commit's last check,
    // after the row swap, ignores a person's cancel ([_commitDownload]).
    bool live() => generationCheck() && !(isCancelled?.call() ?? false);
    // Guarded: an escaped exception would leave the job stuck `active`.
    final Directory dir;
    try {
      dir = await _ensureDownloadDir();
    } catch (e) {
      return DownloadOutcome.otherFailure(e.toString());
    }
    if (!live()) {
      return DownloadOutcome.cancelled;
    }

    // Snapshot the track's local revision + source codec BEFORE the request
    // is sent. These are the fallbacks for servers that don't send
    // `X-Track-Revision`/`X-Audio-Codec`: the revision must predate the bytes
    // (a `/changes` upsert landing mid-download must not get credited to an
    // old-master file), and the codec must be the one current at attempt time
    // rather than at enqueue time (a conversion can land in between).
    // Guarded like the request below: an escaped exception would leave the
    // worker pool's job stuck `active` forever.
    final ({int? revision, String? codec}) preRequest;
    try {
      preRequest = await _readTrackState(job.uuidId);
    } catch (e) {
      return DownloadOutcome.otherFailure(e.toString());
    }

    http.StreamedResponse response;
    try {
      response = await _apiClient.send(
        () => http.Request(
          'GET',
          buildTrackStreamUri(_apiClient.baseUrl, job.uuidId, quality: job.quality),
        ),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401) return DownloadOutcome.authRequired;
      return DownloadOutcome.otherFailure('HTTP ${e.statusCode}');
    } on NetworkException {
      // ApiClient already fired its onNetworkFailure hook for the exhausted
      // handshake; report defensively too in case it wasn't wired.
      _onNetworkFailure?.call();
      return DownloadOutcome.networkFailure;
    } on TokenWithheldException {
      return DownloadOutcome.notVerified;
    } catch (e) {
      // Defensive fallback for unexpected exceptions that escape ApiClient's
      // typed exceptions — without this, the worker pool never marks the job
      // failed and it stays stuck in `active`.
      return DownloadOutcome.otherFailure(e.toString());
    }
    if (!live()) {
      return DownloadOutcome.cancelled;
    }

    // Always use the server's X-Audio-Extension header for the saved extension.
    // The backend may return passthrough bytes even for a transcoded-quality
    // request (e.g. source is already at or below the requested bitrate), so
    // assuming `.m4a` for non-original would mislabel the file. The header
    // becomes part of the file name, so only a plain extension is used; a
    // missing or unusable one (a separator, `..`, empty) falls back to
    // 'audio'. Lower-cased: on a case-insensitive disk `.M4A` and `.m4a`
    // are one file, while the clean-up compares paths as strings.
    final header = response.headers['x-audio-extension'];
    final ext = header != null && _usableExtension.hasMatch(header)
        ? header.toLowerCase()
        : 'audio';

    // For replacement jobs we write to a distinct filename so a same-extension
    // replacement cannot disturb the old file before the DB swap commits.
    // Repeated re-quality on an already-replaced row would otherwise collide
    // on a fixed ".new" suffix, so include a microsecond stamp.
    final replacesFilePath = job.replacesFilePath;
    final isReplacement = replacesFilePath != null;
    final destination = File(
      p.join(
        dir.path,
        isReplacement
            ? '${job.uuidId}.new-${DateTime.now().microsecondsSinceEpoch}.$ext'
            : '${job.uuidId}.$ext',
      ),
    );
    final partial = File('${destination.path}.partial');

    try {
      if (await partial.exists()) await partial.delete();

      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = partial.openWrite();
      StreamSubscription<List<int>>? subscription;
      final streamDone = Completer<void>();
      registerCanceller(() async {
        await subscription?.cancel();
        if (!streamDone.isCompleted) {
          streamDone.completeError(_DownloadCancelled());
        }
      });
      try {
        subscription = response.stream.listen(
          (chunk) {
            if (!live()) {
              return;
            }
            sink.add(chunk);
            received += chunk.length;
            if (total > 0) {
              onProgress(received / total);
            }
          },
          onDone: () {
            if (!streamDone.isCompleted) {
              streamDone.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!streamDone.isCompleted) {
              streamDone.completeError(error, stackTrace);
            }
          },
          cancelOnError: true,
        );
        if (!live()) {
          await subscription.cancel();
          if (!streamDone.isCompleted) {
            streamDone.completeError(_DownloadCancelled());
          }
        }
        await streamDone.future;
        await sink.flush();
      } finally {
        unregisterCanceller();
        await sink.close();
      }

      if (!live()) {
        await _deleteIfExists(partial);
        return DownloadOutcome.cancelled;
      }

      // A body that ended early (or ran long) is never committed: a
      // truncated file would only fail later at playback, looking damaged
      // (review major 1). Unknown length (chunked, compressed) can't be
      // checked.
      final expected = response.contentLength;
      if (expected != null && expected >= 0 && received != expected) {
        await _deleteIfExists(partial);
        return DownloadOutcome.otherFailure(
            'Incomplete download: received $received of $expected bytes');
      }

      // Parse the actual bitrate the server served (may differ from source).
      final bitrateHeader = response.headers['x-audio-bitrate-kbps'];
      final downloadedBitrate = bitrateHeader != null
          ? int.tryParse(bitrateHeader)
          : null;

      final committed = await _commitDownload(
        uuidId: job.uuidId,
        partial: partial,
        destination: destination,
        generationCheck: live,
        fenceCheck: generationCheck,
        downloadedBitrate: downloadedBitrate,
        downloadedQuality: job.quality,
        downloadedCodec: resolveDownloadedCodec(
          headerCodec: response.headers['x-audio-codec'],
          quality: job.quality,
          sourceCodec: preRequest.codec,
          contentType: response.headers['content-type'],
        ),
        downloadedAtRevision: resolveDownloadedAtRevision(
          headerRevision: response.headers['x-track-revision'],
          preRequestRevision: preRequest.revision,
        ),
        received: received,
        replacesFilePath: job.replacesFilePath,
      );
      if (!committed) return DownloadOutcome.cancelled;

      // Try to grab the cover art too. We don't fail the whole job if this
      // fails — the audio is what matters for playback.
      await _downloadCoverArtForTrack(job.uuidId);

      return DownloadOutcome.success(received);
    } on _DownloadCancelled {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return DownloadOutcome.cancelled;
    } catch (e) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      // A drop after headers arrived doesn't surface through ApiClient (the
      // response stream was already handed to us), so classify it here: a
      // transport error re-queues for retry, anything else (e.g. a disk
      // write failure) is a genuine, permanent failure.
      if (e is SocketException ||
          e is OSError ||
          e is http.ClientException ||
          e is TimeoutException) {
        _onNetworkFailure?.call();
        return DownloadOutcome.networkFailure;
      }
      return DownloadOutcome.otherFailure(e.toString());
    }
  }

  /// Performs the partial→destination rename and the DB row update under a
  /// generation guard. Returns true on commit, false if the reset generation
  /// moved during the commit (in which case any state left on disk is cleaned
  /// up so a reset doesn't leak files or DB rows).
  ///
  /// When [replacesFilePath] is non-null this is a two-phase replacement:
  /// the old file and old DB row must survive any failure or cancellation
  /// before the DB swap. Only once the DB row points at the new path do we
  /// remove the old file. If a reset/fence fires between the DB swap and the
  /// old-file delete, this method still removes the old file before returning
  /// so the reset path doesn't leave a stranded sibling.
  Future<bool> _commitDownload({
    required String uuidId,
    required File partial,
    required File destination,
    required bool Function() generationCheck,
    required bool Function() fenceCheck,
    required int? downloadedBitrate,
    required String downloadedQuality,
    required String? downloadedCodec,
    required int downloadedAtRevision,
    required int received,
    String? replacesFilePath,
  }) async {
    // The commit window holds the destination's path lock, so a cleanup retry
    // for the same path waits for it. Late-branch destination files are
    // enqueued for durable cleanup (never deleted in place) and attempted
    // only after the lock is released (cleanRows takes the same lock).
    final step = await _ownedCleanup.withPathLock(destination.path, () async {
      final beforeRename = testHookBeforeRename;
      if (beforeRename != null) await beforeRename(uuidId);

      if (!generationCheck()) {
        await _deleteIfExists(partial);
        return const _CommitStep(committed: false);
      }

      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);

      final beforeDbWrite = testHookBeforeDbWrite;
      if (beforeDbWrite != null) await beforeDbWrite(uuidId);

      Future<_CleanupRows> enqueueLate({bool clearRow = false}) async {
        final token = (await ServerBindingRepository(_db).current())
            ?.localBindingId;
        final ids = await _db.transaction(() async {
          if (clearRow) {
            await (_db.update(_db.tracks)
                  ..where((t) => t.uuidId.equals(uuidId)))
                .write(clearedDownloadColumns);
          }
          return _ownedCleanup.enqueueInTransaction([
            destination.path,
          ], localBindingId: token);
        });
        return (ids: ids, token: token);
      }

      // Reset/fence happened between rename and DB write. The destination
      // file isn't referenced by any row yet. For replacement jobs we
      // deliberately leave the OLD file and OLD DB row intact: callers rely
      // on the invariant that a failed replacement preserves the working
      // copy.
      if (!generationCheck()) {
        return _CommitStep(committed: false, late: await enqueueLate());
      }

      // One transaction swaps the row and enqueues the files it stops
      // referencing: the replaced file and a superseded damaged copy
      // (decision 6), whose mark this write clears. Nothing is deleted here;
      // the rows are cleaned after the lock is released.
      final swapToken = (await ServerBindingRepository(_db).current())
          ?.localBindingId;
      // A record step that throws (its transaction rolled back) leaves the
      // renamed file referenced by no row: it goes to the durable clean-up
      // like a late commit, which keeps it if a row names it after all. If
      // even that fails, the file stays. The error is rethrown after the
      // clean-up attempt below.
      final ({int rows, List<int> ids}) swap;
      try {
        swap = await _db.transaction(() async {
          final damaged = (await (_db.select(_db.tracks)
                    ..where((t) => t.uuidId.equals(uuidId)))
                  .getSingleOrNull())
              ?.damagedFilePath;
          final rows =
              await (_db.update(_db.tracks)
                    ..where((t) => t.uuidId.equals(uuidId)))
                  .write(
                TracksCompanion(
                  damagedFilePath: const Value(null),
                  filePath: Value(destination.path),
                  downloadedBitrateKbps: Value(downloadedBitrate),
                  fileSizeBytes: Value(received),
                  downloadedQuality: Value(downloadedQuality),
                  downloadedAtRevision: Value(downloadedAtRevision),
                  downloadedCodec: Value(downloadedCodec),
                  staleDismissedAtRevision: const Value(null),
                ),
              );
          if (rows == 0) return (rows: 0, ids: const <int>[]);
          final superseded = {
            ?replacesFilePath,
            ?damaged,
          }..remove(destination.path);
          return (
            rows: rows,
            ids: await _ownedCleanup.enqueueInTransaction(
              superseded.toList(),
              localBindingId: swapToken,
            ),
          );
        });
      } catch (e, st) {
        _CleanupRows? late;
        try {
          late = await enqueueLate();
        } catch (_) {}
        return _CommitStep(committed: false, late: late, failure: (e, st));
      }
      final superseded = (ids: swap.ids, token: swapToken);
      if (swap.rows == 0) {
        return _CommitStep(
          committed: false,
          superseded: superseded,
          late: await enqueueLate(),
        );
      }
      final afterRecord = testHookAfterRecord;
      if (afterRecord != null) await afterRecord(uuidId);
      // After the swap only a reset or a delete fence undoes the download: a
      // person's cancel landing now loses (review F1), so a re-download never
      // ends with neither the old nor the new file.
      if (!fenceCheck()) {
        // The same transaction drops the reference and enqueues the file.
        return _CommitStep(
          committed: false,
          superseded: superseded,
          late: await enqueueLate(clearRow: true),
        );
      }
      return _CommitStep(committed: true, superseded: superseded);
    });
    // Cleanup runs only now, after the path lock is released (cleanRows takes
    // the same lock) and outside any transaction.
    final outcomes = <OwnedCleanupOutcome>[];
    for (final rows in [step.superseded, step.late]) {
      if (rows == null || rows.ids.isEmpty) continue;
      outcomes.addAll(
        (await _ownedCleanup.cleanRows(
          rows.ids,
          bindingToken: rows.token,
        )).values,
      );
    }
    if (outcomes.contains(OwnedCleanupOutcome.failed)) {
      _onOwnedCleanupPending?.call();
    }
    final failure = step.failure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
    return step.committed;
  }

  /// The track's local revision and source codec right now (both null for an
  /// unknown uuid).
  Future<({int? revision, String? codec})> _readTrackState(
    String uuidId,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT t.revision AS revision, tm.codec AS codec FROM tracks AS t '
          'LEFT JOIN trackmetadata AS tm ON tm.uuid_id = t.uuid_id '
          'WHERE t.uuid_id = ? LIMIT 1',
          variables: [Variable.withString(uuidId)],
        )
        .getSingleOrNull();
    return (
      revision: row?.readNullable<int>('revision'),
      codec: row?.readNullable<String>('codec'),
    );
  }

  /// The revision a just-downloaded file is current as of: the server's
  /// `X-Track-Revision` (the revision at the moment it served the bytes) when
  /// present, else the local revision read before the request was sent. Both
  /// err early -- a harmless false-positive stale -- never late. 0 when even
  /// that is unknown, so the first revision the track is seen at flags it
  /// (a null watermark would mean "never stale" forever).
  @visibleForTesting
  static int resolveDownloadedAtRevision({
    required String? headerRevision,
    required int? preRequestRevision,
  }) {
    final fromHeader = headerRevision == null
        ? null
        : int.tryParse(headerRevision.trim());
    return fromHeader ?? preRequestRevision ?? 0;
  }

  /// The codec actually written to disk. Prefers the server's `X-Audio-Codec`
  /// (the codec of the bytes it served). Fallback for servers that don't
  /// send it:
  /// * `original` quality is always a passthrough -> the source codec.
  /// * any other preset transcodes to AAC (served as `audio/mp4`) unless the
  ///   source's bitrate is already <= the preset, in which case the source is
  ///   passed through under its own MIME type. So `audio/mp4` means AAC
  ///   unless the source is itself AAC (a passthrough is indistinguishable
  ///   and is AAC either way). An ALAC source is lossless -- its bitrate is
  ///   never under a preset -- so at a preset it is always transcoded to AAC.
  ///   Anything else is the source codec.
  @visibleForTesting
  static String? resolveDownloadedCodec({
    required String? headerCodec,
    required String quality,
    required String? sourceCodec,
    required String? contentType,
  }) {
    final header = headerCodec?.trim().toLowerCase();
    if (header != null && header.isNotEmpty) return header;
    if (quality == originalQuality) return sourceCodec;
    final mime = contentType?.split(';').first.trim().toLowerCase();
    if (mime == 'audio/mp4') return 'aac';
    return sourceCodec;
  }

  Future<void> _downloadCoverArtForTrack(String uuidId) async {
    final row = await _db
        .customSelect(
          'SELECT cover_art_id, has_album_art FROM trackmetadata WHERE uuid_id = ? LIMIT 1',
          variables: [Variable.withString(uuidId)],
        )
        .getSingleOrNull();
    if (row == null) return;
    final coverArtId = row.readNullable<int>('cover_art_id');
    final hasAlbumArt = row.read<bool>('has_album_art');
    if (!hasAlbumArt || coverArtId == null) return;
    // Asked after any removal of this cover under way (a delete of another
    // download): a cover about to go is fetched again.
    if (await _coverArtStore.holds(coverArtId)) return;
    await _coverArtStore.download(coverArtId);
  }

  Future<Directory>? _dirPreparation;

  /// Resolves and creates the downloads folder and sweeps it once, sharing one
  /// in-flight future so the sweep never runs while this downloader's own job
  /// is writing. A failed preparation is not kept: the next call retries.
  Future<Directory> _ensureDownloadDir() {
    final cached = _downloadDir;
    if (cached != null) return Future.value(cached);
    final current = _dirPreparation;
    if (current != null) return current;
    // A preparation that is no longer current (a reset dropped it) must not
    // touch the shared state; its own caller still gets its result or error.
    late final Future<Directory> preparation;
    preparation = _prepareDownloadDir().then(
      (dir) {
        if (identical(_dirPreparation, preparation)) _downloadDir = dir;
        return dir;
      },
      onError: (Object e, StackTrace st) {
        if (identical(_dirPreparation, preparation)) _dirPreparation = null;
        Error.throwWithStackTrace(e, st);
      },
    );
    return _dirPreparation = preparation;
  }

  Future<Directory> _prepareDownloadDir() async {
    final base = await _directoryProvider();
    final dir = Directory(p.join(base.path, 'tracks'));
    await dir.create(recursive: true);
    await _sweepLeftovers(dir);
    return dir;
  }

  static const String _uuidPattern =
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
  static final RegExp _partialName = RegExp(
    '^$_uuidPattern\\.(?:new-\\d+\\.)?[A-Za-z0-9]+\\.partial\$',
  );
  static final RegExp _unrecordedReplacementName = RegExp(
    '^$_uuidPattern\\.new-\\d+\\.[A-Za-z0-9]+\$',
  );

  /// Removes this downloader's own leftovers (`<uuid>.<ext>.partial`,
  /// `<uuid>.new-<n>.<ext>.partial`, `<uuid>.new-<n>.<ext>`) from [dir].
  /// The sweep only FINDS candidates; the owned-file clean-up decides each
  /// unlink (inside the downloads folder, ordinary file, no track refers to
  /// it, size and modification time unchanged). A file is a candidate only
  /// when ALL hold: [dir] is a real directory (not a link); the entry is a
  /// regular file (not a link) listed non-recursively; its basename matches
  /// the patterns above; and no track row names it, by full path or by
  /// basename (the app's files folder can move). Rows are read once, first; if
  /// that fails nothing is done. Never fails the download.
  Future<void> _sweepLeftovers(Directory dir) async {
    try {
      // Fenced on the binding the sweep started under: a session that ends
      // while it runs must not have its finds enqueued under the next one.
      final token = (await ServerBindingRepository(_db).current())
          ?.localBindingId;
      if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final namedPaths = <String>{};
      final namedBasenames = <String>{};
      for (final path in await _db.ownedTrackFilePaths()) {
        namedPaths.add(path);
        namedBasenames.add(p.basename(path));
      }
      final entries = await dir.list(followLinks: false).toList();
      final candidates = <String>[];
      for (final entity in entries) {
        try {
          if (entity is! File) continue;
          if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
            continue;
          }
          final name = p.basename(entity.path);
          if (!_partialName.hasMatch(name) &&
              !_unrecordedReplacementName.hasMatch(name)) {
            continue;
          }
          if (namedPaths.contains(entity.path) ||
              namedBasenames.contains(name)) {
            continue;
          }
          candidates.add(entity.path);
        } catch (_) {}
      }
      if (candidates.isEmpty) return;
      // No path lock of ours is held here: the sweep runs before any job of
      // this downloader commits.
      final List<int> ids;
      if (token != null) {
        // A BindingFencedException (binding changed) ends the sweep via the
        // outer catch with nothing enqueued.
        ids = await ServerBindingRepository(_db).runFenced(
          token,
          () => _ownedCleanup.enqueueInTransaction(
            candidates,
            localBindingId: token,
          ),
        );
      } else {
        final enqueued = await _db.transaction(() async {
          if (await ServerBindingRepository(_db).current() != null) return null;
          return _ownedCleanup.enqueueInTransaction(
            candidates,
            localBindingId: null,
          );
        });
        if (enqueued == null) return;
        ids = enqueued;
      }
      final outcomes = await _ownedCleanup.cleanRows(ids, bindingToken: token);
      if (outcomes.values.contains(OwnedCleanupOutcome.failed)) {
        _onOwnedCleanupPending?.call();
      }
    } catch (e) {
      developer.log(
        'download sweep skipped: ${e.runtimeType}',
        name: 'TrackDownloader',
      );
    }
  }

  /// The reset's delete of the downloads (the owner, 2026-11-17: "route the
  /// reset through the same checks"). One transaction clears every track's
  /// download columns and queues each recorded file and kept damaged copy
  /// for the owned-file clean-up, which deletes only what it can prove is
  /// the app's own: inside the downloads folder (by path and after
  /// resolving links), an ordinary file (a link is never followed), its size
  /// and modification time as recorded. Then the downloads folder goes as a
  /// whole, with every entry left in it: the app's own folder; a link in it
  /// is removed as a link, never followed.
  ///
  /// A reset deletes nothing behind a link. When the downloads folder is
  /// itself a link, the clean-up is not asked to delete anything (the files
  /// behind it are not in the app's own folder): the queued rows are dropped,
  /// the link goes as a link, and the recorded and queued files behind it
  /// stay and are reported like any other file left.
  ///
  /// Files an earlier delete left queued for the clean-up are attempted too.
  /// A recorded or queued file that is still on the device afterwards
  /// (outside the folder, by path or through a link) is left where it is
  /// and reported once: this throws [DownloadsLeftByReset]. Its row no longer names it,
  /// so a rerun of the reset finds nothing to report.
  ///
  /// When the database step fails, the folder still goes and the failure is
  /// rethrown; where the folder is a link, the files behind it that the
  /// database records are reported as left instead ([DownloadsLeftByReset]),
  /// and when even they cannot be read the link stays, so the next run
  /// (the reset is incomplete) can still find and report them.
  ///
  /// A downloads folder, or a link in its place, still there after its
  /// removal throws a [FileSystemException], so the reset is incomplete and
  /// runs again at the next launch. Where this run also throws
  /// [DownloadsLeftByReset], that is reported first and the folder at the
  /// next run. A plain file in the folder's place is left and not reported.
  Future<void> deleteDownloadsForReset() async {
    // Whether the folder is a link decides what may be deleted, and only a
    // look that succeeded decides it. A look that fails here is tried again
    // after the database step and before anything is deleted; a failure
    // then ends the step with nothing deleted (the next run tries again).
    _FolderLook? look;
    try {
      look = await _lookAtDownloadsFolder();
    } catch (_) {}
    final linked = look?.linked ?? false;
    final String? token;
    final List<String> paths;
    List<int> ids;
    try {
      token = (await ServerBindingRepository(_db).current())?.localBindingId;
      (paths, ids) = await _db.transaction(() async {
        final recorded = await _db.ownedTrackFilePaths();
        await (_db.update(_db.tracks)
              ..where(
                (t) => t.filePath.isNotNull() | t.damagedFilePath.isNotNull(),
              ))
            .write(clearedDownloadColumns);
        // Files an earlier delete queued and no track names any more are
        // the previous user's too: attempted and looked for like the rest.
        final queued =
            await _db.select(_db.ownedFileCleanupEntries).get();
        final all = [...recorded, for (final r in queued) r.path];
        if (linked) {
          // Nothing behind the link is deleted: no row is left to try.
          await _db.delete(_db.ownedFileCleanupEntries).go();
          return (all, const <int>[]);
        }
        final newIds = await _ownedCleanup.enqueueInTransaction(
          recorded,
          localBindingId: token,
        );
        return (all, [...newIds, for (final r in queued) r.id]);
      });
    } catch (e, st) {
      if (look == null) {
        try {
          look = await _lookAtDownloadsFolder();
        } catch (_) {
          // Not settled: nothing is removed, the next run tries again.
          Error.throwWithStackTrace(e, st);
        }
      }
      if (look.linked) {
        final List<String> known;
        try {
          known = [
            ...await _db.ownedTrackFilePaths(),
            for (final r in await _db.select(_db.ownedFileCleanupEntries).get())
              r.path,
          ];
        } catch (_) {
          // The link stays: the next run can still find what is behind it.
          Error.throwWithStackTrace(e, st);
        }
        final left = await _removeFolderCountingLeft(look.folder, known);
        if (left > 0) {
          developer.log(
            'reset database step failed: ${e.runtimeType}',
            name: 'TrackDownloader',
          );
          throw DownloadsLeftByReset(left);
        }
        Error.throwWithStackTrace(e, st);
      }
      // The folder still goes; the failure is the reset's to report.
      await deleteDownloadDirectory();
      rethrow;
    }
    if (look == null) {
      // Looked at now, before anything is deleted; a failure ends the step.
      look = await _lookAtDownloadsFolder();
      if (look.linked) {
        // Nothing behind the link is deleted: no row is left to try.
        await _db.delete(_db.ownedFileCleanupEntries).go();
        ids = const [];
      }
    }
    if (ids.isNotEmpty) await _ownedCleanup.cleanRows(ids, bindingToken: token);
    final folder = look.folder;
    final left = await _removeFolderCountingLeft(folder, paths);
    // Left: the folder, or a link in its place, is still there. A plain
    // file named like the folder is not the app's and is never removed.
    final folderLeft = _removableFolderTypes.contains(
      await FileSystemEntity.type(folder, followLinks: false),
    );
    if (left > 0) throw DownloadsLeftByReset(left);
    if (folderLeft) {
      throw FileSystemException(
        'The downloads folder could not be removed',
        folder,
      );
    }
  }

  /// Removes the downloads [folder] ([deleteDownloadDirectory]) and returns
  /// how many of the recorded [paths] are still on the device outside it.
  /// Where each one really is (its folder's links resolved, the file itself
  /// not followed) is read before the folder goes; a file the folder's own
  /// removal took was the app's own and is not counted. Through a linked
  /// folder nothing is inside it: what is behind the link counts.
  Future<int> _removeFolderCountingLeft(
    String folder,
    List<String> paths,
  ) async {
    final recorded = [for (final path in paths) await _realLocation(path)];
    final root = await _realLocation(folder);
    await deleteDownloadDirectory();
    var left = 0;
    for (final path in recorded) {
      if (path == root || p.isWithin(root, path)) continue;
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        left++;
      }
    }
    return left;
  }

  /// The downloads folder's path and whether it is itself a link (read
  /// without following it). Throws when the app's files folder cannot be
  /// found.
  Future<_FolderLook> _lookAtDownloadsFolder() async {
    final folder = p.join((await _directoryProvider()).path, 'tracks');
    return (
      folder: folder,
      linked:
          await FileSystemEntity.type(folder, followLinks: false) ==
          FileSystemEntityType.link,
    );
  }

  /// [path] with its folder's links resolved; the last part is not followed.
  /// Unchanged when the folder cannot be resolved (it does not exist).
  static Future<String> _realLocation(String path) async {
    try {
      final folder = await Directory(p.dirname(path)).resolveSymbolicLinks();
      return p.join(folder, p.basename(path));
    } on FileSystemException {
      return p.normalize(path);
    }
  }

  /// What [deleteDownloadDirectory] removes in the downloads folder's place:
  /// the folder itself, or a link there (as a link).
  static const _removableFolderTypes = {
    FileSystemEntityType.directory,
    FileSystemEntityType.link,
  };

  /// Removes the entire downloads directory (including any partials). A link
  /// in its place (to a drive that is not mounted, say) is removed as a
  /// link, never followed: nothing behind it goes. Anything else there (a
  /// plain file) is not the app's folder and is left.
  Future<void> deleteDownloadDirectory() async {
    final path =
        _downloadDir?.path ??
        p.join((await _directoryProvider()).path, 'tracks');
    _downloadDir = null;
    _dirPreparation = null;
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        // Links inside are removed as links, never followed.
        await Directory(path).delete(recursive: true);
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      }
    } catch (_) {}
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}

/// The downloads folder as one successful look found it.
typedef _FolderLook = ({String folder, bool linked});

/// Clean-up rows a commit step enqueued, with the binding token they were
/// enqueued under.
typedef _CleanupRows = ({List<int> ids, String? token});

/// What one commit step under the path lock decided, for the clean-up and
/// the answer that follow once the lock is released.
class _CommitStep {
  const _CommitStep({
    required this.committed,
    this.superseded,
    this.late,
    this.failure,
  });

  /// The row now names the new file.
  final bool committed;

  /// The files the row swap stopped referencing (the replaced file, a
  /// superseded damaged copy); null when no swap ran.
  final _CleanupRows? superseded;

  /// The new file, enqueued because it ended up referenced by no row (a
  /// fence or reset, a vanished row, a failed record step); null otherwise.
  final _CleanupRows? late;

  /// A record step that threw: rethrown after the clean-up attempt.
  final (Object, StackTrace)? failure;
}

/// What the reset says about downloaded files it left on the device
/// (shown in the "Reset incomplete" dialog).
const downloadsLeftByResetMessage =
    'Downloaded files outside this app’s downloads folder were left where '
    'they are. The app will not delete them.';

/// A reset left recorded downloads it could not prove are the app's own:
/// [count] of them are still on the device.
class DownloadsLeftByReset implements Exception {
  const DownloadsLeftByReset(this.count);

  final int count;

  @override
  String toString() => downloadsLeftByResetMessage;
}
