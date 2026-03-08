import 'package:flutter/material.dart';

class ArtistCard extends StatelessWidget {
  final String artistName;
  final VoidCallback onTap;

  const ArtistCard({super.key, required this.artistName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // TODO: Fetch artist art from API
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                color: colorScheme.secondaryContainer,
                child: Icon(
                  Icons.person,
                  size: 48,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Text(
                artistName,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
