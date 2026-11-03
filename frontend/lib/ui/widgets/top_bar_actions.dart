import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:frontend/ui/session/session_host.dart';

/// One top-bar button (SC-08): opens a session destination. [isAvailable]
/// (null = always) reads capability/state providers, so a button for a
/// feature the server doesn't offer never shows (no dead buttons).
@immutable
class TopBarAction {
  const TopBarAction({
    required this.destination,
    required this.icon,
    required this.tooltip,
    this.isAvailable,
  });

  final SessionDestination destination;
  final IconData icon;
  final String tooltip;
  final ProviderListenable<bool>? isAvailable;
}

/// The top-bar actions, in order. Phase 4: the Downloading page and
/// Settings (Conversions is reached from Settings -> Library tools). Phase 7
/// registers Uploads here, gated on the `uploads` capability.
final topBarActionsProvider = Provider<List<TopBarAction>>(
  (ref) => const [
    TopBarAction(
      destination: SessionDestination.downloadProgress,
      icon: Icons.download,
      tooltip: 'Downloads',
    ),
    TopBarAction(
      destination: SessionDestination.settings,
      icon: Icons.settings,
      tooltip: 'Settings',
    ),
  ],
);

/// Renders [topBarActionsProvider]; every button navigates through the
/// session host (`openSession`), never a local push.
List<Widget> buildTopBarActions(BuildContext context, WidgetRef ref) {
  return [
    for (final action in ref.watch(topBarActionsProvider))
      if (action.isAvailable == null || ref.watch(action.isAvailable!))
        IconButton(
          icon: Icon(action.icon),
          tooltip: action.tooltip,
          onPressed: () => openSession(context, action.destination),
        ),
  ];
}
