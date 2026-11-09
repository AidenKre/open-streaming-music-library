import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/history/listen_recorder.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';

/// The one place app lifecycle changes reach the models (Phase 5 §7
/// "explicit lifecycle service"); the app's binding observer only
/// forwards. App lifecycle is not player lifecycle: backgrounding never
/// pauses or stops playback.
///
/// * The history poll runs only in the foreground.
/// * Resuming runs app-resume recovery.
/// * A started listen recorder checkpoints when the app leaves the
///   foreground (D35); none is built from here.
class AppLifecycleService {
  AppLifecycleService(this._ref);
  final Ref _ref;

  void changed(AppLifecycleState state) {
    _ref
        .read(historySyncTriggersProvider)
        .setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(
        _ref.read(recoveryServiceProvider).runFor(RecoveryTrigger.appResume),
      );
    }
    if (_ref.exists(listenRecorderProvider)) {
      unawaited(_ref.read(listenRecorderProvider).appLifecycleChanged(state));
    }
  }
}

final appLifecycleServiceProvider =
    Provider<AppLifecycleService>((ref) => AppLifecycleService(ref));
