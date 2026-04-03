/// Quality preset names that mirror the backend `transcoder.py` constants.
/// Validation lives here so the UI can offer the same options the server
/// understands without round-tripping.
library;

const String originalQuality = 'original';

/// Ordered from highest to lowest. Used to render dropdowns and to validate
/// settings loaded from `SharedPreferences`.
const List<String> qualityPresets = <String>[
  originalQuality,
  '320',
  '256',
  '192',
  '128',
];

bool isValidQuality(String? quality) {
  if (quality == null) return false;
  return qualityPresets.contains(quality);
}

String qualityLabel(String quality) {
  if (quality == originalQuality) return 'Original';
  return '$quality kbps';
}
