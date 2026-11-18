import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings/settings_registry.dart';
import 'package:frontend/ui/settings_controller.dart';

/// Phase 9's Settings section (SC-21): Home rail visibility (SC-07).
const phase9SettingsSections = <SettingsSection>[
  SettingsSection(id: 'home', order: 350, title: 'Home'),
];

final phase9SettingsRows = <SettingsRowContribution>[
  SettingsRowContribution(
    sectionId: 'library_tools',
    order: 30,
    isAvailable: lastfmIntegrationsEntryProvider,
    build: (_) => const _IntegrationsRow(),
  ),
  SettingsRowContribution(
    sectionId: 'home',
    order: 0,
    build: (_) => const _HomeSectionToggle(
      sectionId: HomeSectionIds.rediscover,
      title: 'Show Rediscover',
    ),
  ),
  SettingsRowContribution(
    sectionId: 'home',
    order: 1,
    build: (_) => const _HomeSectionToggle(
      sectionId: HomeSectionIds.moreFromArtists,
      title: 'Show More from your artists',
    ),
  ),
];

class _IntegrationsRow extends StatelessWidget {
  const _IntegrationsRow();

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.extension_outlined),
    title: const Text('Integrations'),
    subtitle: const Text('Last.fm scrobbling'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => openSession(context, SessionDestination.integrations),
  );
}

/// A switch that shows whether a Home rail is shown. Until the preference
/// loads the rail counts as shown (nothing is hidden by default).
class _HomeSectionToggle extends ConsumerWidget {
  const _HomeSectionToggle({required this.sectionId, required this.title});

  final String sectionId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden =
        ref.watch(homeLayoutPreferencesProvider).value?.isHidden(sectionId) ??
        false;
    return SwitchListTile(
      key: Key('settings.home.toggle.$sectionId'),
      title: Text(title),
      value: !hidden,
      onChanged: (shown) async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        try {
          await ref
              .read(settingsControlsProvider)
              .setHomeSectionHidden(sectionId, !shown);
        } on Object {
          messenger?.showSnackBar(
            const SnackBar(content: Text("Couldn't save this setting.")),
          );
        }
      },
    );
  }
}
