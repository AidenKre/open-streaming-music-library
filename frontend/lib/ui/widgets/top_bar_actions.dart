import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/conversions_page.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/settings_dialog.dart';

/// Standard top-bar action set used by every page that shows a top bar.
/// Replaces the old standalone disconnect button with a downloads-page
/// shortcut and a settings menu.
List<Widget> buildTopBarActions(BuildContext context, WidgetRef ref) {
  return [
    IconButton(
      icon: const Icon(Icons.download),
      tooltip: 'Downloads',
      onPressed: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const DownloadingPage()));
      },
    ),
    IconButton(
      icon: const Icon(Icons.transform),
      tooltip: 'Conversions',
      onPressed: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ConversionsPage()));
      },
    ),
    IconButton(
      icon: const Icon(Icons.settings),
      tooltip: 'Settings',
      onPressed: () {
        showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (_) => const SettingsDialog(),
        );
      },
    ),
  ];
}
