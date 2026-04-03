import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';
import 'package:frontend/ui/widgets/library_card.dart';

/// Forces [offlineModeProvider] to a fixed value without starting the real
/// health-poll timer.
class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

Widget _harness({
  required Widget child,
  bool offline = false,
}) {
  return ProviderScope(
    overrides: [
      offlineModeProvider.overrideWith(() => _StubOffline(offline)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 200, height: 280, child: child),
      ),
    ),
  );
}

LibraryCard _build({
  String title = 'Test Title',
  String? subtitle,
  Widget cover = const ColoredBox(color: Color(0xFFEEEEEE)),
  VoidCallback? onTap,
  VoidCallback? onPlayNext,
  VoidCallback? onAddToQueue,
  VoidCallback? onDownload,
  void Function(String)? onDownloadAtQuality,
  VoidCallback? onDeleteDownload,
  bool isDownloading = false,
  ({int downloaded, int total}) counts = (downloaded: 0, total: 10),
  String playNextLabel = 'Play Next',
  String addToQueueLabel = 'Add to Queue',
  String downloadLabel = 'Download',
  String deleteDownloadLabel = 'Delete downloads',
}) {
  return LibraryCard(
    cover: cover,
    title: title,
    subtitle: subtitle,
    onTap: onTap ?? () {},
    onPlayNext: onPlayNext,
    onAddToQueue: onAddToQueue,
    onDownload: onDownload,
    onDownloadAtQuality: onDownloadAtQuality,
    onDeleteDownload: onDeleteDownload,
    isDownloading: isDownloading,
    downloadCounts: AsyncValue.data(counts),
    playNextLabel: playNextLabel,
    addToQueueLabel: addToQueueLabel,
    downloadLabel: downloadLabel,
    deleteDownloadLabel: deleteDownloadLabel,
  );
}

void main() {
  group('LibraryCard rendering', () {
    testWidgets('renders title, subtitle, and cover', (tester) async {
      const coverKey = Key('cover-content');
      await tester.pumpWidget(_harness(
        child: _build(
          title: 'Hello',
          subtitle: 'World',
          cover: const ColoredBox(
            key: coverKey,
            color: Color(0xFF112233),
          ),
        ),
      ));

      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('World'), findsOneWidget);
      expect(find.byKey(coverKey), findsOneWidget);
    });

    testWidgets('omits subtitle node when subtitle is null', (tester) async {
      await tester.pumpWidget(_harness(
        child: _build(title: 'Solo'),
      ));
      // Only the title Text should appear in the padding column.
      expect(find.text('Solo'), findsOneWidget);
    });

    testWidgets('fires onTap when tapped', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_harness(
        child: _build(onTap: () => tapped++),
      ));

      await tester.tap(find.byType(LibraryCard));
      await tester.pumpAndSettle();
      expect(tapped, 1);
    });
  });

  group('LibraryCard download badges', () {
    testWidgets(
      'renders DownloadedBadge when counts indicate full download',
      (tester) async {
        await tester.pumpWidget(_harness(
          child: _build(counts: (downloaded: 10, total: 10)),
        ));
        await tester.pumpAndSettle();

        expect(find.byType(DownloadedBadge), findsOneWidget);
        expect(find.byType(DownloadProgressBadge), findsNothing);
      },
    );

    testWidgets(
      'renders DownloadProgressBadge when isDownloading and not full',
      (tester) async {
        await tester.pumpWidget(_harness(
          child: _build(
            isDownloading: true,
            counts: (downloaded: 3, total: 10),
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.byType(DownloadProgressBadge), findsOneWidget);
        expect(find.text('3/10'), findsOneWidget);
        expect(find.byType(DownloadedBadge), findsNothing);
      },
    );

    testWidgets(
      'no badge when not downloading and nothing downloaded',
      (tester) async {
        await tester.pumpWidget(_harness(
          child: _build(counts: (downloaded: 0, total: 10)),
        ));
        await tester.pumpAndSettle();

        expect(find.byType(DownloadedBadge), findsNothing);
        expect(find.byType(DownloadProgressBadge), findsNothing);
      },
    );
  });

  group('LibraryCard long-press menu', () {
    testWidgets('shows all menu items with configured labels', (tester) async {
      await tester.pumpWidget(_harness(
        child: _build(
          onPlayNext: () {},
          onAddToQueue: () {},
          onDownload: () {},
          onDeleteDownload: () {},
          counts: (downloaded: 3, total: 10),
          playNextLabel: 'Queue First',
          addToQueueLabel: 'Enqueue',
          downloadLabel: 'Save',
          deleteDownloadLabel: 'Remove downloads',
        ),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.text('Queue First'), findsOneWidget);
      expect(find.text('Enqueue'), findsOneWidget);
      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.text('Remove downloads'), findsOneWidget);
    });

    testWidgets('hides menu items when their callbacks are null',
        (tester) async {
      await tester.pumpWidget(_harness(
        child: _build(
          onPlayNext: () {},
          // onAddToQueue intentionally omitted
          // onDownload intentionally omitted
          // onDeleteDownload intentionally omitted
          counts: (downloaded: 3, total: 10),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsNothing);
      expect(find.byType(SplitDownloadTile), findsNothing);
      expect(find.text('Delete downloads'), findsNothing);
    });

    testWidgets('no long-press handler when no callbacks provided',
        (tester) async {
      await tester.pumpWidget(_harness(
        child: _build(),
      ));
      await tester.pumpAndSettle();

      // Long-press should not crash and should not open a menu.
      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('hides Download tile when fully downloaded', (tester) async {
      await tester.pumpWidget(_harness(
        child: _build(
          onDownload: () {},
          onDeleteDownload: () {},
          counts: (downloaded: 10, total: 10),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsNothing);
      expect(find.text('Delete downloads'), findsOneWidget);
    });

    testWidgets('hides Delete when nothing is downloaded', (tester) async {
      await tester.pumpWidget(_harness(
        child: _build(
          onDownload: () {},
          onDeleteDownload: () {},
          counts: (downloaded: 0, total: 10),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(LibraryCard));
      await tester.pumpAndSettle();

      expect(find.byType(SplitDownloadTile), findsOneWidget);
      expect(find.text('Delete downloads'), findsNothing);
    });

    testWidgets(
      'offline + partially downloaded: queue actions disabled',
      (tester) async {
        await tester.pumpWidget(_harness(
          offline: true,
          child: _build(
            onPlayNext: () {},
            onAddToQueue: () {},
            onDeleteDownload: () {},
            counts: (downloaded: 3, total: 10),
          ),
        ));
        await tester.pumpAndSettle();

        await tester.longPress(find.byType(LibraryCard));
        await tester.pumpAndSettle();

        final playNext = tester.widget<ListTile>(find.ancestor(
          of: find.text('Play Next'),
          matching: find.byType(ListTile),
        ));
        expect(playNext.enabled, isFalse);
      },
    );
  });
}
