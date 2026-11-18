import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings/settings_registry.dart';
import 'package:frontend/ui/settings_controller.dart';
import 'package:frontend/ui/widgets/reset_confirm_sheet.dart';

/// Phase 4's own Settings sections and rows, registered through the SC-21
/// registry like any later phase's (nothing is special-cased in the page).
const phase4SettingsSections = <SettingsSection>[
  SettingsSection(id: 'playback', order: 100, title: 'Playback quality'),
  SettingsSection(id: 'downloads', order: 200, title: 'Downloads'),
  SettingsSection(id: 'notifications', order: 300, title: 'Notifications'),
  SettingsSection(id: 'library_tools', order: 400, title: 'Library tools'),
  SettingsSection(id: 'connection', order: 900, title: 'Connection'),
];

/// Disconnect (and the Sync & storage rows) are offered only inside a live
/// session.
final sessionIsLiveProvider = Provider<bool>(
  (ref) => ref.watch(sessionControlsProvider).phase == SessionPhase.live,
);

final phase4SettingsRows = <SettingsRowContribution>[
  SettingsRowContribution(
    sectionId: 'playback',
    order: 0,
    build: (_) => const _StreamQualityRow(),
  ),
  SettingsRowContribution(
    sectionId: 'downloads',
    order: 0,
    build: (_) => const _DownloadQualityRow(),
  ),
  SettingsRowContribution(
    sectionId: 'notifications',
    order: 0,
    build: (_) => const _StaleNotificationsRow(),
  ),
  SettingsRowContribution(
    sectionId: 'library_tools',
    order: 0,
    build: (_) => const _ConversionsRow(),
  ),
  SettingsRowContribution(
    sectionId: 'connection',
    order: 0,
    isAvailable: sessionIsLiveProvider,
    build: (_) => const _LogOutRow(),
  ),
  SettingsRowContribution(
    sectionId: 'connection',
    order: 1,
    isAvailable: sessionIsLiveProvider,
    build: (_) => const _DisconnectRow(),
  ),
];

/// Only setting a stream-quality default calls the backend (the PUT
/// pre-transcodes server-side); offline the PUT would retry and fail, so the
/// stream choice sheet's "Set as default" is disabled with an explanation.
/// Download quality (saved on this device) and the session-only stream
/// quality (kept in memory) stay usable offline.
Widget _offlineTooltip({required bool canChange, required Widget child}) {
  if (canChange) return child;
  return Tooltip(message: 'Unavailable while offline', child: child);
}

/// Shown when the settings model could not load (it reads only this
/// device's saved preferences). The same sentence as the session's
/// unreadable-preferences notice; proposed to the owner, not yet approved.
const settingsUnreadableMessage =
    "This device's saved settings could not be read.";

/// Shared loading/error presentation for rows backed by the settings model.
class _SettingsValue extends ConsumerWidget {
  const _SettingsValue({required this.builder});
  final Widget Function(BuildContext, WidgetRef, AppSettings) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(settingsProvider).when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      // Other-issues row 66: a fixed sentence; the settings model logs the
      // error's type.
      error: (_, _) => const Padding(
        padding: EdgeInsets.all(16),
        child: Text(settingsUnreadableMessage),
      ),
      data: (settings) => builder(context, ref, settings),
    );
  }
}

class _StreamQualityRow extends StatelessWidget {
  const _StreamQualityRow();

  @override
  Widget build(BuildContext context) {
    return _SettingsValue(
      builder: (context, ref, settings) {
        return ListTile(
          title: const Text('Stream quality'),
          subtitle: DropdownButton<String>(
            isExpanded: true,
            value: settings.streamQuality,
            items: [
              for (final q in qualityPresets)
                DropdownMenuItem(value: q, child: Text(qualityLabel(q))),
            ],
            onChanged: (value) {
              if (value != null && value != settings.streamQuality) {
                _showStreamQualityChoiceSheet(context, ref, value);
              }
            },
          ),
        );
      },
    );
  }

