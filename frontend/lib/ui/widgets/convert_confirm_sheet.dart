import 'package:flutter/material.dart';

import 'package:frontend/models/app_info.dart';

/// Irreversible-confirm bottom sheet for starting a conversion. This is NEW
/// UI, not a mirror of an existing widget -- the codebase has no
/// checkbox-gated confirm anywhere (the only other "irreversible action"
/// dialog, `master_write_confirm_dialog.dart`, is a plain `AlertDialog` with
/// no checkbox). It borrows the outer shell from `_confirmDisconnect`
/// (`settings_dialog.dart`) -- a bottom sheet, not a nested `AlertDialog`, so
/// a back-gesture dismissal can't accidentally pop the parent route -- and
/// adds a `StatefulBuilder`/`CheckboxListTile` gate on top, per the "I
/// understand" checkbox the conversion feature's settled decisions call for.
///
/// The warning copy is chosen from the format matrix (lossless/lossy source
/// x target, see [conversionWarning]); the checkbox gates Convert for every
/// conversion, since the original file is always replaced.
///
/// Returns `true` only if the user both checked the box and tapped Convert;
/// `false` for Cancel or dismissal.
Future<bool> showConvertConfirmSheet(
  BuildContext context, {
  required String? sourceCodec,
  required double? sourceBitrateKbps,
  required String targetCodec,
  required bool targetIsLossless,
  required int? targetBitrateKbps,
}) async {
  final bitratePart = targetBitrateKbps != null ? ' at ${targetBitrateKbps}kbps' : '';
  final warning = conversionWarning(
    sourceCodec: sourceCodec,
    sourceBitrateKbps: sourceBitrateKbps,
    targetCodec: targetCodec,
    targetIsLossless: targetIsLossless,
    targetBitrateKbps: targetBitrateKbps,
  );
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) {
          // Lives in this outer closure (not inside StatefulBuilder's own
          // builder) so it survives across the StatefulBuilder's rebuilds --
          // declaring it inside the inner builder would reset it to false
          // on every setState.
          var understood = false;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: StatefulBuilder(
                builder: (context, setState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Convert to ${targetCodec.toUpperCase()}$bitratePart?',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        warning.title,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: warning.severe
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(warning.body),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: understood,
                        onChanged: (v) =>
                            setState(() => understood = v ?? false),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('I understand this cannot be undone'),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: understood
                                ? () => Navigator.of(context).pop(true)
                                : null,
                            child: const Text('Convert'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ) ??
      false;
}

/// Headline + explanation for the confirm sheet, picked per the format
/// matrix. [severe] tints the headline (irreversible quality loss).
@immutable
class ConversionWarning {
  final String title;
  final String body;
  final bool severe;

  const ConversionWarning({
    required this.title,
    required this.body,
    this.severe = false,
  });
}

const _replacedNote = 'The original file is replaced and cannot be restored.';

/// Format-matrix warning for converting [sourceCodec] to [targetCodec].
/// Source losslessness comes from [isLosslessCodec]; an unrecognised source
/// gets a generic (still cautious) warning.
ConversionWarning conversionWarning({
  required String? sourceCodec,
  required double? sourceBitrateKbps,
  required String targetCodec,
  required bool targetIsLossless,
  required int? targetBitrateKbps,
}) {
  final target = targetCodec.toUpperCase();
  final sourceLossless = isLosslessCodec(sourceCodec);

  if (sourceLossless == null) {
    return ConversionWarning(
      title: 'This replaces the original file',
      body: targetIsLossless
          ? _replacedNote
          : 'Converting to lossy $target may permanently lose audio quality. '
                '$_replacedNote',
      severe: !targetIsLossless,
    );
  }

  final source = sourceCodec!.toUpperCase();
  if (sourceLossless && !targetIsLossless) {
    return ConversionWarning(
      title: 'Permanent quality loss',
      body: 'This converts your lossless $source original to lossy $target. '
          'The audio detail discarded by lossy encoding can never be '
          'recovered. $_replacedNote',
      severe: true,
    );
  }
  if (!sourceLossless && targetIsLossless) {
    return ConversionWarning(
      title: 'No quality is gained',
      body: 'The source is already lossy $source, so converting to lossless '
          '$target cannot restore any quality -- the file just gets much '
          'larger. $_replacedNote',
    );
  }
  if (sourceLossless && targetIsLossless) {
    return ConversionWarning(
      title: 'Lossless to lossless',
      body: 'No audio quality is lost converting $source to $target. '
          '$_replacedNote',
    );
  }

  // Lossy -> lossy.
  final sameCodec = sourceCodec.toLowerCase() == targetCodec.toLowerCase();
  final current = sourceBitrateKbps?.round();
  if (sameCodec &&
      current != null &&
      targetBitrateKbps != null &&
      targetBitrateKbps >= current) {
    return ConversionWarning(
      title: 'Pointless conversion',
      body: 'Re-encoding $source at $targetBitrateKbps kbps (currently ~$current '
          'kbps) gains no quality -- it can only lose a little more. '
          '$_replacedNote',
      severe: true,
    );
  }
  // "Lower bitrate" is only claimed when both bitrates are known (the
  // >= case returned above); an unknown source bitrate gets neutral wording.
  final knownLower =
      sameCodec && current != null && targetBitrateKbps != null;
  return ConversionWarning(
    title: 'Additional quality loss',
    body: knownLower
        ? 'Re-encoding lossy $source at a lower bitrate shrinks the file but '
              'loses more quality (generation loss). $_replacedNote'
        : sameCodec
        ? 'Re-encoding lossy $source again loses additional quality '
              '(generation loss). $_replacedNote'
        : 'Re-encoding lossy $source to lossy $target loses additional quality '
              '(generation loss). $_replacedNote',
    severe: true,
  );
}
