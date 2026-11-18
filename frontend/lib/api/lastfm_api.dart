import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// The `/settings/integrations/lastfm` transport (spec §7.4).
///
/// Every call goes through the bound client. [status] and [nowPlaying] fail
/// fast: while the binding is not verified now they throw
/// [BindingNotVerified] at once (9-R1-38). The user's own actions
/// ([connect], [complete], [enable], [disconnect]) wait up to
/// [userActionVerdictWait] for a pending verdict (9-R2-03), but still fail at
/// once on a settled negative one. An answer from another instance is
/// reported to the gate and rethrown.
/// The authorization URL arrives in [connect]'s answer: it must never be
/// logged or stored. This class logs nothing.
class LastfmApi {
  LastfmApi({required ApiClient api, required ServerBindingGate gate})
    : _api = api,
      _gate = gate;

  final ApiClient _api;
  final ServerBindingGate _gate;

  /// An event each time the gate publishes a verified state: the moment a
  /// failed status read is worth trying again.
  Stream<void> get verifiedAgain =>
      _gate.states.where((s) => s is BindingVerified).map((_) {});

  /// The binding is verified right now AND the token client's own rule
  /// allows a request to this server (online): a failed status read is
  /// re-read at once only then; offline it waits for the next verified edge,
  /// the reconnect (sign-off OPEN-M-11, E9 review: no re-read loop).
  bool get isVerifiedNow =>
      _gate.isVerifiedNow && _gate.allowsTokenTo(Uri.parse(_api.baseUrl));

  static const _base = ['settings', 'integrations', 'lastfm'];

  /// connect/complete: one attempt, 45 seconds, and a timeout is not the
  /// device being offline (spec §7.8).
  static const _slowOnce = RetryPolicy(
    maxAttempts: 1,
    perAttemptTimeout: Duration(seconds: 45),
    triggerOfflineHook: false,
  );

  /// now-playing: never retried; a failure is not shown (spec §7.10).
  static const _fireOnce = RetryPolicy(
    maxAttempts: 1,
    triggerOfflineHook: false,
  );

  Future<LastfmStatus> status() => sendWhenVerified(_gate, wait: BindingWait.failFast, url: Uri.parse(_api.baseUrl), () async {
    final json = await _api.getJson(_base);
    return LastfmStatus.fromJson(json);
  });

  Future<LastfmAuthorization?> connect() => sendWhenVerified(_gate, wait: BindingWait.forPendingVerdict, url: Uri.parse(_api.baseUrl), () async {
    final json = await _api.postJson(
      [..._base, 'connect'],
      body: const {},
      policy: _slowOnce,
    );
    return LastfmAuthorization.fromJson(json);
  });

  Future<LastfmCompleted?> complete() => sendWhenVerified(_gate, wait: BindingWait.forPendingVerdict, url: Uri.parse(_api.baseUrl), () async {
    final json = await _api.postJson(
      [..._base, 'complete'],
      body: const {},
      policy: _slowOnce,
    );
    return LastfmCompleted.fromJson(json);
  });

  Future<void> enable(String connectionId) => sendWhenVerified(_gate, wait: BindingWait.forPendingVerdict, url: Uri.parse(_api.baseUrl), () async {
    await _api.postJson(
      [..._base, 'enable'],
      body: {'connection_id': connectionId},
    );
  });

  Future<void> disconnect() => sendWhenVerified(_gate, wait: BindingWait.forPendingVerdict, url: Uri.parse(_api.baseUrl), () async {
    await _api.deleteJson(_base);
  });

  /// While the binding is not verified now the notice is dropped (spec
  /// §7.10 queues nothing for later).
  Future<void> nowPlaying(String trackUuid) async {
    if (!_gate.isVerifiedNow) return;
    return sendWhenVerified(_gate, wait: BindingWait.failFast, () async {
      await _api.postJson(
          [..._base, 'now-playing'],
          body: {'track_uuid': trackUuid},
          policy: _fireOnce,
        );
      });
  }
}

final lastfmApiProvider = Provider<LastfmApi>(
  (ref) => LastfmApi(
    api: ref.read(boundApiClientProvider),
    gate: ref.read(serverBindingGateProvider),
  ),
);
