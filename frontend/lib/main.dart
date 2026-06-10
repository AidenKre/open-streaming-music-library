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
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/startup_gate.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final savedUrl = prefs.getString('serverUrl');
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

class _FrontendState extends ConsumerState<Frontend> with WidgetsBindingObserver {
  // Stored so dispose can deregister exactly the same listener. Doing
  // `ref.read(...).enterOffline` twice yields equal tear-offs in practice,
  // but capturing once removes any doubt.
  late final void Function() _offlineListener;

  @override
  void initState() {
    super.initState();
    // Bridge ApiClient's transport-failure hook into the offline-mode notifier.
    // Lives here (not in main()) because the notifier requires a ProviderScope.
    _offlineListener = ref.read(offlineModeProvider.notifier).enterOffline;
    ApiClient.addNetworkFailureListener(_offlineListener);
    WidgetsBinding.instance.addObserver(this);
    // Fire-and-forget: clears stale `tracks.file_path` rows whose underlying
    // files were removed outside the app. UI consumers refresh through
    // `downloadStatusVersionProvider` when something actually changes.
    unawaited(ref.read(downloadReconciliationServiceProvider).reconcile());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ApiClient.removeNetworkFailureListener(_offlineListener);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(downloadReconciliationServiceProvider).reconcile());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Recovery side effects live here, not inside the offline notifier, so the
    // notifier stays focused on local-only state. When the app leaves offline
    // mode, kick the work that was paused while we were dark.
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev == true && next == false) {
        ref.read(trackSyncProvider.notifier).sync();
        ref.read(downloadManagerProvider).resumeIfPaused();
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

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _tabIndex = 0;
  final _tracksKey = GlobalKey<TracksPageState>();

  final _navigatorKeys = [
    GlobalKey<NavigatorState>(debugLabel: 'artists'),
    GlobalKey<NavigatorState>(debugLabel: 'tracks'),
    GlobalKey<NavigatorState>(debugLabel: 'downloads'),
    GlobalKey<NavigatorState>(debugLabel: 'search'),
  ];

  Widget _buildTabNavigator(int index, Widget Function() rootBuilder) {
    return Navigator(
      key: _navigatorKeys[index],
      onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => rootBuilder()),
    );
  }

  void _onTabTap(int index) {
    if (index == _tabIndex) {
      _navigatorKeys[index].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tabIndex = index);
      if (index == 1) _tracksKey.currentState?.sync();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = ref.watch(offlineModeProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navigatorKeys[_tabIndex].currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _tabIndex,
                children: [
                  _buildTabNavigator(
                    0,
                    () => const ArtistsPage(isRoot: true),
                  ),
                  _buildTabNavigator(
                    1,
                    () => TracksPage(key: _tracksKey, isRoot: true),
                  ),
                  _buildTabNavigator(2, () => const DownloadedTracksPage()),
                  _buildTabNavigator(3, () => const SearchPage()),
                ],
              ),
            ),
            if (isOffline) const OfflineBanner(),
            const MiniPlayer(),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: _onTabTap,
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: "Artists"),
            BottomNavigationBarItem(
              icon: Icon(Icons.music_note),
              label: "Tracks",
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.download_done),
              label: "Downloads",
            ),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: "Search"),
          ],
        ),
      ),
    );
  }
}
