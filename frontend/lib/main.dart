import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/scope_token_route.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_lifecycle_service.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frontend/ui/playback_wiring.dart';
import 'package:frontend/ui/startup_gate.dart';

export 'package:frontend/ui/shell/app_shell.dart' show AppShell;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase(openAppDatabase());
  final coverArtDirectory = await LocalCoverArtStore.ensureDirectory();
  // Process-wide disk cache for cover art, shared by every provider scope.
  // Its requests go through the live scope's token client at send time.
  final scopeTokenRoute = ScopeTokenRoute();
  final coverArtDiskCache = CacheManager(Config(DefaultCacheManager.key, fileService: HttpFileService(httpClient: scopeTokenRoute.client)));
  final audioHandler = await AudioService.init<AudioServiceBridge>(
    builder: () => AudioServiceBridge(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.osml.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    ),
  );
  // Which codecs this device can decode, asked once (review major 1).
  final codecSupport = await CodecSupport.probe();
  // The app's support folder holds the credential fallback file and the
  // session log file.
  final supportDirectory = await getApplicationSupportDirectory();
  // One credential store for the process. iOS keychain items survive an
  // uninstall, so a first launch with no prefs clears stale items (spec 7.1).
  final credentialStore = CredentialStore(
    secure: FlutterSecureCredentialBackend(),
    directory: supportDirectory,
  );
  await credentialStore.clearStaleAfterReinstall(
    isIOS: Platform.isIOS,
    hasPrefs: (await SharedPreferences.getInstance()).getKeys().isNotEmpty,
  );
  runApp(
    FrontendApp(
      credentialStore: credentialStore,
      sessionEventLog: SessionEventLogFile(supportDirectory),
      db: db,
      audioHandler: audioHandler,
      coverArtDirectory: coverArtDirectory,
      coverArtDiskCache: coverArtDiskCache,
      scopeTokenRoute: scopeTokenRoute,
      codecSupport: codecSupport,
    ),
  );
}

class FrontendApp extends StatefulWidget {
  final AppDatabase db;
  final AudioServiceBridge audioHandler;
  final Directory coverArtDirectory;
  final BaseCacheManager? coverArtDiskCache;
  final ScopeTokenRoute? scopeTokenRoute;
  final CodecSupport codecSupport;
  final Future<String?> Function()? loadSessionUrl;
  final CredentialStore credentialStore;

  /// The session event lines kept on disk; none in tests.
  final SessionEventLogFile? sessionEventLog;

  /// Test seam; defaults to [credentialStore]'s `read`.
  final Future<Credentials?> Function()? loadCredentials;
  @visibleForTesting
  final List<Override> testOverrides;

  const FrontendApp({
    super.key,
    required this.db,
    required this.audioHandler,
    required this.coverArtDirectory,
    this.coverArtDiskCache,
    this.scopeTokenRoute,
    this.codecSupport = const CodecSupport.unknown(),
    this.loadSessionUrl,
    required this.credentialStore,
    this.sessionEventLog,
    this.loadCredentials,
    this.testOverrides = const [],
  });

  @override
  State<FrontendApp> createState() => _FrontendAppState();
}

class _FrontendAppState extends State<FrontendApp> {
  // One transport for the app's lifetime, shared by every scope's clients.
  final http.Client _httpClient = http.Client();
  int _providerGeneration = 0;
  String? _sessionUrl;
  Credentials? _credentials;
  bool _credentialsUnavailable = false;
  bool _loaded = false;
  int _sessionRequest = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_onSessionChanged());
  }

  static Future<String?> _loadSavedUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(SessionService.serverUrlKey);
  }

  /// Re-reads the saved server URL and the stored credentials, then builds a
  /// fresh keyed scope from them (spec 7.2: credentials enter the scope before
  /// it is built).
  ///
  /// Only the newest call applies its result, so overlapping calls cannot
  /// let an older load replace a newer one. A failing URL load is logged and
  /// treated as no saved server; a failing credentials read is logged (without
  /// secrets) and treated as unavailable, so a scope is always built.
  Future<void> _onSessionChanged() async {
    final request = ++_sessionRequest;
    String? url;
    try {
      url = await (widget.loadSessionUrl ?? _loadSavedUrl)();
    } catch (e) {
      developer.log(
        'Could not load the saved server URL: ${e.runtimeType}',
        name: 'FrontendApp',
      );
    }
    Credentials? credentials;
    var unavailable = false;
    try {
      credentials = await (widget.loadCredentials ??
          widget.credentialStore.read)();
    } catch (e) {
      unavailable = true;
      developer.log(
        'Could not load the stored sign-in: ${e.runtimeType}',
        name: 'FrontendApp',
      );
    }
    if (!mounted || request != _sessionRequest) return;
    setState(() {
      _sessionUrl = url;
      _credentials = credentials;
      _credentialsUnavailable = unavailable;
      _loaded = true;
      _providerGeneration++;
    });
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    return ProviderScope(
      key: ValueKey(_providerGeneration),
      overrides: [
        databaseProvider.overrideWithValue(widget.db),
        audioServiceProvider.overrideWithValue(widget.audioHandler),
        coverArtDirectoryProvider.overrideWithValue(widget.coverArtDirectory),
        coverArtDiskCacheProvider.overrideWithValue(widget.coverArtDiskCache),
        if (widget.scopeTokenRoute != null)
          scopeTokenRouteProvider.overrideWithValue(widget.scopeTokenRoute!),
        codecSupportProvider.overrideWithValue(widget.codecSupport),
        httpClientProvider.overrideWithValue(_httpClient),
        sessionUrlProvider.overrideWithValue(_sessionUrl),
        credentialsProvider.overrideWithValue(_credentials),
        credentialsUnavailableProvider.overrideWithValue(
          _credentialsUnavailable,
        ),
        credentialStoreProvider.overrideWithValue(widget.credentialStore),
        onSessionChangedProvider.overrideWithValue(_onSessionChanged),
        // A 401 signs this scope out (spec 7.7): memory only.
        onUnauthorizedProvider.overrideWith(
          (ref) => ref.read(sessionServiceProvider).onUnauthorized,
        ),
        if (widget.sessionEventLog != null)
          sessionEventLogFileProvider.overrideWithValue(widget.sessionEventLog),
        ...widget.testOverrides,
      ],
      child: const Frontend(),
    );
  }
}

class Frontend extends ConsumerStatefulWidget {
  const Frontend({super.key});

  @override
  ConsumerState<Frontend> createState() => _FrontendState();
}

class _FrontendState extends ConsumerState<Frontend>
    with WidgetsBindingObserver {
  // Stored so dispose can deregister exactly the same listener. Doing
  // `ref.read(...).enterOffline` twice yields equal tear-offs in practice,
  // but capturing once removes any doubt.
  late final void Function() _offlineListener;
  late final ApiClient _apiClient;
  // Keeps the OS media-session wiring alive for this provider scope (SC-27);
  // a reset builds a new keyed scope, and so a fresh subscription.
  late final ProviderSubscription<PlaybackWiring> _playbackWiring;

  @override
  void initState() {
    super.initState();
    // Bridge ApiClient's transport-failure hook into the offline-mode notifier.
    // Lives here (not in main()) because the notifier requires a ProviderScope.
    _offlineListener = ref.read(offlineModeProvider.notifier).enterOffline;
    _apiClient = ref.read(apiClientProvider);
    _apiClient.addNetworkFailureListener(_offlineListener);
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
    _apiClient.removeNetworkFailureListener(_offlineListener);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      ref.read(appLifecycleServiceProvider).changed(state);

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
      home: StartupGate(),
    );
  }
}
