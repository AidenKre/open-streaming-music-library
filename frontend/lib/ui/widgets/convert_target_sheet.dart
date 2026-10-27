import 'package:flutter/material.dart';

import 'package:frontend/models/app_info.dart';

/// Result of [showConvertTargetSheet]: the chosen target codec, plus a
/// bitrate when the codec is lossy (null for a lossless target).
@immutable
class ConvertTargetChoice {
  final String codec;
  final int? bitrateKbps;

  const ConvertTargetChoice({required this.codec, required this.bitrateKbps});
}

/// Two-step bottom sheet: pick a target codec from [allowedTargets] (already
/// filtered for this track -- see [ConversionCapabilities.allowedFor]), then,
/// only if that codec is lossy, pick a bitrate from [bitratePresets]. Mirrors
/// `showDownloadQualitySheet`'s single-step shape, extended with the extra
/// step conversion needs (a codec choice, which `showDownloadQualitySheet`
/// doesn't have -- it only ever targets AAC).
///
/// Returns `null` if the user dismisses either step (never a partial choice).
Future<ConvertTargetChoice?> showConvertTargetSheet(
  BuildContext context, {
  required List<ConversionTargetInfo> allowedTargets,
  required List<int> bitratePresets,
}) async {
  final codec = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Convert to',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          for (final target in allowedTargets)
            ListTile(
              title: Text(target.codec.toUpperCase()),
              subtitle: target.isLossless ? const Text('Lossless') : null,
              onTap: () => Navigator.pop(ctx, target.codec),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (codec == null) return null;

  final chosen = allowedTargets.where((t) => t.codec == codec).firstOrNull;
  if (chosen == null || chosen.isLossless) {
    return ConvertTargetChoice(codec: codec, bitrateKbps: null);
  }

  final bitrate = await showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Bitrate',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          for (final preset in bitratePresets)
            ListTile(
              title: Text('$preset kbps'),
              onTap: () => Navigator.pop(ctx, preset),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (bitrate == null) return null;
  return ConvertTargetChoice(codec: codec, bitrateKbps: bitrate);
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
