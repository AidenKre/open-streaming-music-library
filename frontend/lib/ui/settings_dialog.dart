import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/settings_service.dart';

/// Modal that lets the user pick stream + download quality presets and exit
/// the session. Replaces the standalone disconnect button.
class SettingsDialog extends ConsumerWidget {
  final VoidCallback? onDisconnect;

  const SettingsDialog({super.key, this.onDisconnect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);

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
            DropdownButton<String>(
              isExpanded: true,
              value: settings.streamQuality,
              items: [
                for (final q in qualityPresets)
                  DropdownMenuItem(value: q, child: Text(qualityLabel(q))),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setStreamQuality(value);
                }
              },
            ),
            const SizedBox(height: 16),
            const Text('Download quality'),
            const SizedBox(height: 4),
            DropdownButton<String>(
              isExpanded: true,
              value: settings.downloadQuality,
              items: [
                for (final q in qualityPresets)
                  DropdownMenuItem(value: q, child: Text(qualityLabel(q))),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setDownloadQuality(value);
                }
              },
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
        if (onDisconnect != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onDisconnect!();
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
}
