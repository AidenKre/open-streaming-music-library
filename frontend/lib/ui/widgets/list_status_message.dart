import 'package:flutter/material.dart';

/// Centered explanatory text shown in place of a list that has nothing to
/// show (a filtered browse list, or a search with no matches), so an empty
/// view never reads like the library was wiped.
class ListStatusMessage extends StatelessWidget {
  const ListStatusMessage(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
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
    );
  }
}
