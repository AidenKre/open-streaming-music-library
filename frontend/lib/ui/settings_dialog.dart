import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/disconnect_controller.dart';

/// Modal that lets the user pick stream + download quality presets and exit
/// the session. Replaces the standalone disconnect button.
class SettingsDialog extends ConsumerWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    // Quality changes round-trip through the backend (the PUT pre-transcodes
    // tracks server-side). While offline the PUT will retry and fail, leaving
    // the user staring at a spinner — so we disable the dropdowns entirely
    // and surface a tooltip explaining why.
    final isOffline = ref.watch(offlineModeProvider);
    // Disconnect is unavailable outside the live-session scope (login screen,
    // tests that don't set up the override). Hide the button in that case.
    final disconnectController = ref.watch(disconnectControllerProvider);

    return AlertDialog(
      title: const Text('Settings'),
      content: settingsAsync.when(
        loading: () => const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Text('Failed to load settings: $e'),
        data: (settings) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Stream quality'),
            const SizedBox(height: 4),
            _maybeOfflineTooltip(
              isOffline: isOffline,
              child: DropdownButton<String>(
                isExpanded: true,
                value: settings.streamQuality,
                items: [
                  for (final q in qualityPresets)
                    DropdownMenuItem(value: q, child: Text(qualityLabel(q))),
                ],
                onChanged: isOffline
                    ? null
                    : (value) {
                        if (value != null && value != settings.streamQuality) {
                          _showStreamQualityChoiceSheet(context, ref, value);
                        }
                      },
              ),
            ),
            const SizedBox(height: 16),
            const Text('Download quality'),
            const SizedBox(height: 4),
            _maybeOfflineTooltip(
              isOffline: isOffline,
              child: DropdownButton<String>(
                isExpanded: true,
                value: settings.downloadQuality,
                items: [
                  for (final q in qualityPresets)
                    DropdownMenuItem(value: q, child: Text(qualityLabel(q))),
                ],
                onChanged: isOffline
                    ? null
                    : (value) {
                        if (value != null) {
                          ref
                              .read(settingsProvider.notifier)
                              .setDownloadQuality(value);
                        }
                      },
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Changing the download quality only affects future downloads — '
              'existing downloads stay as-is.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        if (disconnectController != null)
          TextButton(
            onPressed: () async {
              final confirmed = await _confirmDisconnect(context);
              if (!confirmed || !context.mounted) return;
              Navigator.of(context).pop();
              unawaited(disconnectController.disconnect());
            },
            child: const Text('Disconnect'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// Wraps [child] with an explanatory tooltip when the app is offline.
  Widget _maybeOfflineTooltip({required bool isOffline, required Widget child}) {
    if (!isOffline) return child;
    return Tooltip(
      message: 'Unavailable while offline',
      child: child,
    );
  }

  /// Confirms the destructive disconnect via a modal bottom sheet.
  ///
  /// A bottom sheet (rather than a nested AlertDialog) shares the parent
  /// route, so dismissing it via back-gesture cannot accidentally pop the
  /// SettingsDialog's underlying route — the dialog-on-dialog footgun the
  /// old code had.
  Future<bool> _confirmDisconnect(BuildContext context) async {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Reset and disconnect?',
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This deletes the local library database, downloads, caches, '
                    'queue, playback state, and saved settings on this device.',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Reset and disconnect'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;
  }

  /// Presents the persistent-vs-session stream-quality choice as a modal
  /// bottom sheet. Same rationale as [_confirmDisconnect]: a bottom sheet
  /// avoids dialog-on-dialog dismiss/pop ordering issues.
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
                          .read(settingsProvider.notifier)
                          .setStreamQualityTemporary(newQuality);
                    },
                    child: const Text('This session only'),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      ref
                          .read(settingsProvider.notifier)
                          .setStreamQualityFull(newQuality);
                    },
                    child: const Text('Set as default'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
