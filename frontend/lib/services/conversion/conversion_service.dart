import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';

/// A conversion target the user picked (or a still-valid preset): the
/// target codec, plus a bitrate when the codec is lossy (null for a lossless
/// target).
@immutable
class ConvertTargetChoice {
  final String codec;
  final int? bitrateKbps;

  const ConvertTargetChoice({required this.codec, required this.bitrateKbps});
}

/// What the conversion flow knows about a track after its fresh sync: the
/// source the confirmation names, the revision the job is based on, and
/// what the server allows.
class ConversionDraft {
  const ConversionDraft({
    required this.uuidId,
    required this.sourceCodec,
    required this.sourceBitrateKbps,
    required this.revision,
    required this.allowedTargets,
    required this.bitratePresets,
  });

  final String uuidId;
  final String? sourceCodec;
  final double? sourceBitrateKbps;
  final int? revision;
  final List<ConversionTargetInfo> allowedTargets;
  final List<int> bitratePresets;

  bool isLossless(String codec) =>
      allowedTargets.firstWhere((t) => t.codec == codec).isLossless;
}

/// The model's verdict on starting a conversion (SC-26: the rules live
/// here; the view only shows sheets and messages).
sealed class ConversionPrep {
  const ConversionPrep();
}

/// Not possible now; [message] is shown to the user.
final class ConversionRefused extends ConversionPrep {
  const ConversionRefused(this.message);
  final String message;
}

/// The user must pick a target ([ConversionDraft.allowedTargets]).
final class ConversionNeedsTarget extends ConversionPrep {
  const ConversionNeedsTarget(this.draft);
  final ConversionDraft draft;
}

/// A preset target is still allowed: confirm it without asking (Retry).
final class ConversionReady extends ConversionPrep {
  const ConversionReady(this.draft, this.choice);
  final ConversionDraft draft;
  final ConvertTargetChoice choice;
}

/// The conversion rules (SC-26 model; formerly `ui/convert_flow.dart`).
class ConversionService {
  ConversionService(this._ref);

  final Ref _ref;

  /// Online + not loaded in the player + a fresh completed sync + no pending
  /// edit for the track + the track still exists + the server advertises
  /// convert with an allowed target. A valid preset skips the target pick.
  ///
  /// Never trusts a possibly-stale in-memory track: the revision the job is
  /// based on is only read after the fresh sync.
  Future<ConversionPrep> prepare(
    String uuidId, {
    String? presetCodec,
    int? presetBitrateKbps,
  }) async {
    // Resolve everything reached through the ref up front.
    final syncNotifier = _ref.read(trackSyncProvider.notifier);
    final db = _ref.read(databaseProvider);
    final browse = _ref.read(browseRepositoryProvider);

    if (_ref.read(offlineModeProvider)) {
      return const ConversionRefused(
        "You're offline. Converting needs the server.",
      );
    }
    if (_isLoadedInPlayer(uuidId)) {
      return const ConversionRefused(convertWhilePlayingMessage);
    }

    if (!await syncNotifier.syncFresh()) {
      return const ConversionRefused(
        "Couldn't sync with the server. Try again.",
      );
    }

    if (await db.pendingWriteMode(uuidId) != null) {
      return const ConversionRefused(
        "Finish syncing this track's pending edit before converting.",
      );
    }

    final current = await browse.getTrack(uuidId);
    if (current == null) {
      return const ConversionRefused(
        'This track is no longer in your library.',
      );
    }

    final appInfo = await _ref.read(appInfoProvider.future);
    if (!_advertisesConvert(appInfo)) {
      return const ConversionRefused(
        "This server doesn't support conversion.",
      );
    }
    final allowedTargets = appInfo.conversion.allowedFor(current.codec);
    if (allowedTargets.isEmpty) {
      return const ConversionRefused(
        'No conversion targets are available for this track.',
      );
    }

    final draft = ConversionDraft(
      uuidId: current.uuidId,
      sourceCodec: current.codec,
      sourceBitrateKbps: current.bitrateKbps,
      revision: current.revision,
      allowedTargets: allowedTargets,
      bitratePresets: appInfo.conversion.bitratePresets,
    );
    final choice = _presetChoice(
      allowedTargets,
      appInfo.conversion.bitratePresets,
      presetCodec,
      presetBitrateKbps,
    );
    return choice == null
        ? ConversionNeedsTarget(draft)
        : ConversionReady(draft, choice);
  }

