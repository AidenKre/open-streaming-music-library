import 'package:flutter/material.dart';

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
/// Returns `true` only if the user both checked the box and tapped Convert;
/// `false` for Cancel or dismissal.
Future<bool> showConvertConfirmSheet(
  BuildContext context, {
  required String targetCodec,
  required int? targetBitrateKbps,
}) async {
  final bitratePart = targetBitrateKbps != null ? ' at ${targetBitrateKbps}kbps' : '';
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
                      const Text(
                        'This replaces the original file permanently. For a '
                        'lossy target, the original audio quality cannot be '
                        'recovered afterward.',
                      ),
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
