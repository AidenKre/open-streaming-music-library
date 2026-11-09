import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
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
/// * The history poll runs only in the foreground. On desktop a visible
///   window without focus (`inactive`) still counts as foreground (5A M6):
///   only a hidden window is background there. On mobile `inactive` is a
///   transient interruption (shade, app switcher, call) and is background.
/// * Resuming runs app-resume recovery.
/// * A started listen recorder checkpoints when the app leaves the
///   foreground (D35); none is built from here.
class AppLifecycleService {
  AppLifecycleService(this._ref);
  final Ref _ref;

  void changed(AppLifecycleState state) {
    _ref
        .read(historySyncTriggersProvider)
        .setForeground(_isForeground(state));
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

bool _isForeground(AppLifecycleState state) => switch (state) {
      AppLifecycleState.resumed => true,
      AppLifecycleState.inactive => _isDesktop,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached =>
        false,
    };

bool get _isDesktop => switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };

final appLifecycleServiceProvider =
    Provider<AppLifecycleService>((ref) => AppLifecycleService(ref));
