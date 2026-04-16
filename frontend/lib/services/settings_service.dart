import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/quality_presets.dart';

/// Whether a stream quality change is persistent or session-only.
enum QualityChangeKind { full, temporary }

/// User-tweakable settings backed by `SharedPreferences`.
///
/// Two presets are tracked: the quality used when streaming a track from the
/// server, and the quality used when permanently downloading a track. Changing
/// the download quality does NOT redownload existing local files — it only
/// affects future downloads.
///
/// Stream quality additionally supports a *temporary* override that is
/// session-only (not persisted) and reverts on app restart.
class AppSettings {
  /// Stream quality persisted to SharedPreferences.
  final String persistedStreamQuality;

  /// Session-only stream quality override. Reverts on restart.
  final String? temporaryStreamQuality;

  /// Tracks what kind of change last updated the stream quality, so the
  /// AudioCoordinator can decide how much of the playlist to rebuild.
  final QualityChangeKind? streamQualityChangeKind;

  final String downloadQuality;

  const AppSettings({
    required this.persistedStreamQuality,
    required this.downloadQuality,
    this.temporaryStreamQuality,
    this.streamQualityChangeKind,
  });

  /// Effective stream quality: temporary override takes precedence.
  String get streamQuality => temporaryStreamQuality ?? persistedStreamQuality;

  AppSettings copyWith({
    String? persistedStreamQuality,
    String? downloadQuality,
    String? temporaryStreamQuality,
    QualityChangeKind? streamQualityChangeKind,
    bool clearTemporary = false,
  }) {
    return AppSettings(
      persistedStreamQuality:
          persistedStreamQuality ?? this.persistedStreamQuality,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      temporaryStreamQuality:
          clearTemporary ? null : (temporaryStreamQuality ?? this.temporaryStreamQuality),
      streamQualityChangeKind:
          streamQualityChangeKind ?? this.streamQualityChangeKind,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.persistedStreamQuality == persistedStreamQuality &&
      other.temporaryStreamQuality == temporaryStreamQuality &&
      other.downloadQuality == downloadQuality &&
      other.streamQualityChangeKind == streamQualityChangeKind;

  @override
  int get hashCode => Object.hash(
        persistedStreamQuality,
        temporaryStreamQuality,
        downloadQuality,
        streamQualityChangeKind,
      );
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  static const _streamQualityKey = 'settings.streamQuality';
  static const _downloadQualityKey = 'settings.downloadQuality';
  static const _defaultQuality = originalQuality;

  @override
  Future<AppSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final settings = _read(prefs);

    // Fetch the backend's persisted default quality (informational — this
    // lets the UI show what the server is set to, but the frontend pref
    // drives actual stream URLs).
    _fetchBackendQuality();

    return settings;
  }

  AppSettings _read(SharedPreferences prefs) {
    final stream = prefs.getString(_streamQualityKey);
    final download = prefs.getString(_downloadQualityKey);
    return AppSettings(
      persistedStreamQuality:
          isValidQuality(stream) ? stream! : _defaultQuality,
      downloadQuality: isValidQuality(download) ? download! : _defaultQuality,
    );
  }

  void _fetchBackendQuality() {
    if (ApiClient.instance.baseUrl.isEmpty) return;
    ApiClient.instance
        .getJson(['settings', 'quality'])
        .then((_) {/* informational — no action needed */})
        .catchError((Object e) {
      developer.log(
        'Could not fetch backend quality setting: $e',
        name: 'SettingsNotifier',
      );
    });
  }

  /// Persists [quality] to SharedPreferences **and** sends it to the backend
  /// so the server warms all tracks at the new default. Rebuilds the full
  /// playlist in the AudioCoordinator (via [streamQualityChangeKind]).
  Future<void> setStreamQualityFull(String quality) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid stream quality: $quality');
    }
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_streamQualityKey, quality);

    // Tell the backend — failures are non-fatal (the local pref still applies).
    try {
      await ApiClient.instance
          .putJson(['settings', 'quality'], body: {'quality': quality});
    } catch (e) {
      developer.log(
        'Failed to update backend quality: $e',
        name: 'SettingsNotifier',
      );
    }

    final current = state.value ??
        AppSettings(
          persistedStreamQuality: _defaultQuality,
          downloadQuality: _defaultQuality,
        );
    state = AsyncData(
      current.copyWith(
        persistedStreamQuality: quality,
        streamQualityChangeKind: QualityChangeKind.full,
        clearTemporary: true,
      ),
    );
  }

  /// Sets [quality] for this session only — not persisted to prefs and reverts
  /// on app restart. Only rebuilds the current playlist source (cheap).
  void setStreamQualityTemporary(String quality) {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid stream quality: $quality');
    }
    final current = state.value ??
        AppSettings(
          persistedStreamQuality: _defaultQuality,
          downloadQuality: _defaultQuality,
        );
    state = AsyncData(
      current.copyWith(
        temporaryStreamQuality: quality,
        streamQualityChangeKind: QualityChangeKind.temporary,
      ),
    );
  }

  Future<void> setDownloadQuality(String quality) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid download quality: $quality');
    }
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(_downloadQualityKey, quality);
    final current = state.value ??
        AppSettings(
          persistedStreamQuality: _defaultQuality,
          downloadQuality: _defaultQuality,
        );
    state = AsyncData(current.copyWith(downloadQuality: quality));
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Synchronous read of the current effective stream quality (temporary takes
/// precedence over persisted). Falls back to `original` while loading.
final streamQualityProvider = Provider<String>((ref) {
  final settings = ref.watch(settingsProvider).value;
  return settings?.streamQuality ?? originalQuality;
});

/// The kind of the most recent stream quality change — `null` on first load.
final streamQualityChangeKindProvider = Provider<QualityChangeKind?>((ref) {
  return ref.watch(settingsProvider).value?.streamQualityChangeKind;
});

final downloadQualityProvider = Provider<String>((ref) {
  final settings = ref.watch(settingsProvider).value;
  return settings?.downloadQuality ?? originalQuality;
});
