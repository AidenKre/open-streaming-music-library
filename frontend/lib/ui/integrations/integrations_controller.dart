// Phase 9 §7.12: the Integrations page's input and presentation state
// (SC-26). Page-scoped: created when the page opens, disposed when it
// closes. Every rule (what may be offered, the words for a problem row, the
// links) lives in the model; this controller forwards and translates.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/models/track_names.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/lastfm/lastfm_errors.dart';
import 'package:frontend/services/lastfm/lastfm_links.dart';
import 'package:frontend/services/lastfm/lastfm_page_policy.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';

enum IntegrationsLoad {
  /// The first status read is running.
  loading,

  /// The status read failed: [IntegrationsView.loadError] says why.
  failed,

  /// The server does not offer Last.fm.
  notOffered,

  /// Only a cached block is known (offline or the server unreachable).
  unreachable,

  /// The status is known.
  known,
}

/// One row of the "did not go through" list.
@immutable
class IntegrationsProblemView {
  const IntegrationsProblemView({
    required this.artist,
    required this.track,
    required this.listenedAt,
    required this.reason,
  });
  final String artist;
  final String track;

  /// UTC milliseconds.
  final int listenedAt;

  /// OSML's words (model: `lastfmProblemReason`).
  final String reason;
}

@immutable
class IntegrationsView {
  const IntegrationsView({
    required this.load,
    this.loadError,
    this.status,
    this.available = false,
    this.online = true,
    this.offer,
    this.problems = const [],
  });

  final IntegrationsLoad load;
  final String? loadError;

  /// Known only when [load] is `known`.
  final LastfmStatus? status;

  /// The block's `available` (false when unknown).
  final bool available;
  final bool online;

  /// Known only when [load] is `known`.
  final LastfmPageOffer? offer;
  final List<IntegrationsProblemView> problems;
}

abstract interface class IntegrationsControls implements Listenable {
  IntegrationsView get view;

  /// An action is running; every other action is ignored meanwhile.
  bool get busy;

  /// The last action's outcome text (an error in OSML's words), or null.
  String? get message;

  /// Reads the status again.
  Future<void> refresh();

  /// Asks the server for an approval and opens it in the system browser.
  Future<void> connect();

  /// Finish connecting after the approval on last.fm.
  Future<void> finish();

  /// The opt-in confirmation: start scrobbling for the current connection.
  Future<void> enable();

  Future<void> disconnect();

  Future<void> openCredit();
  Future<void> openTerms();
  Future<void> openPrivacy();

  /// Opens the connected account's profile.
  Future<void> openProfile();

  void dispose();
}

typedef IntegrationsFactory = IntegrationsControls Function();

final integrationsControllerFactoryProvider = Provider<IntegrationsFactory>(
  (ref) =>
      () => IntegrationsController(ref),
);

const _browserMessage = "Couldn't open your browser.";

/// An action the binding refused (9-R2-11): nothing was sent. The load error
/// says why; these words only say the tap changed nothing.
const _notConnectedYetMessage =
    "Nothing was changed: the app wasn't connected to your server yet. Try again.";
const _nothingChangedMessage = 'Nothing was changed.';