  /// Enqueue the confirmed conversion. Null when enqueued, else the message
  /// to show (the player-loaded rule is re-checked here).
  Future<String?> submit(
    ConversionDraft draft,
    ConvertTargetChoice choice,
  ) async {
    // Re-checked: playback may have started while the sheets were open.
    if (_isLoadedInPlayer(draft.uuidId)) return convertWhilePlayingMessage;
    final jobsNotifier = _ref.read(conversionJobsProvider.notifier);
    try {
      await jobsNotifier.enqueue(
        uuidId: draft.uuidId,
        targetCodec: choice.codec,
        // Lossless targets never carry a bitrate (the server 422s one).
        targetBitrateKbps: draft.isLossless(choice.codec)
            ? null
            : choice.bitrateKbps,
        baseRevision: draft.revision,
      );
      return null;
    } catch (e) {
      if (e is ApiException && e.errorCode == 'job_active') {
        // Surface the job that's already running for this track.
        unawaited(jobsNotifier.refreshAll());
      }
      return conversionErrorMessage(e);
    }
  }

  /// Cancel [jobId]. Null when cancelled, else the message to show.
  Future<String?> cancel(int jobId) async {
    try {
      await _ref.read(conversionJobsProvider.notifier).cancel(jobId);
      return null;
    } catch (_) {
      return "Couldn't cancel the conversion. Try again.";
    }
  }

  /// TEMPORARY GUARD -- NOT A PERMANENT FIX. Converting the track this
  /// device is playing swaps its master file mid-stream: the player keeps
  /// issuing byte-range requests for offsets in the OLD file, which the
  /// server then answers from the NEW one (416s, or bytes from the middle of
  /// a different encoding -> noise/skips). Refusing to convert the current
  /// track (playing or paused -- a paused track resumes with more range
  /// requests) covers the common case only. It does NOT cover: another
  /// device streaming the track, a job queued before playback started, the
  /// player's preloaded next track, or Phase 1 master-file tag edits (same
  /// swap problem). The real fix is versioned stream URLs (`?v=<revision>`,
  /// server rejects stale versions) plus the player reloading the current
  /// source when its revision changes; see the Phase 2 follow-ups. Remove
  /// this guard once that lands.
  bool _isLoadedInPlayer(String uuidId) =>
      _ref.read(currentTrackProvider)?.uuidId == uuidId;
}

/// Whether the per-track "Convert…" entry should be offered at all: online,
/// the server advertises the `convert` track action, and at least one target
/// is allowed for this track's source codec. (A pending edit is NOT checked
/// here -- [ConversionService.prepare] gates on it after a fresh sync, since
/// the local pending state can be stale.)
bool canConvertTrack({
  required bool isOffline,
  required AppInfo? appInfo,
  required String? codec,
}) {
  if (isOffline || appInfo == null) return false;
  if (!_advertisesConvert(appInfo)) return false;
  return appInfo.conversion.allowedFor(codec).isNotEmpty;
}

bool _advertisesConvert(AppInfo appInfo) =>
    appInfo.entity('track')?.actions.contains('convert') ?? false;

@visibleForTesting
const convertWhilePlayingMessage =
    'This track is loaded in the player. Stop or skip it before converting.';

/// [presetCodec]/[presetBitrateKbps] as a choice, if still valid for this
/// track and server; null means "ask the user".
ConvertTargetChoice? _presetChoice(
  List<ConversionTargetInfo> allowed,
  List<int> presets,
  String? presetCodec,
  int? presetBitrateKbps,
) {
  if (presetCodec == null) return null;
  final target = allowed.where((t) => t.codec == presetCodec).firstOrNull;
  if (target == null) return null;
  if (target.isLossless) {
    return ConvertTargetChoice(codec: target.codec, bitrateKbps: null);
  }
  if (presetBitrateKbps == null || !presets.contains(presetBitrateKbps)) {
    return null;
  }
  return ConvertTargetChoice(
    codec: target.codec,
    bitrateKbps: presetBitrateKbps,
  );
}

/// User-facing text for a failed `POST /jobs`. Never shows the raw
/// `ApiException(...)` string.
String conversionErrorMessage(Object error) {
  if (error is NetworkException) {
    return "Couldn't reach the server. Try again.";
  }
  if (error is! ApiException) return 'Could not start the conversion.';
  switch (error.statusCode) {
    case 409:
      return switch (error.errorCode) {
        'job_active' => 'A conversion for this track is already in progress.',
        'target_exists' =>
          "A file already exists at the converted file's location.",
        'pending_recovery' =>
          'The server is still finishing a previous change to this track. '
              'Try again later.',
        _ => 'This track changed on the server. Try again.',
      };
    case 404:
      return 'Track or its file was not found on the server.';
    case 507:
      return 'Not enough disk space on the server.';
    case 503:
      return 'The server is busy. Try again in a moment.';
    case 422:
      final detail = error.detailMessage;
      return detail != null
          ? "Can't convert: $detail"
          : 'The server rejected this conversion.';
    default:
      return 'Could not start the conversion.';
  }
}

final conversionServiceProvider = Provider<ConversionService>(
  ConversionService.new,
);
