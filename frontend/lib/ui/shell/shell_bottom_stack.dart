import 'package:flutter/material.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/glass.dart';
import 'package:frontend/ui/shell/shell_banner_region.dart';
import 'package:frontend/ui/shell/shell_tab.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';
import 'package:frontend/ui/widgets/pending_edits_banner.dart';
import 'package:frontend/ui/widgets/server_blocked_banner.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';

/// The rows of the shell's floating bottom stack, toward the screen edge:
/// the banners (in a [ShellBannerRegion] capped at 30% of [bodyHeight]),
/// the mini player and the Home/Search navigation, on one glass surface.
/// The shell constrains it to the body's height and measures it; this
/// widget only lays the rows out (navigation first in view when they
/// scroll).
class ShellBottomStack extends StatelessWidget {
  const ShellBottomStack({
    super.key,
    required this.bodyHeight,
    required this.isOffline,
    required this.session,
    required this.selectedTab,
    required this.onSelectTab,
    required this.bannerRegionKey,
  });

  final double bodyHeight;
  final bool isOffline;
  final SessionControls session;
  final ShellTab selectedTab;
  final ValueChanged<ShellTab> onSelectTab;
  final Key bannerRegionKey;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      // The top safe area belongs to the top bar: without this the tab
      // bar's own SafeArea would add it again (audit 4B(a) M2). Side
      // safe areas apply to every row of the stack.
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: SafeArea(
          top: false,
          bottom: false,
          child: SingleChildScrollView(
            primary: false,
            reverse: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Blocked (different server) behaves as offline, so its
                // banner replaces the offline one (SC-01 rule 1).
                ListenableBuilder(
                  listenable: session,
                  builder: (context, _) => ShellBannerRegion(
                    key: bannerRegionKey,
                    maxHeight: bodyHeight * 0.3,
                    banners: [
                      const PendingEditsBanner(),
                      const StaleDownloadsBanner(),
                      if (session.serverBlocked != ServerBlockedReason.none)
                        const ServerBlockedBanner()
                      else if (isOffline)
                        const OfflineBanner(),
                    ],
                  ),
                ),
                const MiniPlayer(),
                NavigationBar(
                  // The glass behind it is the bar's surface.
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  selectedIndex: selectedTab.index,
                  onDestinationSelected: (i) =>
                      onSelectTab(ShellTab.values[i]),
                  destinations: [
                    for (final tab in ShellTab.values)
                      NavigationDestination(
                        icon: Icon(tab.icon),
                        selectedIcon: Icon(tab.selectedIcon),
                        label: tab.label,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