class IntegrationsController extends ChangeNotifier
    implements IntegrationsControls {
  IntegrationsController(this._ref) {
    _subs = [
      _ref.container.listen(
        lastfmServiceProvider,
        (prev, next) {
          // An automatic recovery keeps the action's words (9-R2-05).
          _recompute();
        },
        fireImmediately: false,
      ),
      _ref.container.listen(
        offlineModeProvider,
        (prev, next) => _recompute(),
      ),
    ];
    _view = _compute();
  }

  final Ref _ref;
  late final List<ProviderSubscription<Object?>> _subs;
  late IntegrationsView _view;
  bool _disposed = false;
  bool _busy = false;
  String? _message;

  @override
  IntegrationsView get view => _view;

  @override
  bool get busy => _busy;

  @override
  String? get message => _message;

  IntegrationsView _compute() {
    final async = _ref.container.read(lastfmServiceProvider);
    final online = !_ref.container.read(offlineModeProvider);
    // Reloading from an error (or with nothing known): loading, not the
    // stale error. A reload from a known value keeps showing it.
    if (async.isLoading && (async.hasError || !async.hasValue)) {
      return IntegrationsView(load: IntegrationsLoad.loading, online: online);
    }
    if (async.hasError) {
      final problem = LastfmException.from(async.error!).problem;
      return IntegrationsView(
        load: IntegrationsLoad.failed,
        loadError: lastfmProblemText(problem),
        online: online,
      );
    }
    final account = async.value;
    if (account == null) {
      return IntegrationsView(load: IntegrationsLoad.loading, online: online);
    }
    return switch (account) {
      LastfmNotOffered() => IntegrationsView(
        load: IntegrationsLoad.notOffered,
        online: online,
      ),
      LastfmUnreachable(:final available) => IntegrationsView(
        load: IntegrationsLoad.unreachable,
        available: available,
        online: online,
      ),
      LastfmKnown(:final status, :final available) => IntegrationsView(
        load: IntegrationsLoad.known,
        status: status,
        available: available,
        online: online,
        offer: LastfmPageOffer.of(
          status: status,
          available: available,
          online: online,
        ),
        problems: [
          for (final row in status.recentProblems)
            IntegrationsProblemView(
              artist: row.artist ?? unknownArtistName,
              track: trackTitleOrUnknown(row.track),
              listenedAt: row.listenedAt,
              reason: lastfmProblemReason(row),
            ),
        ],
      ),
    };
  }

  void _recompute() {
    if (_disposed) return;
    _view = _compute();
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    if (_disposed) return;
    _message = null;
    notifyListeners();
    _ref.invalidate(lastfmServiceProvider);
  }

  /// [tooSoon]: this action's own words for the server's too-soon answer.
  Future<void> _act(
    bool Function(LastfmPageOffer o) allowed,
    Future<void> Function() run, {
    String? tooSoon,
  }) async {
    final offer = _view.offer;
    if (_disposed || _busy || offer == null || !allowed(offer)) return;
    _message = null;
    _busy = true;
    notifyListeners();
    try {
      await run();
    } on Object catch (e) {
      final problem = LastfmException.from(e);
      _message = switch (problem.problem) {
        LastfmProblem.needsConnection => _notConnectedYetMessage,
        LastfmProblem.differentServer ||
        LastfmProblem.signedOut => _nothingChangedMessage,
        LastfmProblem.tooSoon when tooSoon != null => tooSoon,
        _ => _words(problem),
      };
    }
    _busy = false;
    if (!_disposed) notifyListeners();
  }

  static String _words(LastfmException e) {
    final b = StringBuffer(lastfmProblemText(e.problem));
    if (e.problem == LastfmProblem.accountMismatch) {
      if (e.storedAccount != null) {
        b.write(' Connected account: ${e.storedAccount}.');
      }
      if (e.approvedAccount != null) {
        b.write(' Approved account: ${e.approvedAccount}.');
      }
    }
    return b.toString();
  }

  LastfmService get _service => _ref.read(lastfmServiceProvider.notifier);

  @override
  Future<void> connect() => _act((o) => o.canConnect, () async {
    final auth = await _service.connect();
    if (_disposed) return;
    final opened = await _ref
        .read(lastfmLinksProvider)
        .openAuthorization(auth.url);
    if (!opened) _message = _browserMessage;
  });

  @override
  Future<void> finish() => _act(
    (o) => o.canFinish,
    () async => _service.finish(),
    tooSoon: lastfmFinishTooSoonText,
  );

  @override
  Future<void> enable() => _act(
    (o) => o.canOptIn,
    () async => _service.enable(_view.status!.connectionId!),
  );

  @override
  Future<void> disconnect() => _act(
    (o) => o.canDisconnect,
    () async => _service.disconnect(),
  );

  Future<void> _link(Future<bool> Function(LastfmLinks l) open) async {
    if (_disposed) return;
    final ok = await open(_ref.read(lastfmLinksProvider));
    if (_disposed) return;
    if (!ok) {
      _message = _browserMessage;
      notifyListeners();
    }
  }

  @override
  Future<void> openCredit() => _link((l) => l.openCredit());

  @override
  Future<void> openTerms() => _link((l) => l.openTerms());

  @override
  Future<void> openPrivacy() => _link((l) => l.openPrivacy());

  @override
  Future<void> openProfile() {
    final name = _view.status?.accountName;
    if (name == null) return Future.value();
    return _link((l) => l.openProfile(name));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      s.close();
    }
    super.dispose();
  }
}
