import 'dart:async';
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
    bool clearStreamQualityChangeKind = false,
  }) {
    return AppSettings(
      persistedStreamQuality:
          persistedStreamQuality ?? this.persistedStreamQuality,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      temporaryStreamQuality:
          clearTemporary ? null : (temporaryStreamQuality ?? this.temporaryStreamQuality),
      streamQualityChangeKind: clearStreamQualityChangeKind
          ? null
          : (streamQualityChangeKind ?? this.streamQualityChangeKind),
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

  /// Hard cap on a single backend-sync attempt. The reconciliation runs
  /// asynchronously after [build] returns, so this no longer gates first
  /// paint — it just bounds how long any one network attempt blocks the
  /// follow-up state update before we fall back to the cached pref.
  @visibleForTesting
  static Duration backendSyncTimeout = const Duration(seconds: 3);

  /// Test seam: completes when the post-build backend reconciliation
  /// settles (success or swallowed failure). Tests await this to assert on
  /// the final state without races against the unawaited sync.
  @visibleForTesting
  Future<void> get debugBackendSyncDone => _syncDone.future;
  Completer<void> _syncDone = Completer<void>();

  @override
  Future<AppSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final local = _read(prefs);

    // Publish local prefs immediately so consumers (download default,
    // restored playback quality, settings UI) don't sit on the `original`
    // fallback while the backend sync is in flight. The backend remains
    // the source of truth for stream quality and is reconciled below.
    _syncDone = Completer<void>();
    Future.microtask(() => _reconcileFromBackend(prefs, local));
    return local;
  }

  Future<void> _reconcileFromBackend(
    SharedPreferences prefs,
    AppSettings initial,
  ) async {
    try {
      final reconciled = await _syncQualityFromBackend(initial, prefs);
      if (identical(reconciled, initial) || reconciled == initial) return;
      // If the user changed stream quality while the sync was in flight,
      // their choice wins — drop the late backend value.
      final current = state.value;
      if (current == null) return;
      if (current.persistedStreamQuality != initial.persistedStreamQuality) {
        return;
      }
      // A backend reconcile is a silent sync — clear any pending change-kind so
      // the AudioCoordinator's streamQualityProvider listener doesn't mistake
      // it for a user-initiated full/temporary change and rebuild the playlist.
      state = AsyncData(
        current.copyWith(
          persistedStreamQuality: reconciled.persistedStreamQuality,
          clearStreamQualityChangeKind: true,
        ),
      );
    } finally {
      if (!_syncDone.isCompleted) _syncDone.complete();
    }
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
      // Single-attempt policy bounded by backendSyncTimeout: a slow or
      // unreachable backend must not strand the reconcile forever, and
      // exhaustion still goes through the offline hook so a real outage
      // flips the app into offline mode like any other GET would.
      final data = await ApiClient.instance.getJson(
        ['settings', 'quality'],
        policy: RetryPolicy.noRetry.copyWith(
          perAttemptTimeout: backendSyncTimeout,
        ),
      );
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

  /// Current settings, or the default fallback when state hasn't loaded yet.
  /// Shared by the mutators so the fallback construction lives in one place.
  AppSettings get _current =>
      state.value ??
      const AppSettings(
        persistedStreamQuality: _defaultQuality,
        downloadQuality: _defaultQuality,
      );

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

    state = AsyncData(
      _current.copyWith(
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
    state = AsyncData(
      _current.copyWith(
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
    state = AsyncData(_current.copyWith(downloadQuality: quality));
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Synchronous read of the current effective stream quality (temporary takes
/// precedence over persisted). Falls back to `original` only while the
/// SharedPreferences read is in flight — once [SettingsNotifier.build]
/// returns, the local pref is published and the backend reconciliation
/// runs asynchronously without holding this provider on `original`.
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
