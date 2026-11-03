import 'package:flutter/material.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

/// Centered explanatory text shown in place of a list that has nothing to
/// show (a filtered browse list, or a search with no matches), so an empty
/// view never reads like the library was wiped.
class ListStatusMessage extends StatelessWidget {
  const ListStatusMessage(this.message, {super.key, this.padForChrome = true});

  final String message;

  /// Keep clear of the shell's floating bottom chrome. False where the
  /// caller already pads for it (inside Search's feed).
  final bool padForChrome;

  @override
  Widget build(BuildContext context) {
    // Centred in the space the shell's floating bottom chrome leaves (4B);
    // the top is the page's own (an AppBar, or a root's padded header).
    final bottom = padForChrome ? ShellChromeInsets.of(context).bottom : 0.0;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
