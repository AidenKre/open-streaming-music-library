import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/services/conversion/conversion_service.dart';
import 'package:frontend/ui/conversion_controller.dart';
import 'package:frontend/ui/widgets/convert_confirm_sheet.dart';
import 'package:frontend/ui/widgets/convert_target_sheet.dart';

export 'package:frontend/services/conversion/conversion_service.dart'
    show canConvertTrack, conversionErrorMessage, convertWhilePlayingMessage;

/// Starts a master-type conversion for the track at [uuidId] -- the single
/// entry point shared by the per-track menu (`tracks_page.dart`) and the
/// Conversions page's Retry. The rules (online, fresh sync, pending edit,
/// capabilities, presets) are the model's ([ConversionService.prepare]);
/// this view shows the target and confirm sheets and the messages. A
/// dismissed sheet bails silently; every other bail-out shows a snackbar.
/// Returns true when a job was enqueued.
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
  final controls = ref.read(conversionControlsProvider);
  bool isAlive() => context.mounted;

  void snack(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  final prep = await controls.begin(
    uuidId,
    isAlive: isAlive,
    presetCodec: presetCodec,
    presetBitrateKbps: presetBitrateKbps,
  );
  if (prep == null) return false;
  try {
    if (!context.mounted) return false;
    final ConversionDraft draft;
    final ConvertTargetChoice? choice;
    switch (prep) {
      case ConversionRefused(:final message):
        snack(message);
        return false;
      case ConversionNeedsTarget(draft: final d):
        draft = d;
        choice = await showConvertTargetSheet(
          context,
          allowedTargets: d.allowedTargets,
          bitratePresets: d.bitratePresets,
        );
      case ConversionReady(draft: final d, choice: final c):
        draft = d;
        choice = c;
    }
    if (choice == null || !context.mounted) return false;

    final confirmed = await showConvertConfirmSheet(
      context,
      sourceCodec: draft.sourceCodec,
      sourceBitrateKbps: draft.sourceBitrateKbps,
      targetCodec: choice.codec,
      targetIsLossless: draft.isLossless(choice.codec),
      targetBitrateKbps: choice.bitrateKbps,
    );
    if (!confirmed || !context.mounted) return false;

    final error = await controls.submit(draft, choice);
    if (error != null) {
      snack(error);
      return false;
    }
    return true;
  } finally {
    controls.end(uuidId, isAlive: isAlive);
  }
}

/// Cancels [jobId], showing a snackbar instead of an uncaught async error
/// when the cancel fails.
Future<void> cancelConversion(
  BuildContext context,
  WidgetRef ref,
  int jobId,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final error = await ref.read(conversionControlsProvider).cancel(jobId);
  if (error != null) {
    messenger?.showSnackBar(SnackBar(content: Text(error)));
  }
}
