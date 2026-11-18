import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';

/// Characterization of the browse pages' paging window (A.16, written before
/// the window moved out of the view mixin): what a page shows and which
/// subscriptions are open as a person scrolls, as the window fails and is
/// retried, and while it is suspended. Driven through a real scrolling page
/// and scripted window streams, each of which reports whether it is being
/// listened to.
class _Window {
  _Window(this.limit) {
    controller = StreamController<List<int>>(
      onListen: () => listening = true,
      onCancel: () => listening = false,
    );
  }

  final int limit;
  late final StreamController<List<int>> controller;
  bool listening = false;

  /// The library holds [total] rows: answer with the first [limit] of them.
  void answer(int total) =>
      controller.add([for (var i = 0; i < math.min(total, limit); i++) i]);

  void fail() => controller.addError(StateError('query failed'));
}

class _Source {
  final windows = <_Window>[];

  Stream<List<int>> open(int limit) {
    final window = _Window(limit);
    windows.add(window);
    return window.controller.stream;
  }

  int get listening => windows.where((w) => w.listening).length;
  _Window get last => windows.last;
}

class _Page extends StatefulWidget {
  const _Page(this.source);

  final _Source source;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with CursorPaginationMixin<int> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 20;

  @override
  void initState() {
    super.initState();
    initPagination();
  }

