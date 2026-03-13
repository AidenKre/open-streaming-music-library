import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/queue_resolver.dart';
import 'package:frontend/providers/audio/window_manager.dart';
import 'package:frontend/providers/providers.dart';

final audioWindowProvider = Provider<AudioWindowController>((ref) {
  return WindowManager.create();
});

final audioQueueLookupProvider = Provider<AudioQueueLookup>((ref) {
  return QueueResolver(ref.read(databaseProvider));
});

/// Provided via ProviderScope override in main.dart.
final audioServiceProvider = Provider<AudioServiceBridge>((ref) {
  throw UnimplementedError('audioServiceProvider must be overridden');
});
