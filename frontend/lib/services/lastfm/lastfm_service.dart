// The Last.fm account model (spec §7.4). No ui/ import; logs nothing. The
// authorization URL is never logged, kept in state or put into an error.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/lastfm_api.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/lastfm/lastfm_errors.dart';

sealed class LastfmAccount {
  const LastfmAccount();
}

/// The server does not offer Last.fm (no `integrations.lastfm` entry).
class LastfmNotOffered extends LastfmAccount {
  const LastfmNotOffered();
}

/// Only a cached `integrations` block is known: nothing was asked.
class LastfmUnreachable extends LastfmAccount {
  const LastfmUnreachable({required this.available});
  final bool available;
}

class LastfmKnown extends LastfmAccount {
  const LastfmKnown({required this.status, required this.available});
  final LastfmStatus status;
  final bool available;
}

/// The state is read once at build (session start) and again after every
/// action that reached the API; that is how Now Playing learns of changes
/// made on the Integrations page.
class LastfmService extends AsyncNotifier<LastfmAccount> {
  StreamSubscription<void>? _rearm;
  int _builds = 0;

  /// After a failed status read: one re-read on the next verified edge.
  /// At most one is armed; a successful read leaves none.
  void _armReread(LastfmApi api, Object error) {
    _rearm?.cancel();
    _rearm = api.verifiedAgain.listen((_) {
      _rearm?.cancel();
      _rearm = null;
      if (ref.mounted) ref.invalidateSelf();
    });
    // The verified edge may have passed before the listener existed.
    if (error is BindingNotVerified && api.isVerifiedNow) {
      _rearm?.cancel();
      _rearm = null;
      // After the failed read has been delivered, not instead of it.
      final builds = _builds;
      Future.microtask(() {
        if (ref.mounted && builds == _builds) ref.invalidateSelf();
      });
    }
  }

  @override
  Future<LastfmAccount> build() async {
    ref.onDispose(() {
      _rearm?.cancel();
      _rearm = null;
    });
    _rearm?.cancel();
    _rearm = null;
    final mine = ++_builds;
    final advertised = await ref.watch(integrationsFeatureProvider.future);
    final lastfm = advertised?.block.lastfm;
    if (advertised == null || lastfm == null) return const LastfmNotOffered();
    if (featureForNetwork(advertised) == null) {
      return LastfmUnreachable(available: lastfm.available);
    }
    final api = ref.read(lastfmApiProvider);
    try {
      final status = await api.status();
      return LastfmKnown(status: status, available: lastfm.available);
    } on Object catch (e) {
      // A superseded build (the provider rebuilt meanwhile) arms nothing.
      if (ref.mounted && mine == _builds) _armReread(api, e);
      throw LastfmException.from(e);
    }
  }

  /// Nothing is sent unless the server's live block offers Last.fm. Returns
  /// the block's `available` flag.
  Future<bool> _precondition() async {
    final advertised = await ref.read(integrationsFeatureProvider.future);
    final lastfm = advertised?.block.lastfm;
    if (advertised == null || lastfm == null) {
      throw const LastfmException(LastfmProblem.notOffered);
    }
    if (featureForNetwork(advertised) == null) {
      throw const LastfmException(LastfmProblem.unreachable);
    }
    return lastfm.available;
  }

  /// Reads the status once and publishes it; null when the read failed (the
  /// state then holds the typed error) or the scope is gone.
  Future<LastfmStatus?> _reread(LastfmApi api, bool available) async {
    try {
      final status = await api.status();
      if (!ref.mounted) return null;
      _rearm?.cancel();
      _rearm = null;
      state = AsyncData(LastfmKnown(status: status, available: available));
      return status;
    } on Object catch (e, st) {
      if (!ref.mounted) return null;
      _armReread(api, e);
      state = AsyncError(LastfmException.from(e), st);
      return null;
    }
  }

  /// Runs [call], then re-reads the status; the call's own result or error
  /// is what the caller sees.
  Future<T> _act<T>(Future<T> Function(LastfmApi api) call) async {
    final available = await _precondition();
    if (!ref.mounted) throw const LastfmException(LastfmProblem.failed);
    final api = ref.read(lastfmApiProvider);
    final T result;
    try {
      result = await call(api);
    } on Object catch (e) {
      if (ref.mounted) await _reread(api, available);
      throw LastfmException.from(e);
    }
    if (ref.mounted) await _reread(api, available);
    return result;
  }

  Future<LastfmAuthorization> connect() async {
    final a = await _act((api) => api.connect());
    if (a == null) throw const LastfmException(LastfmProblem.badAnswer);
    return a;
  }

  /// `complete`. After a 410, and only then, the status re-read decides:
  /// a connected account with `needs_reconnect == false` is success.
  Future<LastfmCompleted> finish() async {
    final available = await _precondition();
    if (!ref.mounted) throw const LastfmException(LastfmProblem.failed);
    final api = ref.read(lastfmApiProvider);
    final LastfmCompleted? done;
    try {
      done = await api.complete();
    } on Object catch (e) {
      final status = ref.mounted ? await _reread(api, available) : null;
      if (e is ApiException &&
          e.statusCode == 410 &&
          status != null &&
          status.isConnected &&
          status.needsReconnect == false &&
          status.connectionId != null &&
          status.accountName != null) {
        return LastfmCompleted(
          connectionId: status.connectionId!,
          accountName: status.accountName!,
          state: status.state,
        );
      }
      throw LastfmException.from(e);
    }
    if (ref.mounted) await _reread(api, available);
    if (done == null) throw const LastfmException(LastfmProblem.badAnswer);
    return done;
  }

  Future<void> enable(String connectionId) =>
      _act((api) => api.enable(connectionId));

  Future<void> disconnect() => _act((api) => api.disconnect());
}

final lastfmServiceProvider =
    // No automatic retry: a failed read is a typed error the page shows.
    AsyncNotifierProvider<LastfmService, LastfmAccount>(
      LastfmService.new,
      retry: (_, _) => null,
    );

/// Whether Settings → Library tools shows the Integrations row (spec
/// §7.12). No block: no row, and nothing is asked. `available`: the row.
/// `available: false`: the row only for a user who still has a connection
/// (read from the status route).
final lastfmIntegrationsEntryProvider = Provider<bool>((ref) {
  final lastfm = ref.watch(integrationsFeatureProvider).value?.block.lastfm;
  if (lastfm == null) return false;
  if (lastfm.available) return true;
  final account = ref.watch(lastfmServiceProvider).value;
  return account is LastfmKnown && account.status.isConnected;
});
