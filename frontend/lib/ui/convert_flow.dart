import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/ui/widgets/convert_confirm_sheet.dart';
import 'package:frontend/ui/widgets/convert_target_sheet.dart';

/// Whether the per-track "Convert…" entry should be offered at all: online,
/// the server advertises the `convert` track action, and at least one target
/// is allowed for this track's source codec. (A pending edit is NOT checked
/// here -- [startConversion] gates on it with a snackbar after a fresh sync,
/// since the local pending state can be stale.)
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

/// Starts a master-type conversion for the track at [uuidId] -- the single
/// entry point shared by the per-track menu (`tracks_page.dart`) and the
/// Conversions page's Retry. Never trusts a possibly-stale in-memory
/// `TrackUI` the caller captured at build time.
///
/// Sequence: online + capability gate -> flush pending edits and await a
/// completed fresh `/changes` pull -> gate on no pending edit remaining for
/// this track -> re-read the track (its revision is only read now) -> pick
/// a target codec/bitrate (skipped when [presetCodec] is still allowed, e.g.
/// a Retry) -> irreversible confirm -> enqueue. A dismissed sheet bails
/// silently; every other bail-out shows a snackbar. Returns true when a job
/// was enqueued.
///
/// [context] and [ref] must outlive the flow (spanning a network sync and
/// two sheets): pass the PAGE's, never a per-row widget's, which can
/// unmount mid-flow (scrolled away, moved) and silently abort it.
///
/// At most one flow per track runs at a time: a second call for a [uuidId]
/// whose flow is still running (a double-tap on Convert…, or Convert… and
/// Retry together) returns false immediately.
Future<bool> startConversion(
  BuildContext context,
  WidgetRef ref,
  String uuidId, {
  String? presetCodec,
  int? presetBitrateKbps,
}) async {
  final running = _conversionFlowsInFlight[uuidId];
  if (running != null && running.mounted) return false;
  _conversionFlowsInFlight[uuidId] = context;
  try {
    return await _runConversionFlow(
      context,
      ref,
      uuidId,
      presetCodec: presetCodec,
      presetBitrateKbps: presetBitrateKbps,
    );
  } finally {
    if (identical(_conversionFlowsInFlight[uuidId], context)) {
      _conversionFlowsInFlight.remove(uuidId);
    }
  }
}

/// The context of each track's running [startConversion] flow. An entry
/// whose context has unmounted no longer blocks: a flow left awaiting a
/// sheet whose navigator was torn down never completes, and must not
/// disable Convert for that track for the rest of the session.
final _conversionFlowsInFlight = <String, BuildContext>{};

