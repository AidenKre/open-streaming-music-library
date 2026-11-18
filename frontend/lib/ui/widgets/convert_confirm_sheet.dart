import 'package:flutter/material.dart';

import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/services/conversion/conversion_warning.dart';

/// Irreversible-confirm bottom sheet for starting a conversion. This is NEW
/// UI, not a mirror of an existing widget -- the codebase has no
/// checkbox-gated confirm anywhere (the only other "irreversible action"
/// dialog, `master_write_confirm_dialog.dart`, is a plain `AlertDialog` with
/// no checkbox). It borrows the outer shell from `_confirmDisconnect`
/// (`settings_dialog.dart`) -- a bottom sheet, not a nested `AlertDialog`, so
/// a back-gesture dismissal can't accidentally pop the parent route -- and
/// adds a stateful `CheckboxListTile` gate on top, per the "I
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
  final bitratePart = targetBitrateKbps != null
      ? ' at ${targetBitrateKbps}kbps'
      : '';
  final warning = conversionWarning(
    sourceCodec: sourceCodec,
    sourceBitrateKbps: sourceBitrateKbps,
    targetCodec: targetCodec,
    targetIsLossless: targetIsLossless,
    targetBitrateKbps: targetBitrateKbps,
  );
  return await showModalBottomSheet<bool>(
        context: SessionHost.sheetContext(context),
        isScrollControlled: true,
        builder: (ctx) => _ConvertConfirmBody(
          title: 'Convert to ${targetCodec.toUpperCase()}$bitratePart?',
          warning: warning,
        ),
      ) ??
      false;
}

/// The sheet's content. The "I understand" tick lives in this State, not
/// in the route's builder: the route re-runs its builder on a rebuild (a
/// theme or media change), which would reset a local variable to unticked
/// (U25-A-04).
class _ConvertConfirmBody extends StatefulWidget {
  const _ConvertConfirmBody({required this.title, required this.warning});

  final String title;
  final ConversionWarning warning;

  @override
  State<_ConvertConfirmBody> createState() => _ConvertConfirmBodyState();
}

class _ConvertConfirmBodyState extends State<_ConvertConfirmBody> {
  var _understood = false;

  @override
  Widget build(BuildContext context) {
    final warning = widget.warning;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
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
              value: _understood,
              onChanged: (v) => setState(() => _understood = v ?? false),
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
                  onPressed: _understood
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  child: const Text('Convert'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
