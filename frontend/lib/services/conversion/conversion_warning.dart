import 'package:flutter/foundation.dart';
import 'package:frontend/models/app_info.dart';

/// Headline + explanation for the confirm sheet, picked per the format
/// matrix. [severe] tints the headline (irreversible quality loss).
@immutable
class ConversionWarning {
  final String title;
  final String body;
  final bool severe;

  const ConversionWarning({
    required this.title,
    required this.body,
    this.severe = false,
  });
}

const _replacedNote = 'The original file is replaced and cannot be restored.';

/// Format-matrix warning for converting [sourceCodec] to [targetCodec].
/// Source losslessness comes from [isLosslessCodec]; an unrecognised source
/// gets a generic (still cautious) warning.
ConversionWarning conversionWarning({
  required String? sourceCodec,
  required double? sourceBitrateKbps,
  required String targetCodec,
  required bool targetIsLossless,
  required int? targetBitrateKbps,
}) {
  final target = targetCodec.toUpperCase();
  final sourceLossless = isLosslessCodec(sourceCodec);

  if (sourceLossless == null) {
    return ConversionWarning(
      title: 'This replaces the original file',
      body: targetIsLossless
          ? _replacedNote
          : 'Converting to lossy $target may permanently lose audio quality. '
                '$_replacedNote',
      severe: !targetIsLossless,
    );
  }

  final source = sourceCodec!.toUpperCase();
  if (sourceLossless && !targetIsLossless) {
    return ConversionWarning(
      title: 'Permanent quality loss',
      body:
          'This converts your lossless $source original to lossy $target. '
          'The audio detail discarded by lossy encoding can never be '
          'recovered. $_replacedNote',
      severe: true,
    );
  }
  if (!sourceLossless && targetIsLossless) {
    return ConversionWarning(
      title: 'No quality is gained',
      body:
          'The source is already lossy $source, so converting to lossless '
          '$target cannot restore any quality -- the file just gets much '
          'larger. $_replacedNote',
    );
  }
  if (sourceLossless && targetIsLossless) {
    return ConversionWarning(
      title: 'Lossless to lossless',
      body:
          'No audio quality is lost converting $source to $target. '
          '$_replacedNote',
    );
  }

  // Lossy -> lossy.
  final sameCodec = sourceCodec.toLowerCase() == targetCodec.toLowerCase();
  final current = sourceBitrateKbps?.round();
  if (sameCodec &&
      current != null &&
      targetBitrateKbps != null &&
      targetBitrateKbps >= current) {
    return ConversionWarning(
      title: 'Pointless conversion',
      body:
          'Re-encoding $source at $targetBitrateKbps kbps (currently ~$current '
          'kbps) gains no quality -- it can only lose a little more. '
          '$_replacedNote',
      severe: true,
    );
  }
  // "Lower bitrate" is only claimed when both bitrates are known (the
  // >= case returned above); an unknown source bitrate gets neutral wording.
  final knownLower = sameCodec && current != null && targetBitrateKbps != null;
  return ConversionWarning(
    title: 'Additional quality loss',
    body: knownLower
        ? 'Re-encoding lossy $source at a lower bitrate shrinks the file but '
              'loses more quality (generation loss). $_replacedNote'
        : sameCodec
        ? 'Re-encoding lossy $source again loses additional quality '
              '(generation loss). $_replacedNote'
        : 'Re-encoding lossy $source to lossy $target loses additional quality '
              '(generation loss). $_replacedNote',
    severe: true,
  );
}
