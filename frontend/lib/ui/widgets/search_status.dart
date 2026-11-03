import 'package:flutter/material.dart';

/// Copy for a search that matched nothing. Says when the Downloaded filter
/// narrowed it, so an empty result isn't read as "not in my library".
///
/// No "reconnect" advice even offline: every caller has a Downloaded chip,
/// and switching it off searches the full library from local metadata.
String noSearchResultsMessage({
  required String noun,
  required String query,
  required bool downloadedOnly,
}) {
  final kind = downloadedOnly ? 'downloaded $noun' : noun;
  return 'No $kind match "$query".';
}

/// Copy for a search that threw, so a failure never reads as "no matches".
const searchFailedMessage = "Couldn't search your library. Try again.";

/// A search failed: [searchFailedMessage] with a Retry (SC-19; shared by the
/// global Search, the in-page searches and Phase 8's Manage library). The
/// query and filters stay as they were; Retry re-runs them.
///
/// [compact] is the one-line form shown above results kept from before the
/// failure; otherwise it is the centered form for an empty body.
class SearchFailedNotice extends StatelessWidget {
  const SearchFailedNotice({
    super.key,
    required this.onRetry,
    this.compact = false,
  });

  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.error,
    );
    final retry = TextButton(onPressed: onRetry, child: const Text('Retry'));
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(child: Text(searchFailedMessage, style: style)),
            retry,
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(searchFailedMessage, textAlign: TextAlign.center, style: style),
            const SizedBox(height: 8),
            retry,
          ],
        ),
      ),
    );
  }
}

/// Shown with capped search results: search mode has no infinite scroll, so
/// a full page of one type means there may be more of it. Per type (SC-19):
/// the global Search shows one per capped rail; in-page and Phase 8's
/// Manage library searches show one for their single type.
class SearchCappedHint extends StatelessWidget {
  const SearchCappedHint({super.key, required this.cap, required this.noun});

  final int cap;

  /// The capped type, plural ("artists", "songs").
  final String noun;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Text(
        'Showing the first $cap $noun — refine your search.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
