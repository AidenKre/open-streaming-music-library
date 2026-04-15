import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/quality_presets.dart';

/// User-tweakable settings backed by `SharedPreferences`.
///
/// Two presets are tracked: the quality used when streaming a track from the
/// server, and the quality used when permanently downloading a track. Changing
/// the download quality does NOT redownload existing local files — it only
/// affects future downloads.
class AppSettings {
  final String streamQuality;
  final String downloadQuality;

  const AppSettings({
    required this.streamQuality,
    required this.downloadQuality,
  });

  AppSettings copyWith({String? streamQuality, String? downloadQuality}) {
    return AppSettings(
      streamQuality: streamQuality ?? this.streamQuality,
      downloadQuality: downloadQuality ?? this.downloadQuality,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.streamQuality == streamQuality &&
      other.downloadQuality == downloadQuality;

  @override
  int get hashCode => Object.hash(streamQuality, downloadQuality);
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  static const _streamQualityKey = 'settings.streamQuality';
  static const _downloadQualityKey = 'settings.downloadQuality';
  static const _defaultQuality = originalQuality;

  @override
  Future<AppSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    return _read(prefs);
  }

  AppSettings _read(SharedPreferences prefs) {
    final stream = prefs.getString(_streamQualityKey);
    final download = prefs.getString(_downloadQualityKey);
    return AppSettings(
      streamQuality: isValidQuality(stream) ? stream! : _defaultQuality,
      downloadQuality: isValidQuality(download) ? download! : _defaultQuality,
    );
  }

  Future<void> setStreamQuality(String quality) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid stream quality: $quality');
    }
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_streamQualityKey, quality);
    final current = state.value ??
        AppSettings(
          streamQuality: _defaultQuality,
          downloadQuality: _defaultQuality,
        );
    state = AsyncData(current.copyWith(streamQuality: quality));
  }

  Future<void> setDownloadQuality(String quality) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid download quality: $quality');
    }
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_downloadQualityKey, quality);
    final current = state.value ??
        AppSettings(
          streamQuality: _defaultQuality,
          downloadQuality: _defaultQuality,
        );
    state = AsyncData(current.copyWith(downloadQuality: quality));
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Synchronous read of the current stream quality. Falls back to `original`
/// while the async settings are still loading on first launch.
final streamQualityProvider = Provider<String>((ref) {
  final settings = ref.watch(settingsProvider).value;
  return settings?.streamQuality ?? originalQuality;
});

final downloadQualityProvider = Provider<String>((ref) {
  final settings = ref.watch(settingsProvider).value;
  return settings?.downloadQuality ?? originalQuality;
});
