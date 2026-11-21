// Phase 8 spec §3 and §4 para 3; O6: whether Manage library may offer
// server deletion, and the typed-count rule. Model code: nothing from ui/.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';

enum ServerDeleteAvailability {
  /// The server's info is still loading.
  checking,

  /// No `library_tools` block: this server doesn't offer library tools.
  notOffered,

  /// `server_delete` is false: deletion is turned off on this server.
  switchedOff,

  /// Offline, or only the cached block is known: can't confirm now.
  unreachable,

  /// A live block says `server_delete` is true, and the app is online.
  enabled,
}

ServerDeleteAvailability serverDeleteAvailability({
  required bool loading,
  required AdvertisedFeature<LibraryToolsFeature>? advertised,
  required bool offline,
  bool failed = false,
}) {
  if (loading) return ServerDeleteAvailability.checking;
  // A failed server-info read is unknown, never "not offered".
  if (failed && advertised == null) return ServerDeleteAvailability.unreachable;
  if (advertised == null) return ServerDeleteAvailability.notOffered;
  if (!advertised.block.serverDelete) {
    return ServerDeleteAvailability.switchedOff;
  }
  return featureForNetwork(advertised) == null || offline
      ? ServerDeleteAvailability.unreachable
      : ServerDeleteAvailability.enabled;
}

/// [serverDeleteAvailability] from the library-tools block as
/// `libraryToolsFeatureProvider` holds it: loading while it has neither a
/// value nor an error; a failed read with no value is unknown.
ServerDeleteAvailability serverDeleteAvailabilityOf(
  AsyncValue<AdvertisedFeature<LibraryToolsFeature>?> feature, {
  required bool offline,
}) => serverDeleteAvailability(
  loading: !feature.hasValue && !feature.hasError,
  failed: feature.hasError && !feature.hasValue,
  advertised: feature.hasValue ? feature.value : null,
  offline: offline,
);

/// The user typed exactly [count] (spec §4 para 3, N > 1).
bool typedCountMatches(String typed, int count) => typed.trim() == '$count';
