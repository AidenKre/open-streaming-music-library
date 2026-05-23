import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
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

  /// Hard cap on how long `build()` waits for the backend to return its
  /// authoritative quality. Kept tight so first-paint isn't held hostage by
  /// a slow/unreachable server — on timeout we fall back to the cached pref
  /// and the next online startup will refresh.
  @visibleForTesting
  static Duration backendSyncTimeout = const Duration(seconds: 3);

  @override
  Future<AppSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final local = _read(prefs);

    // Sync the backend's authoritative quality before returning. The backend
    // is the source of truth; SharedPreferences is an offline cache of the
    // last known value. We await (with a tight timeout) so a racing call to
    // [setStreamQualityFull] cannot be clobbered by a late-resolving sync.
    final synced = await _syncQualityFromBackend(local, prefs);
    return synced;
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

  /// Fetches the authoritative stream quality from the backend and folds it
  /// into [local], returning the merged settings. On any failure (no URL,
  /// offline, timeout, network error, invalid response), returns [local]
  /// unchanged. Persists the fetched value so offline restarts use it.
  Future<AppSettings> _syncQualityFromBackend(
    AppSettings local,
    SharedPreferences prefs,
  ) async {
    if (ApiClient.instance.baseUrl.isEmpty) return local;
    // Skip when offline — the request would just fail. The cached value in
    // SharedPreferences remains in effect; next online startup will refresh.
    if (ref.read(offlineModeProvider)) return local;
    try {
      final data = await ApiClient.instance
          .getJson(['settings', 'quality'])
          .timeout(backendSyncTimeout);
      final quality = data['quality'];
      if (!isValidQuality(quality)) return local;
      // Cache locally so offline restarts use the last known backend value.
      await prefs.setString(_streamQualityKey, quality as String);
      if (local.persistedStreamQuality == quality) return local;
      // Intentionally do NOT set streamQualityChangeKind so the
      // AudioCoordinator doesn't attempt a playlist rebuild at startup.
      return local.copyWith(persistedStreamQuality: quality);
    } catch (e) {
      developer.log(
        'Could not sync quality from backend: $e',
        name: 'SettingsNotifier',
      );
      return local;
    }
  }

  /// Sends [quality] to the backend so the server warms all tracks at the new
  /// default. On success, persists to SharedPreferences and updates state.
  /// On PUT failure, updates in-memory state (so the UI reflects the user's
  /// choice for the session) but does NOT persist — the next online startup
  /// will resync from the backend, keeping cross-device state consistent.
  Future<void> setStreamQualityFull(String quality) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid stream quality: $quality');
    }

    // PUT first; only persist on success. A failed PUT must not leave prefs
    // ahead of the backend — that breaks cross-device sync.
    var backendOk = false;
    try {
      await ApiClient.instance.putJson(
        ['settings', 'quality'],
        body: {'quality': quality},
        retry: true,
      );
      backendOk = true;
    } catch (e) {
      developer.log(
        'Failed to update backend quality: $e',
        name: 'SettingsNotifier',
      );
    }

    if (backendOk) {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      await prefs.setString(_streamQualityKey, quality);
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
