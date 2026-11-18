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

/// The one "a read failed" notice: for the local library read it never
/// claims the library is empty (a failed read is unknown, not none); a page
/// whose server read failed gives its own words as [message]. It never shows
/// the error's text. Full-size in place of a list with no rows; [compact] in
/// a list's trailing slot (or a header) when rows were kept.
class LoadFailureNotice extends StatelessWidget {
  const LoadFailureNotice({
    super.key,
    required this.onRetry,
    this.compact = false,
    this.message = libraryMessage,
    this.retryKey,
    this.padForChrome = true,
  });

  static const libraryMessage = "Couldn't load your library.";

  final VoidCallback onRetry;
  final bool compact;

  /// What failed to load, in the page's words.
  final String message;

  /// The key of the Retry button.
  final Key? retryKey;

  /// Keep the full-size notice clear of the shell's floating bottom chrome.
  /// False inside a scrolling page that already ends above it.
  final bool padForChrome;

  @override
  Widget build(BuildContext context) {
    final retry = TextButton(
      key: retryKey,
      onPressed: onRetry,
      child: const Text('Retry'),
    );
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
    final bottom = padForChrome ? ShellChromeInsets.of(context).bottom : 0.0;
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
