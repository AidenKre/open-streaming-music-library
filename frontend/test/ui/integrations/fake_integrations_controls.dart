// A scripted Integrations controller for page tests (9D.2e). Records every
// input; does no I/O.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/ui/integrations/integrations_page.dart';
import 'package:frontend/services/lastfm/lastfm_page_policy.dart';
import 'package:frontend/ui/integrations/integrations_controller.dart';

import '../../helpers/fake_lastfm_api.dart' show lastfmStatus;

class FakeIntegrationsControls extends ChangeNotifier
    implements IntegrationsControls {
  FakeIntegrationsControls(this._view);

  /// A known view for [status], with the model's real offer.
  factory FakeIntegrationsControls.known(
    LastfmStatus status, {
    bool available = true,
    bool online = true,
    List<IntegrationsProblemView> problems = const [],
  }) => FakeIntegrationsControls(
    knownView(status, available: available, online: online, problems: problems),
  );

  IntegrationsView _view;
  bool _busy = false;
  String? _message;
  final calls = <String>[];
  bool disposed = false;

  @override
  IntegrationsView get view => _view;
  set view(IntegrationsView v) {
    _view = v;
    notifyListeners();
  }

  @override
  bool get busy => _busy;
  set busy(bool v) {
    _busy = v;
    notifyListeners();
  }

  @override
  String? get message => _message;
  set message(String? v) {
    _message = v;
    notifyListeners();
  }

  @override
  Future<void> refresh() async => calls.add('refresh');
  @override
  Future<void> connect() async => calls.add('connect');
  @override
  Future<void> finish() async => calls.add('finish');
  @override
  Future<void> enable() async => calls.add('enable');
  @override
  Future<void> disconnect() async => calls.add('disconnect');
  @override
  Future<void> openCredit() async => calls.add('openCredit');
  @override
  Future<void> openTerms() async => calls.add('openTerms');
  @override
  Future<void> openPrivacy() async => calls.add('openPrivacy');
  @override
  Future<void> openProfile() async => calls.add('openProfile');

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

IntegrationsView knownView(
  LastfmStatus status, {
  bool available = true,
  bool online = true,
  List<IntegrationsProblemView> problems = const [],
}) => IntegrationsView(
  load: IntegrationsLoad.known,
  status: status,
  available: available,
  online: online,
  offer: LastfmPageOffer.of(
    status: status,
    available: available,
    online: online,
  ),
  problems: problems,
);

/// Pumps the Integrations page over [fake] (tall enough for every row).
Future<void> pumpIntegrations(
  WidgetTester tester,
  FakeIntegrationsControls fake,
) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        integrationsControllerFactoryProvider.overrideWithValue(() => fake),
      ],
      child: const MaterialApp(home: IntegrationsPage()),
    ),
  );
  await tester.pump();
}

/// Finds a widget by its string key.
Finder byKey(String key) => find.byKey(Key(key));

/// A status as the server sends it (helper re-export for page tests).
LastfmStatus status({
  String service = 'running',
  String state = 'enabled',
  Object? needsReconnect = false,
  String? account = 'listener_01',
  String? appName,
}) => lastfmStatus(
  service: service,
  state: state,
  needsReconnect: needsReconnect,
  account: account,
  appName: appName,
);