Future<bool> _runConversionFlow(
  BuildContext context,
  WidgetRef ref,
  String uuidId, {
  required String? presetCodec,
  required int? presetBitrateKbps,
}) async {
  void snack(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // Resolve everything reached through `ref` up front: these objects stay
  // valid across the awaits below even if the calling widget rebuilds.
  final syncNotifier = ref.read(trackSyncProvider.notifier);
  final jobsNotifier = ref.read(conversionJobsProvider.notifier);
  final db = ref.read(databaseProvider);
  final browse = ref.read(browseRepositoryProvider);

  if (ref.read(offlineModeProvider)) {
    snack("You're offline. Converting needs the server.");
    return false;
  }
  if (_isLoadedInPlayer(ref, uuidId)) {
    snack(convertWhilePlayingMessage);
    return false;
  }

  final synced = await syncNotifier.syncFresh();
  if (!context.mounted) return false;
  if (!synced) {
    snack("Couldn't sync with the server. Try again.");
    return false;
  }

  final pendingMode = await db.pendingWriteMode(uuidId);
  if (!context.mounted) return false;
  if (pendingMode != null) {
    snack("Finish syncing this track's pending edit before converting.");
    return false;
  }

  final current = await browse.getTrack(uuidId);
  if (!context.mounted) return false;
  if (current == null) {
    snack('This track is no longer in your library.');
    return false;
  }

  final appInfo = await ref.read(appInfoProvider.future);
  if (!context.mounted) return false;
  if (!_advertisesConvert(appInfo)) {
    snack("This server doesn't support conversion.");
    return false;
  }
  final allowedTargets = appInfo.conversion.allowedFor(current.codec);
  if (allowedTargets.isEmpty) {
    snack('No conversion targets are available for this track.');
    return false;
  }

  ConvertTargetChoice? choice = _presetChoice(
    allowedTargets,
    appInfo.conversion.bitratePresets,
    presetCodec,
    presetBitrateKbps,
  );
  choice ??= await showConvertTargetSheet(
    context,
    allowedTargets: allowedTargets,
    bitratePresets: appInfo.conversion.bitratePresets,
  );
  if (choice == null || !context.mounted) return false;

  final targetIsLossless = allowedTargets
      .firstWhere((t) => t.codec == choice!.codec)
      .isLossless;
  final confirmed = await showConvertConfirmSheet(
    context,
    sourceCodec: current.codec,
    sourceBitrateKbps: current.bitrateKbps,
    targetCodec: choice.codec,
    targetIsLossless: targetIsLossless,
    targetBitrateKbps: choice.bitrateKbps,
  );
  if (!confirmed || !context.mounted) return false;
  // Re-checked: playback may have started while the sheets were open.
  if (_isLoadedInPlayer(ref, uuidId)) {
    snack(convertWhilePlayingMessage);
    return false;
  }

  try {
    await jobsNotifier.enqueue(
      uuidId: current.uuidId,
      targetCodec: choice.codec,
      // Lossless targets never carry a bitrate (the server 422s one).
      targetBitrateKbps: targetIsLossless ? null : choice.bitrateKbps,
      baseRevision: current.revision,
    );
    return true;
  } catch (e) {
    if (e is ApiException && _errorCode(e) == 'job_active') {
      // Surface the job that's already running for this track.
      unawaited(jobsNotifier.refreshAll());
    }
    snack(conversionErrorMessage(e));
    return false;
  }
}

@visibleForTesting
const convertWhilePlayingMessage =
    'This track is loaded in the player. Stop or skip it before converting.';

/// TEMPORARY GUARD -- NOT A PERMANENT FIX. Converting the track this device
/// is playing swaps its master file mid-stream: the player keeps issuing
/// byte-range requests for offsets in the OLD file, which the server then
/// answers from the NEW one (416s, or bytes from the middle of a different
/// encoding -> noise/skips). Refusing to convert the current track (playing
/// or paused -- a paused track resumes with more range requests) covers the
/// common case only. It does NOT cover: another device streaming the track,
/// a job queued before playback started, the player's preloaded next track,
/// or Phase 1 master-file tag edits (same swap problem). The real fix is
/// versioned stream URLs (`?v=<revision>`, server rejects stale versions)
/// plus the player reloading the current source when its revision changes;
/// see the Phase 2 follow-ups. Remove this guard once that lands.
bool _isLoadedInPlayer(WidgetRef ref, String uuidId) =>
    ref.read(currentTrackProvider)?.uuidId == uuidId;

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
      return switch (_errorCode(error)) {
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
      final detail = _detailText(error);
      return detail != null
          ? "Can't convert: $detail"
          : 'The server rejected this conversion.';
    default:
      return 'Could not start the conversion.';
  }
}

Object? _detail(ApiException e) {
  try {
    final body = jsonDecode(e.message);
    if (body is Map) return body['detail'];
  } on FormatException {
    // Non-JSON body.
  }
  return null;
}

String? _errorCode(ApiException e) {
  final detail = _detail(e);
  if (detail is Map && detail['error'] is String) {
    return detail['error'] as String;
  }
  return null;
}

/// Flattens FastAPI's `detail` shapes (string, validation-error list, or an
/// object with a message) into one line.
String? _detailText(ApiException e) {
  final detail = _detail(e);
  if (detail is String && detail.isNotEmpty) return detail;
  if (detail is List) {
    final msgs = [
      for (final d in detail)
        if (d is Map && d['msg'] is String) d['msg'] as String,
    ];
    if (msgs.isNotEmpty) return msgs.join('; ');
  }
  if (detail is Map) {
    for (final key in const ['message', 'msg', 'error']) {
      final v = detail[key];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  return null;
}

/// Cancels [jobId], showing a snackbar instead of an uncaught async error
/// when the DELETE fails.
Future<void> cancelConversion(
  BuildContext context,
  WidgetRef ref,
  int jobId,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(conversionJobsProvider.notifier).cancel(jobId);
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(content: Text("Couldn't cancel the conversion. Try again.")),
    );
  }
}
