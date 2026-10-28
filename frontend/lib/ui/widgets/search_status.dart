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

/// Shown under capped search results: search mode has no infinite scroll, so
/// a full page of results means there may be more.
class SearchCappedHint extends StatelessWidget {
  const SearchCappedHint({super.key, required this.cap});

  final int cap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Text(
        'Showing the first $cap matches — refine your search to narrow them '
        'down.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
