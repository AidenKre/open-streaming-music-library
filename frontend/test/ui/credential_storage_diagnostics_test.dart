// Phase M §7.1 / decision O4 (DEV-M-04, M-U19 store): the credential store
// "reports [the fallback] in diagnostics". Settings → Sync & storage gets a
// row that observes the store's status: secure storage, or the owner-only
// file and why (an unsigned or ad-hoc build answering -34018).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/ui/settings/credential_storage_diagnostics_view.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';

import '../helpers/fake_secure_backend.dart';
import 'browse_harness.dart';

const _alice = Credentials(
  token: 'api-token-A',
  mediaToken: 'media-token-A',
  userId: 7,
  username: 'alice',
);

void main() {
  late Directory dir;
  late FakeSecureBackend secure;
  late CredentialStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cred_diag_test_');
    secure = FakeSecureBackend();
    store = CredentialStore(secure: secure, directory: dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester, WidgetBuilder build) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [credentialStoreProvider.overrideWithValue(store)],
          child: MaterialApp(
            home: Scaffold(body: Builder(builder: build)),
          ),
        ),
      );

  test('the row is contributed to Sync & storage', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(diagnosticsRowsProvider).map((r) => r.id),
      contains(credentialStorageDiagnosticsRow.id),
    );
  });

  testWidgets('says the fallback file is in use, and why', (tester) async {
    secure.makeUnusable();
    await tester.runAsync(() => store.save(_alice));
    await pump(tester, credentialStorageDiagnosticsRow.buildDetail);
    expect(find.textContaining('owner-only file'), findsOneWidget);
    expect(find.textContaining('-34018'), findsOneWidget);
    expect(find.textContaining('api-token-A'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('says secure storage is in use', (tester) async {
    await tester.runAsync(() => store.save(_alice));
    await pump(tester, credentialStorageDiagnosticsRow.buildSummary);
    expect(find.textContaining('secure storage'), findsOneWidget);
    expect(find.textContaining('file'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('follows the store when its status changes', (tester) async {
    await tester.runAsync(() => store.save(_alice));
    await pump(tester, credentialStorageDiagnosticsRow.buildDetail);
    expect(find.textContaining('owner-only file'), findsNothing);
    secure.makeUnusable();
    await tester.runAsync(() => store.save(_alice));
    await tester.pump();
    expect(find.textContaining('owner-only file'), findsOneWidget);
    await teardownTree(tester);
  });
}
