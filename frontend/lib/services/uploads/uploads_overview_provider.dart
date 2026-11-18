// The live Uploads page state (spec §7 para 3): the current binding's
// intents, the running transfers' progress, the offline flag, the session's
// server block and the uploads feature block, combined into one
// [UploadsOverview]. Model code: nothing from ui/.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

/// [listenable]'s value, re-read whenever it changes.
T _live<T>(Ref ref, ValueListenable<T> listenable) {
  void onChange() => ref.invalidateSelf();
  listenable.addListener(onChange);
  ref.onDispose(() => listenable.removeListener(onChange));
  return listenable.value;
}

/// Bytes sent per running transfer (the upload manager's progress), live.
final uploadProgressProvider = Provider<Map<String, int>>(
  (ref) => _live(ref, ref.watch(uploadManagerProvider).progress),
);

/// The server's per-item `retryable` flags (the upload manager's), live.
final uploadRetryableProvider = Provider<Map<String, bool>>(
  (ref) => _live(ref, ref.watch(uploadManagerProvider).retryable),
);

/// The batches another device is sending (the upload manager's), live.
final uploadOtherDeviceSendingProvider = Provider<Set<String>>(
  (ref) => _live(ref, ref.watch(uploadManagerProvider).otherDeviceSending),
);

/// Why the session's network features are paused, live.
final uploadsServerBlockedProvider = Provider<ServerBlockedReason>(
  (ref) => _live(ref, ref.watch(sessionServiceProvider).serverBlocked),
);

/// What the Uploads page shows; null until the intents have loaded.
final uploadsOverviewProvider = Provider<UploadsOverview?>((ref) {
  // Listened (not watched) so the block starts loading with the intents
  // without rebuilding this provider while they are still on their way.
  ref.listen(uploadsFeatureProvider, (_, _) {});
  final intents = ref.watch(uploadIntentsProvider).value;
  if (intents == null) return null;
  final featureAsync = ref.watch(uploadsFeatureProvider);
  // An error counts as no block, not as loading.
  final feature = featureAsync.value;
  return UploadsOverview.of(
    intents: intents,
    progress: ref.watch(uploadProgressProvider),
    retryable: ref.watch(uploadRetryableProvider),
    otherDeviceSending: ref.watch(uploadOtherDeviceSendingProvider),
    availability: uploadsAvailability(
      offline: ref.watch(offlineModeProvider),
      blocked: ref.watch(uploadsServerBlockedProvider),
      feature: feature,
      // Loading only before the first answer: a refresh keeps the value.
      featureLoading: !featureAsync.hasValue && !featureAsync.hasError,
    ),
    limits: feature?.block.limits,
    transfersPaused: ref.watch(streamsUnavailableNowProvider),
  );
});