  /// Persistent-vs-session choice as a bottom sheet (no dialog-on-dialog
  /// dismiss ordering issues); it pops only itself.
  void _showStreamQualityChoiceSheet(
    BuildContext context,
    WidgetRef ref,
    String newQuality,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set stream quality to ${qualityLabel(newQuality)}?',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              const Text(
                'Set as default:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Persists across restarts and tells the server to pre-transcode '
                'all tracks. Playback may experience brief startup delays until '
                'the server finishes.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              const Text(
                'This session only:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Reverts when the app is restarted. No server-side transcoding '
                'is triggered.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      ref
                          .read(settingsControlsProvider)
                          .setStreamQualityForSession(newQuality);
                    },
                    child: const Text('This session only'),
                  ),
                  Consumer(
                    builder: (ctx, sheetRef, _) {
                      final canChange = sheetRef
                          .watch(settingsControlsProvider)
                          .canChangeServerQuality;
                      return _offlineTooltip(
                        canChange: canChange,
                        child: FilledButton(
                          onPressed: !canChange
                              ? null
                              : () => _setDefault(ctx, sheetRef, newQuality),
                          child: const Text('Set as default'),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pops the sheet, then sets the default; says so when the server did not
  /// take it (the row keeps the old default).
  Future<void> _setDefault(
    BuildContext sheetContext,
    WidgetRef ref,
    String quality,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(sheetContext);
    final controls = ref.read(settingsControlsProvider);
    Navigator.of(sheetContext).pop();
    try {
      await controls.setStreamQualityDefault(quality);
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text(saveDefaultQualityFailedMessage)),
      );
    }
  }
}

class _DownloadQualityRow extends StatelessWidget {
  const _DownloadQualityRow();

  @override
  Widget build(BuildContext context) {
    return _SettingsValue(
      builder: (context, ref, settings) {
        return ListTile(
          title: const Text('Download quality'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButton<String>(
                isExpanded: true,
                value: settings.downloadQuality,
                items: [
                  for (final q in qualityPresets)
                    DropdownMenuItem(value: q, child: Text(qualityLabel(q))),
                ],
                onChanged: (value) {
                  if (value != null) {
                    ref.read(settingsControlsProvider).setDownloadQuality(value);
                  }
                },
              ),
              const SizedBox(height: 4),
              const Text(
                'Changing the download quality only affects future downloads — '
                'existing downloads stay as-is.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StaleNotificationsRow extends StatelessWidget {
  const _StaleNotificationsRow();

  @override
  Widget build(BuildContext context) {
    return _SettingsValue(
      builder: (context, ref, settings) => SwitchListTile(
        title: const Text('Notify about changed downloads'),
        subtitle: const Text(
          'Show a banner when a track you downloaded changes on the '
          'server (audio, tags, or artwork).',
        ),
        value: settings.notifyStaleDownloads,
        onChanged: (value) =>
            ref.read(settingsControlsProvider).setNotifyStaleDownloads(value),
      ),
    );
  }
}

class _ConversionsRow extends StatelessWidget {
  const _ConversionsRow();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.transform),
      title: const Text('Conversions'),
      subtitle: const Text('Master-format conversion jobs'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openSession(context, SessionDestination.conversions),
    );
  }
}

/// Signs out but keeps every local store (spec 7.6). It asks first only when
/// unsent work would be dropped.
class _LogOutRow extends ConsumerWidget {
  const _LogOutRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.person_off_outlined),
      title: const Text('Log out'),
      subtitle: const Text(
        'Log out of this account; downloads and library stay on this device',
      ),
      onTap: () => unawaited(
        logOutAfterWarning(context, ref.read(sessionControlsProvider)),
      ),
    );
  }
}

class _DisconnectRow extends ConsumerWidget {
  const _DisconnectRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.logout),
      title: const Text('Disconnect'),
      subtitle: const Text('Reset this device and return to the server address screen'),
      onTap: () async {
        final session = ref.read(sessionControlsProvider);
        final losses = await session.pendingLossSummaries();
        if (!context.mounted) return;
        final confirmed = await showDisconnectConfirmSheet(
          context,
          losses: losses,
        );
        if (!confirmed || !context.mounted) return;
        // Success ends the session: the session host and every session
        // route go with it. A partial reset is shown honestly first.
        unawaited(session.disconnect());
      },
    );
  }

}
