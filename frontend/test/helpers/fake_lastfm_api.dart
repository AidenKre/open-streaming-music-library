// A scripted LastfmApi for model tests (9D.2d). No network. Every value is
// made up.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/lastfm_api.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';

const fakeLastfmKey = '0123456789abcdef0123456789abcdef';
const fakeLastfmToken = 'made-up-token';
const fakeLastfmUrl =
    'https://www.last.fm/api/auth/?api_key=$fakeLastfmKey&token=$fakeLastfmToken';
const fakeConnectionId = 'c0ffee00-0000-4000-8000-000000000001';

/// A status body as the 9D.1d server sends it. [counts] null sends no
/// numbers (each count unknown); the other optional fields are sent as given
/// (R-332-12).
LastfmStatus lastfmStatus({
  String service = 'running',
  String state = 'enabled',
  Object? needsReconnect = false,
  String? account = 'listener_01',
  String? connectionId = fakeConnectionId,
  String? appName,
  int? approvalExpiresAt,
  Object? counts = const {
    'pending': 0,
    'sent': 0,
    'ignored': 0,
    'failed': 0,
    'dropped': 0,
  },
  List<Object?> recentProblems = const [],
  int? lastSuccessAt,
}) => LastfmStatus.fromJson({
  'service': service,
  'state': state,
  'needs_reconnect': needsReconnect,
  'account_name': account,
  'connection_id': connectionId,
  'approval_expires_at': approvalExpiresAt,
  'counts': counts,
  'recent_problems': recentProblems,
  'last_success_at': lastSuccessAt,
  // Omitted when null: a server without LASTFM_APP_NAME support (DEV-9-06).
  'app_name': ?appName,
});

/// An SC-22 error answer.
ApiException lastfmApiError(
  int status,
  String code, {
  bool retryable = false,
  Map<String, Object?> extra = const {},
  String message = 'server text that is never shown',
}) => ApiException(
  status,
  jsonEncode({
    'detail': {
      'error': code,
      'message': message,
      'retryable': retryable,
      ...extra,
    },
  }),
);

class FakeLastfmApi implements LastfmApi {
  final calls = <String>[];

  final _verified = StreamController<void>.broadcast();

  /// What [isVerifiedNow] answers.
  bool verifiedNow = false;

  @override
  bool get isVerifiedNow => verifiedNow;

  /// Publishes one "the gate verified a connection" edge.
  void verifyAgain() => _verified.add(null);

  /// How many listeners wait for a verified edge (0 once their scope is gone).
  int get verifiedListeners => _verifiedListeners;
  int _verifiedListeners = 0;

  @override
  Stream<void> get verifiedAgain => Stream<void>.multi((out) {
    _verifiedListeners++;
    final sub = _verified.stream.listen(out.add);
    out.onCancel = () {
      _verifiedListeners--;
      return sub.cancel();
    };
  });

  Future<LastfmStatus> Function() onStatus = () async => lastfmStatus();
  Future<LastfmAuthorization?> Function() onConnect = () async =>
      LastfmAuthorization.fromJson(
          {'authorization_url': fakeLastfmUrl, 'expires_at': 1800000600000});
  Future<LastfmCompleted?> Function() onComplete = () async =>
      LastfmCompleted.fromJson({
        'connection_id': fakeConnectionId,
        'account_name': 'listener_01',
        'state': 'connected_disabled',
      });
  Future<void> Function(String connectionId) onEnable = (_) async {};
  Future<void> Function() onDisconnect = () async {};
  Future<void> Function(String trackUuid) onNowPlaying = (_) async {};

  @override
  Future<LastfmStatus> status() {
    calls.add('status');
    return onStatus();
  }

  @override
  Future<LastfmAuthorization?> connect() {
    calls.add('connect');
    return onConnect();
  }

  @override
  Future<LastfmCompleted?> complete() {
    calls.add('complete');
    return onComplete();
  }

  @override
  Future<void> enable(String connectionId) {
    calls.add('enable $connectionId');
    return onEnable(connectionId);
  }

  @override
  Future<void> disconnect() {
    calls.add('disconnect');
    return onDisconnect();
  }

  @override
  Future<void> nowPlaying(String trackUuid) {
    calls.add('nowPlaying $trackUuid');
    return onNowPlaying(trackUuid);
  }
}

/// The `integrations` block as a live answer (`fromCache: false`).
AdvertisedFeature<IntegrationsFeature> liveIntegrations({
  bool available = true,
}) => AdvertisedFeature(
  IntegrationsFeature(
    version: 1,
    lastfm: LastfmIntegration(available: available),
  ),
  fromCache: false,
);

/// Overrides for a scope with [api] and the given block (null = absent).
List<Override> lastfmOverrides(
  FakeLastfmApi api, {
  AdvertisedFeature<IntegrationsFeature>? block,
  bool absent = false,
}) => [
  lastfmApiProvider.overrideWithValue(api),
  integrationsFeatureProvider.overrideWith(
    (ref) async => absent ? null : (block ?? liveIntegrations()),
  ),
];
