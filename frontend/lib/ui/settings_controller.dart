import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/settings_service.dart';

/// Settings input (SC-26): every Settings change goes through here; the
/// model `SettingsNotifier` owns persistence, the backend pre-transcode
/// call and their rules.
abstract interface class SettingsControls {
  /// Persist as the default and ask the server to pre-transcode.
  Future<void> setStreamQualityDefault(String quality);

  /// This app session only; nothing persisted, no server call.
  void setStreamQualityForSession(String quality);

  Future<void> setDownloadQuality(String quality);

  Future<void> setNotifyStaleDownloads(bool notify);
}

final settingsControlsProvider = Provider<SettingsControls>(
  (ref) => SettingsController(ref),
);

class SettingsController implements SettingsControls {
  SettingsController(this._ref);

  final Ref _ref;

  SettingsNotifier get _settings => _ref.read(settingsProvider.notifier);

  @override
  Future<void> setStreamQualityDefault(String quality) =>
      _settings.setStreamQualityFull(quality);

  @override
  void setStreamQualityForSession(String quality) =>
      _settings.setStreamQualityTemporary(quality);

  @override
  Future<void> setDownloadQuality(String quality) =>
      _settings.setDownloadQuality(quality);

  @override
  Future<void> setNotifyStaleDownloads(bool notify) =>
      _settings.setNotifyStaleDownloads(notify);
}
