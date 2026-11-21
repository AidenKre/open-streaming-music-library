import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/editable_fields.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/local_reset_service.dart';

const _cacheKey = 'appInfo.cache';

/// Intrinsic audio facts that are NEVER user-editable, regardless of what the
/// server advertises — a client-side safety lock on top of the server's
/// allowlist. They are display-only info rows on the Get Info page.
const intrinsicAudioFields = {
  'codec',
  'duration',
  'bitrate_kbps',
  'sample_rate_hz',
  'channels',
};

/// Conservative built-in default used on a cold-offline start (no server, no
/// cache): exactly the Phase-1 advertised track tag fields, from the single
/// client field list (which also derives the optimistic-write gate). Keeps
/// the Get Info form usable offline without ever advertising more than the
/// server would.
AppInfo defaultAppInfo() => const AppInfo(entities: {
      'track': EntityInfo(fields: defaultEditableTrackFields),
    });

/// The fields a user may actually edit for [entity]: advertised-and-editable,
/// minus the intrinsic audio lock.
List<FieldDescriptor> editableFieldsFor(AppInfo info, String entity) {
  final e = info.entity(entity);
  if (e == null) return const [];
  return e.fields
      .where((f) => f.editable && !intrinsicAudioFields.contains(f.key))
      .toList();
}

class AppInfoService {
  AppInfoService(this._ref, this._prefs, {required ApiClient api})
      : _api = api;

  final Ref _ref;
  final SharedPreferences _prefs;
  final ApiClient _api;

  /// Resolve the capabilities blob: refresh from the server when online (and
  /// cache it), fall back to the cached copy offline, and finally to the
  /// conservative built-in default when there is no cache at all.
  Future<AppInfo> load() async {
    final online = _api.baseUrl.isNotEmpty && !_ref.read(offlineModeProvider);
    if (online) {
      try {
        // A reset that begins meanwhile must win over this late answer.
        final generation = _ref.read(localResetServiceProvider).generation;
        final data = await _api.getJson(
          ['app', 'info'],
          policy: RetryPolicy.noRetry,
        );
        final info = AppInfo.fromJson(data);
        if (!_ref.mounted ||
            _ref.read(localResetServiceProvider).generation != generation) {
          return info;
        }
        await _prefs.setString(_cacheKey, jsonEncode(data));
        return info;
      } catch (e) {
        developer.log('app/info refresh failed: $e', name: 'AppInfoService');
        // fall through to the cache
      }
    }
    return _cachedOrDefault();
  }

  AppInfo _cachedOrDefault() {
    final raw = _prefs.getString(_cacheKey);
    if (raw != null) {
      try {
        return AppInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>)
            .asCached();
      } catch (e) {
        developer.log('app/info cache parse failed: $e', name: 'AppInfoService');
      }
    }
    return defaultAppInfo().asBuiltInDefault();
  }
}

/// Cached app capabilities. Refreshed each time it is (re)read while online;
/// the Get Info page watches it.
final appInfoProvider = FutureProvider<AppInfo>((ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  return AppInfoService(
    ref,
    prefs,
    // A public, user-independent path: never send the token (m-R3-11).
    api: ref.read(publicApiClientProvider),
  ).load();
});