  @override
  void dispose() {
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Stream<List<int>> watchPage({required int limit}) =>
      widget.source.open(limit);

  @override
  Widget build(BuildContext context) {
    if (paginationFailedEmpty) return buildPaginationFailure();
    if (paginationLoadedEmpty) return const Text('empty');
    return ListView.builder(
      controller: scrollController,
      itemCount: paginatedItems.length + (paginationHasTrailing ? 1 : 0),
      itemBuilder: (_, index) => index >= paginatedItems.length
          ? buildPaginationTrailing()
          : SizedBox(height: 50, child: Text('row ${paginatedItems[index]}')),
    );
  }
}

void main() {
  late _Source source;

  setUp(() => source = _Source());

  Future<_PageState> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _Page(source))));
    return tester.state<_PageState>(find.byType(_Page));
  }

  /// Past the 150 ms quiet period, so a held emission has landed and the
  /// quiet timer has lapsed.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 200));

  /// Scroll to the end of the list, as a person would.
  Future<void> scrollToEnd(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -10000));
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  }

  testWidgets('the first window is one page, subscribed once; until it '
      'answers the page shows only the loading slot', (tester) async {
    final page = await pumpPage(tester);
    expect(source.windows.map((w) => w.limit), [20]);
    expect(source.listening, 1);
    expect(page.hasMore, isTrue, reason: 'not settled yet');
    expect(page.paginationLoadedEmpty, isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    source.last.answer(100);
    await settle(tester);
    expect(find.text('row 0'), findsOneWidget);
    expect(page.paginatedItems, hasLength(20));
    expect(page.hasMore, isTrue, reason: 'a full window may have more');
    await unmount(tester);
  });

  testWidgets('scrolling to the end grows the window by one page, once per '
      'answer, with one subscription open at a time', (tester) async {
    final page = await pumpPage(tester);
    source.last.answer(100);
    await settle(tester);

    await scrollToEnd(tester);
    expect(source.windows.map((w) => w.limit), [20, 40]);
    expect(source.windows.first.listening, isFalse);
    expect(source.listening, 1);
    expect(page.isLoading, isTrue);

    // Still loading: more scrolling subscribes nothing new.
    await scrollToEnd(tester);
    expect(source.windows, hasLength(2));

    source.last.answer(100);
    await settle(tester);
    expect(page.isLoading, isFalse);
    expect(page.paginatedItems, hasLength(40));

    await scrollToEnd(tester);
    expect(source.windows.map((w) => w.limit), [20, 40, 60]);
    expect(source.listening, 1);
    source.last.answer(100);
    await settle(tester);
    await unmount(tester);
  });

  testWidgets('a short answer is the last page: no trailing slot, and '
      'scrolling to the end subscribes nothing more', (tester) async {
    final page = await pumpPage(tester);
    source.last.answer(100);
    await settle(tester);
    await scrollToEnd(tester);
    source.last.answer(35);
    await settle(tester);
    expect(page.paginatedItems, hasLength(35));
    expect(page.hasMore, isFalse);
    expect(page.paginationHasTrailing, isFalse);

    await scrollToEnd(tester);
    expect(find.text('row 34'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(source.windows, hasLength(2));
    await unmount(tester);
  });

  testWidgets('an empty answer settles as loaded and empty', (tester) async {
    final page = await pumpPage(tester);
    source.last.answer(0);
    await settle(tester);
    expect(page.paginationLoadedEmpty, isTrue);
    expect(find.text('empty'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the quiet period: the first answer shows at once, a burst is '
      'held, and the latest rows land when 150 ms have passed', (
    tester,
  ) async {
    final page = await pumpPage(tester);
    source.last.answer(3);
    await tester.pump();
    expect(page.paginatedItems, [0, 1, 2]);

    source.last.controller.add([7]);
    source.last.controller.add([8, 9]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.paginatedItems, [0, 1, 2], reason: 'held');
    await tester.pump(const Duration(milliseconds: 50));
    expect(page.paginatedItems, [8, 9], reason: 'the latest, not [7]');
    expect(find.text('row 9'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a failure keeps the rows, shows the short notice in the '
      'trailing slot, and scrolling does not retry', (tester) async {
    final page = await pumpPage(tester);
    source.last.answer(100);
    await settle(tester);
    await scrollToEnd(tester);
    expect(source.windows, hasLength(2));

    source.last.fail();
    await settle(tester);
    expect(page.paginationFailed, isTrue);
    expect(page.isLoading, isFalse);
    expect(page.hasMore, isFalse);
    expect(page.paginatedItems, hasLength(20), reason: 'rows kept');
    expect(page.paginationFailedEmpty, isFalse);
    expect(page.paginationLoadedEmpty, isFalse, reason: 'unknown, not empty');

    await scrollToEnd(tester);
    expect(find.text(LoadFailureNotice.libraryMessage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await scrollToEnd(tester);
    expect(source.windows, hasLength(2), reason: 'no retry on scroll');
    expect(page.paginationFailed, isTrue);
    await unmount(tester);
  });

  testWidgets('Retry resubscribes at the window size it had, closes the '
      'failed subscription, and the page is loading (not empty) until the '
      'answer', (tester) async {
    final page = await pumpPage(tester);
    source.last.answer(100);
    await settle(tester);
    await scrollToEnd(tester);
    source.last.fail();
    await settle(tester);
    expect(source.last.listening, isTrue,
        reason: 'a failed window stays subscribed until replaced');

    await scrollToEnd(tester);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(source.windows.map((w) => w.limit), [20, 40, 40]);
    expect(source.listening, 1);
    expect(page.paginationFailed, isFalse);
    expect(page.hasMore, isTrue);
    expect(find.text(LoadFailureNotice.libraryMessage), findsNothing);

    source.last.answer(100);
    await settle(tester);
    expect(page.paginatedItems, hasLength(40));
    await unmount(tester);
  });

  testWidgets('a failure with nothing loaded shows the full notice; Retry '
      'leaves it and the page is not empty until the window answers', (
    tester,
  ) async {
    final page = await pumpPage(tester);
    source.last.fail();
    await settle(tester);
    expect(page.paginationFailedEmpty, isTrue);
    expect(find.text(LoadFailureNotice.libraryMessage), findsOneWidget);
    expect(find.byType(ListView), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(source.windows.map((w) => w.limit), [20, 20]);
    expect(page.paginationLoadedEmpty, isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    source.last.answer(0);
    await settle(tester);
    expect(find.text('empty'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('an answer after a failure, on the same subscription, clears '
      'the failure', (tester) async {
    final page = await pumpPage(tester);
    source.last.fail();
    await settle(tester);
    expect(page.paginationFailed, isTrue);
    source.last.answer(5);
    await settle(tester);
    expect(page.paginationFailed, isFalse);
    expect(page.paginatedItems, hasLength(5));
    expect(source.windows, hasLength(1));
    await unmount(tester);
  });

  testWidgets('suspended: no subscription is open, scrolling and refresh '
      'subscribe nothing; resume starts again from page 1 at the top', (
    tester,
  ) async {
    final page = await pumpPage(tester);
    source.last.answer(100);
    await settle(tester);
    await scrollToEnd(tester);
    source.last.answer(100);
    await settle(tester);
    expect(page.scrollController.offset, greaterThan(0));

    page.suspendPagination();
    expect(source.listening, 0);
    await scrollToEnd(tester);
    page.refresh();
    expect(source.windows, hasLength(2));
    expect(page.paginatedItems, hasLength(40), reason: 'dormant rows kept');

    page.resumePagination();
    await tester.pump();
    expect(source.windows.map((w) => w.limit), [20, 40, 20]);
    expect(source.listening, 1);
    expect(page.scrollController.offset, 0);
    expect(page.paginatedItems, isEmpty);
    source.last.answer(100);
    await settle(tester);
    expect(page.paginatedItems, hasLength(20));
    await unmount(tester);
  });

  testWidgets('refresh starts again from page 1 with one subscription; '
      'leaving the page closes every subscription', (tester) async {
    final page = await pumpPage(tester);
    source.last.answer(100);
    await settle(tester);
    await scrollToEnd(tester);
    source.last.answer(100);
    await settle(tester);

    page.refresh();
    await tester.pump();
    expect(source.windows.map((w) => w.limit), [20, 40, 20]);
    expect(source.listening, 1);
    expect(page.paginatedItems, isEmpty);

    // Leave while an answer is held in the quiet period.
    source.last.answer(100);
    await tester.pump();
    source.last.answer(50);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.listening, 0);
    await settle(tester);
  });
}
