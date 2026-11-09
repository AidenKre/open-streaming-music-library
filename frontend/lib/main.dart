import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frontend/ui/playback_wiring.dart';
import 'package:frontend/ui/startup_gate.dart';

export 'package:frontend/ui/shell/app_shell.dart' show AppShell;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final savedUrl = prefs.getString(SessionService.serverUrlKey);
  if (savedUrl != null) {
    ApiClient.init(savedUrl);
  }
  final db = AppDatabase(openAppDatabase());
  final coverArtStore = await LocalCoverArtStore.create();
  initCoverArtCache(CoverArtCacheManager(localStore: coverArtStore));
  final audioHandler = await AudioService.init<AudioServiceBridge>(
    builder: () => AudioServiceBridge(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.osml.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    ),
  );
  runApp(
    FrontendApp(
      db: db,
      audioHandler: audioHandler,
      coverArtStore: coverArtStore,
    ),
  );
}

class FrontendApp extends StatefulWidget {
  final AppDatabase db;
  final AudioServiceBridge audioHandler;
  final LocalCoverArtStore coverArtStore;

  const FrontendApp({
    super.key,
    required this.db,
    required this.audioHandler,
    required this.coverArtStore,
  });

  @override
  State<FrontendApp> createState() => _FrontendAppState();
}

class _FrontendAppState extends State<FrontendApp> {
  int _providerGeneration = 0;

  void _resetProviderScope() {
    setState(() => _providerGeneration++);
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      key: ValueKey(_providerGeneration),
      overrides: [
        databaseProvider.overrideWithValue(widget.db),
        audioServiceProvider.overrideWithValue(widget.audioHandler),
        localCoverArtStoreProvider.overrideWithValue(widget.coverArtStore),
      ],
      child: Frontend(onLocalResetComplete: _resetProviderScope),
    );
  }
}

class Frontend extends ConsumerStatefulWidget {
  final VoidCallback? onLocalResetComplete;

  const Frontend({super.key, this.onLocalResetComplete});

  @override
  ConsumerState<Frontend> createState() => _FrontendState();
}

class _FrontendState extends ConsumerState<Frontend>
    with WidgetsBindingObserver {
  // Stored so dispose can deregister exactly the same listener. Doing
  // `ref.read(...).enterOffline` twice yields equal tear-offs in practice,
  // but capturing once removes any doubt.
  late final void Function() _offlineListener;
  // Keeps the OS media-session wiring alive for this provider scope (SC-27);
  // a reset builds a new keyed scope, and so a fresh subscription.
  late final ProviderSubscription<PlaybackWiring> _playbackWiring;

  @override
  void initState() {
    super.initState();
    // Bridge ApiClient's transport-failure hook into the offline-mode notifier.
    // Lives here (not in main()) because the notifier requires a ProviderScope.
    _offlineListener = ref.read(offlineModeProvider.notifier).enterOffline;
    ApiClient.addNetworkFailureListener(_offlineListener);
    WidgetsBinding.instance.addObserver(this);
    _playbackWiring = ref.listenManual(playbackWiringProvider, (_, _) {});
    // Cold-start recovery. On this edge that means reconciling stale
    // `tracks.file_path` rows whose underlying files were removed outside the
    // app; UI consumers refresh through `downloadStatusVersionProvider` when
    // something actually changes. Fire-and-forget — recovery never throws.
    unawaited(
      ref.read(recoveryServiceProvider).runFor(RecoveryTrigger.coldStart),
    );
    // The scope starts in the foreground: the history poll may run.
    ref.read(historySyncTriggersProvider).setForeground(true);
  }

  @override
  void dispose() {
    _playbackWiring.close();
    WidgetsBinding.instance.removeObserver(this);
    ApiClient.removeNetworkFailureListener(_offlineListener);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref
        .read(historySyncTriggersProvider)
        .setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref.read(recoveryServiceProvider).runFor(RecoveryTrigger.appResume),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Recovery side effects live here, not inside the offline notifier, so the
    // notifier stays focused on local-only state. When the app leaves offline
    // mode, kick the work that was paused while we were dark (sync, then resume
    // downloads) through the recovery registry.
    //
    // This `true → false` transition is the *only* firing of
    // `networkRecovered`, which is what keeps the reset carve-out working: a
    // local reset cancels health polling via `cancelOfflinePolling()` WITHOUT
    // flipping the flag, so this listener never runs mid-wipe. See
    // `_OfflineExitResettable` in `local_reset_service.dart`.
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev == true && next == false) {
        unawaited(
          ref
              .read(recoveryServiceProvider)
              .runFor(RecoveryTrigger.networkRecovered),
        );
      }
    });
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OSML',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: StartupGate(onLocalResetComplete: widget.onLocalResetComplete),
    );
  }
}
