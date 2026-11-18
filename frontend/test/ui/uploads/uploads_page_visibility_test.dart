// Phase 7 §7 ("Leaving Uploads does not cancel active transfer; explicit
// cancel does") and the 7B.1d visibility seam: the page drives polling —
// visible while it is open and the app is in the foreground, not visible
// when it is left or the app goes to the background. Leaving the route
// cancels and quiesces nothing.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/services/uploads/uploads_visibility.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';
import 'package:frontend/ui/uploads/uploads_page.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';
import '../fake_uploads_controls.dart';

class _RecordingManager implements UploadManager {
  final calls = <String>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('${invocation.memberName}');
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  /// A root page with a button that pushes the Uploads page.
  Widget app(List<Object> overrides) => harness.wrap(
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const UploadsPage()),
          ),
          child: const Text('open'),
        ),
      ),
    ),
    overrides: [
      sessionControlsProvider.overrideWithValue(FakeSessionControls()),
      ...overrides.cast(),
    ],
  );

  group('with a fake controller', () {
    late FakeUploadsControls fake;
    setUp(() => fake = FakeUploadsControls(overview: fakeUploadsOverview(const [])));

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        app([uploadsControllerFactoryProvider.overrideWithValue(() => fake)]),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('opening the page makes it visible', (tester) async {
      await open(tester);
      expect(fake.visibility, [true]);
      await teardownTree(tester);
    });

    testWidgets('background hides it, foreground shows it again',
        (tester) async {
      await open(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(fake.visibility.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fake.visibility.last, isTrue);
      await teardownTree(tester);
    });

    testWidgets('a desktop window losing focus (inactive) is still visible',
        (tester) async {
      await open(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(fake.visibility, isNot(contains(false)));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await teardownTree(tester);
    });

    testWidgets('leaving disposes the controller and cancels nothing',
        (tester) async {
      await open(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(UploadsPage), findsNothing);
      expect(fake.disposed, isTrue);
      expect(fake.calls, isEmpty);
      await teardownTree(tester);
    });
  });

  testWidgets('real controller: leave and re-enter; polling follows the page, '
      'the manager is never cancelled or quiesced', (tester) async {
    final manager = _RecordingManager();
    final visibility = NotifierUploadsVisibility();
    addTearDown(visibility.dispose);
    await tester.pumpWidget(
      app([
        uploadManagerProvider.overrideWithValue(manager),
        uploadsVisibilityProvider.overrideWithValue(visibility),
        uploadsOverviewProvider.overrideWith(
          (ref) => fakeUploadsOverview([fakeUploadRow('a', cancel: true)]),
        ),
      ]),
    );
    expect(visibility.visible.value, isFalse);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(visibility.visible.value, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(visibility.visible.value, isFalse);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(visibility.visible.value, isTrue);
    expect(find.byKey(const ValueKey('upload-row-a')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(visibility.visible.value, isFalse);
    expect(manager.calls, isEmpty);
    await teardownTree(tester);
  });
}
