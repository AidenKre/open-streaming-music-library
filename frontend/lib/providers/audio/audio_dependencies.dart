import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/concatenating_player_controller.dart';

final concatenatingPlayerProvider =
    Provider<ConcatenatingPlayerController>((ref) {
  final controller = ConcatenatingPlayerController.create();
  ref.onDispose(controller.dispose);
  return controller;
});

final audioServiceProvider = Provider<AudioServiceBridge>((ref) {
  throw UnimplementedError('audioServiceProvider must be overridden');
});
