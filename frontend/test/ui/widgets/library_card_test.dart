import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';
import 'package:frontend/ui/widgets/library_card.dart';

import '../fake_library_actions.dart';

/// Forces [offlineModeProvider] to a fixed value without starting the real
/// health-poll timer.
class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

Widget _harness({required Widget child, bool offline = false}) {
  return ProviderScope(
    overrides: [offlineModeProvider.overrideWith(() => _StubOffline(offline))],
    child: MaterialApp(
      home: Scaffold(body: SizedBox(width: 200, height: 280, child: child)),
    ),
  );
}

/// The card under test, with the menu the real builder makes for an album
/// with [counts] (or an explicit [menu]).
LibraryCard _build({
  String title = 'Test Title',
  String? subtitle,
  Widget cover = const ColoredBox(color: Color(0xFFEEEEEE)),
  VoidCallback? onTap,
  bool isDownloading = false,
  bool offline = false,
  ({int downloaded, int total}) counts = (downloaded: 0, total: 10),
  List<LibraryMenuEntry>? menu,
  FakeLibraryActions? actions,
}) {
  return LibraryCard(
    cover: cover,
    title: title,
    subtitle: subtitle,
    onTap: onTap ?? () {},
    menu:
        menu ??
        buildLibraryActionMenu(
          const AlbumScope(artistId: 1, albumId: 2),
          PlaybackAvailability.of(
            offline: offline,
            downloaded: counts.downloaded,
            total: counts.total,
          ),
          actions: actions ?? FakeLibraryActions(),
        ),
    isDownloading: isDownloading,
    downloadCounts: AsyncValue.data(counts),
    availability: PlaybackAvailability.of(
      offline: offline,
      downloaded: counts.downloaded,
      total: counts.total,
    ),
  );
}

void main() {
  group('LibraryCard rendering', () {
    testWidgets('renders title, subtitle, and cover', (tester) async {
      const coverKey = Key('cover-content');
      await tester.pumpWidget(
        _harness(
          child: _build(
            title: 'Hello',
            subtitle: 'World',
            cover: const ColoredBox(key: coverKey, color: Color(0xFF112233)),
          ),
        ),
      );

      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('World'), findsOneWidget);
      expect(find.byKey(coverKey), findsOneWidget);
    });

    testWidgets('omits subtitle node when subtitle is null', (tester) async {
      await tester.pumpWidget(_harness(child: _build(title: 'Solo')));
      // Only the title Text should appear in the padding column.
      expect(find.text('Solo'), findsOneWidget);
    });

    // Audit 4A(c) #7 (phase-4 §5: keyboard activation).
    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      testWidgets('keyboard: Tab focuses the card, ${key.keyLabel} activates '
          'it', (tester) async {
        var tapped = 0;
        await tester.pumpWidget(_harness(child: _build(onTap: () => tapped++)));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(key);
        await tester.pump();
        expect(tapped, 1);
      });
    }

    testWidgets('fires onTap when tapped', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_harness(child: _build(onTap: () => tapped++)));

      await tester.tap(find.byType(LibraryCard));
      await tester.pumpAndSettle();
      expect(tapped, 1);
    });
  });

  group('LibraryCard download badges', () {
    testWidgets('renders DownloadedBadge when counts indicate full download', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(child: _build(counts: (downloaded: 10, total: 10))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DownloadedBadge), findsOneWidget);
      expect(find.byType(DownloadProgressBadge), findsNothing);
    });

    testWidgets(
      'renders DownloadProgressBadge when isDownloading and not full',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            child: _build(
              isDownloading: true,
              counts: (downloaded: 3, total: 10),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(DownloadProgressBadge), findsOneWidget);
        expect(find.text('3/10'), findsOneWidget);
        expect(find.byType(DownloadedBadge), findsNothing);
      },
    );

    testWidgets('no badge when not downloading and nothing downloaded', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(child: _build(counts: (downloaded: 0, total: 10))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DownloadedBadge), findsNothing);
      expect(find.byType(DownloadProgressBadge), findsNothing);
    });
  });

  group('LibraryCard long-press menu', () {
    testWidgets('shows the builder menu for a partially downloaded album', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(child: _build(counts: (downloaded: 3, total: 10))),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsOneWidget);
      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.text('Delete downloads'), findsOneWidget);
    });

    testWidgets('renders exactly the entries it is given', (tester) async {
      await tester.pumpWidget(
        _harness(
          child: _build(
            menu: [
              LibraryMenuAction(
                icon: Icons.playlist_play,
                label: 'Play Next',
                onSelected: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsNothing);
      expect(find.byType(SplitDownloadTile), findsNothing);
      expect(find.text('Delete downloads'), findsNothing);
    });

    testWidgets('no long-press menu when the menu is empty', (tester) async {
      await tester.pumpWidget(_harness(child: _build(menu: const [])));
      await tester.pumpAndSettle();

      // Long-press should not crash and should not open a menu.
      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('hides Download tile when fully downloaded', (tester) async {
      await tester.pumpWidget(
        _harness(child: _build(counts: (downloaded: 10, total: 10))),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsNothing);
      expect(find.text('Delete downloads'), findsOneWidget);
    });

    testWidgets('hides Delete when nothing is downloaded', (tester) async {
      await tester.pumpWidget(
        _harness(child: _build(counts: (downloaded: 0, total: 10))),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.text('Delete downloads'), findsNothing);
    });

    testWidgets('offline + partially downloaded: queue actions disabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          offline: true,
          child: _build(offline: true, counts: (downloaded: 3, total: 10)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      final playNext = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Play Next'),
          matching: find.byType(ListTile),
        ),
      );
      expect(playNext.enabled, isFalse);
    });

    testWidgets('an entry acts on the card scope via the controller', (
      tester,
    ) async {
      final actions = FakeLibraryActions();
      await tester.pumpWidget(_harness(child: _build(actions: actions)));
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['download album(1,2)']);
    });
  });

  testWidgets(
    'the downloaded badge follows PlaybackAvailability, not raw counts',
    (tester) async {
      // Counts still loading, availability already known (one predicate).
      await tester.pumpWidget(
        _harness(
          child: LibraryCard(
            cover: const SizedBox(),
            title: 'T',
            onTap: () {},
            isDownloading: false,
            downloadCounts: const AsyncLoading(),
            availability: PlaybackAvailability.of(
              offline: false,
              downloaded: 2,
              total: 2,
            ),
          ),
        ),
      );
      expect(find.byType(DownloadedBadge), findsOneWidget);
    },
  );

  testWidgets(
    'no downloaded badge when availability is not full, whatever the counts say',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          child: LibraryCard(
            cover: const SizedBox(),
            title: 'T',
            onTap: () {},
            isDownloading: false,
            downloadCounts: const AsyncData((downloaded: 2, total: 2)),
            availability: const PlaybackAvailability.unknown(offline: false),
          ),
        ),
      );
      expect(find.byType(DownloadedBadge), findsNothing);
    },
  );
}
