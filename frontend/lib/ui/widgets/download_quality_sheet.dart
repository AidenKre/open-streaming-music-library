import 'package:flutter/material.dart';

import 'package:frontend/services/quality_presets.dart';

/// Shows a bottom sheet listing all quality presets and returns the selected
/// quality string. Callers await the Future; `null` means the user dismissed.
Future<String?> showDownloadQualitySheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Download quality',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          for (final quality in qualityPresets)
            ListTile(
              title: Text(qualityLabel(quality)),
              onTap: () => Navigator.pop(ctx, quality),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// A split download row: the left area triggers the default-quality download;
/// the trailing chevron opens the quality picker sheet and then calls
/// [onDownloadAtQuality] with the chosen quality.
class SplitDownloadTile extends StatelessWidget {
  final VoidCallback onDownload;

  /// When non-null, a chevron is shown that opens the quality picker sheet.
  /// When null, the tile behaves as a plain download button (no chevron).
  final void Function(String quality)? onDownloadAtQuality;

  const SplitDownloadTile({
    super.key,
    required this.onDownload,
    this.onDownloadAtQuality,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Download'),
            onTap: onDownload,
          ),
        ),
        if (onDownloadAtQuality != null)
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              tooltip: 'Choose quality',
              icon: const Icon(Icons.chevron_right),
              onPressed: () async {
                final quality = await showDownloadQualitySheet(context);
                if (quality != null) {
                  onDownloadAtQuality!(quality);
                }
              },
            ),
          ),
      ],
    );
  }
}
