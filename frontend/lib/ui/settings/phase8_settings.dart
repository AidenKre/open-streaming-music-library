import 'package:flutter/material.dart';
import 'package:frontend/services/duplicates/duplicates_review.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings/settings_registry.dart';

/// Phase 8's Settings rows (SC-21), under Library tools: Manage library and
/// Possible duplicates.
final phase8SettingsRows = <SettingsRowContribution>[
  SettingsRowContribution(
    sectionId: 'library_tools',
    order: 10,
    // Available whenever the block is present, even with server_delete off,
    // so the page can say deletion is turned off.
    isAvailable: libraryToolsAdvertisedProvider,
    build: (_) => const _ManageLibraryRow(),
  ),
  SettingsRowContribution(
    sectionId: 'library_tools',
    order: 20,
    // Shown only when the server offers the duplicate review.
    isAvailable: duplicateReviewAdvertisedProvider,
    build: (_) => const _PossibleDuplicatesRow(),
  ),
];

class _ManageLibraryRow extends StatelessWidget {
  const _ManageLibraryRow();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.delete_sweep_outlined),
      title: const Text('Manage library'),
      subtitle: const Text('Select tracks and delete them from the server'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openSession(context, SessionDestination.manageLibrary),
    );
  }
}

class _PossibleDuplicatesRow extends StatelessWidget {
  const _PossibleDuplicatesRow();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.content_copy_outlined),
      title: const Text('Possible duplicates'),
      subtitle: const Text('Review tracks that may be the same recording'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openSession(context, SessionDestination.duplicates),
    );
  }
}
