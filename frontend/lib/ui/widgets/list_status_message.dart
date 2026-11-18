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

/// The one "the local read failed" notice: it never claims the library is
/// empty (a failed read is unknown, not none) and never shows the error's
/// text. Full-size in place of a list with no rows; [compact] in a list's
/// trailing slot when rows were kept.
class LoadFailureNotice extends StatelessWidget {
  const LoadFailureNotice({super.key, required this.onRetry, this.compact = false});

  static const message = "Couldn't load your library.";

  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final retry = TextButton(onPressed: onRetry, child: const Text('Retry'));
    if (compact) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              retry,
            ],
          ),
        ),
      );
    }
    final bottom = ShellChromeInsets.of(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              retry,
            ],
          ),
        ),
      ),
    );
  }
}
