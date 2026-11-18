import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/browse_filter_controller.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/mixins/root_browse_mixin.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';

import '../../helpers/test_offline.dart';
import '../fake_library_search_controls.dart';

/// U29-A-11: root browsing tested on its own, through a minimal host page
/// (no repository, no database). The page tests cover the same wiring
/// through the real pages; this pins the mixin's own rules: the first
/// window reads the chip, a chip change or an offline flip re-runs the mode
/// on screen, search mode suspends the window and leaving it resumes from
/// page 1, download events reach only a search snapshot, and dispose
/// releases both controllers.
class _Host extends ConsumerStatefulWidget {
  const _Host({
    required this.watch,
    this.controls = true,
    this.refreshOnOfflineChange = false,
  });

  final Stream<List<String>> Function(int limit, bool downloadedOnly) watch;
  final bool controls;
  final bool refreshOnOfflineChange;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host>
    with CursorPaginationMixin<String>, RootBrowseMixin<_Host, String> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 2;

  @override
  void initState() {
    super.initState();
    if (widget.controls) initRootBrowse(type: SearchType.tracks);
    initPagination();
  }

  @override
  void dispose() {
    disposeRootBrowse();
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Stream<List<String>> watchPage({required int limit}) =>
      widget.watch(limit, filters.downloaded);

  @override
  Widget build(BuildContext context) {
    listenForBrowseChanges(
      refreshOnOfflineChange: widget.refreshOnOfflineChange,
    );
    if (isSearchMode) return const Text('search mode');
    if (showDownloadedEmpty) return const Text('downloaded empty');
    return ListView(
      controller: scrollController,
      children: [for (final item in paginatedItems) Text(item)],
    );
  }
}

void main() {
  late StreamController<List<String>> rows;
  late StreamController<int> downloadVersions;
  late List<({int limit, bool downloadedOnly})> watches;
  late TestOffline offline;
  late ValueNotifier<bool> hostShown;
  FakeLibrarySearchControls? search;
  BrowseFilterControls? filterControls;

  setUp(() {
    rows = StreamController<List<String>>.broadcast();
    downloadVersions = StreamController<int>.broadcast();
    watches = [];
    search = null;
    filterControls = null;
    hostShown = ValueNotifier(true);
  });

  tearDown(() async {
    await rows.close();
    await downloadVersions.close();
    hostShown.dispose();
  });

  Stream<List<String>> watch(int limit, bool downloadedOnly) {
    watches.add((limit: limit, downloadedOnly: downloadedOnly));
    return rows.stream.map((all) => all.take(limit).toList());
  }

  Future<_HostState> pumpHost(
    WidgetTester tester, {
    bool startOffline = false,
    bool controls = true,
    bool refreshOnOfflineChange = false,
  }) async {
    offline = TestOffline(startOffline);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          offlineModeProvider.overrideWith(() => offline),
          downloadStatusVersionProvider.overrideWith(
            (ref) => downloadVersions.stream,
          ),
          browseFilterControllerFactoryProvider.overrideWith(
            (ref) =>
                ({policy = OfflineFilterPolicy.autoApply, initial}) =>
                    filterControls = BrowseFilterController(
                      ref,
                      policy: policy,
                      initial: initial,
                    ),
          ),
          librarySearchControllerFactoryProvider.overrideWithValue(
            ({required types, required limitPerType, required downloadedOnly}) =>
                search = FakeLibrarySearchControls(
                  types: types,
                  limitPerType: limitPerType,
                  downloadedOnly: downloadedOnly,
                ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            // Hiding the host (not the scope) disposes the page while the
            // providers live on.
            body: ValueListenableBuilder<bool>(
              valueListenable: hostShown,
              builder: (_, shown, _) => shown
                  ? _Host(
                      watch: watch,
                      controls: controls,
                      refreshOnOfflineChange: refreshOnOfflineChange,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<_HostState>(find.byType(_Host));
  }

  /// Past the window's 150 ms quiet period, so a held emission has landed.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 200));

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  }

  testWidgets('online, the first window reads the Downloaded chip off', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    expect(host.hasBrowseControls, isTrue);
    expect(host.filters.downloaded, isFalse);
    expect(watches, [(limit: 2, downloadedOnly: false)]);
    rows.add(['a', 'b', 'c']);
    await settle(tester);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('offline at start, the first window reads the chip on', (
    tester,
  ) async {
    final host = await pumpHost(tester, startOffline: true);
    expect(host.filters.downloaded, isTrue);
    expect(watches, [(limit: 2, downloadedOnly: true)]);
    await unmount(tester);
  });

  testWidgets('a chip change in browse mode re-runs the window from the '
      'first page with the new filter, and clears the old rows at once', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    rows.add(['a', 'b', 'c']);
    await settle(tester);
    host.loadMore();
    rows.add(['a', 'b', 'c']);
    await settle(tester);
    expect(watches.last, (limit: 4, downloadedOnly: false));

    filterControls!.setDownloaded(true);
    expect(host.paginatedItems, isEmpty);
    expect(watches.last, (limit: 2, downloadedOnly: true));
    await tester.pump();
    expect(find.text('a'), findsNothing);
    rows.add(['d']);
    await settle(tester);
    expect(find.text('d'), findsOneWidget);
    expect(search!.calls, isEmpty, reason: 'no search is showing');
    await unmount(tester);
  });

  testWidgets('search mode suspends the window: a write does not reach the '
      'dormant rows, and leaving search resumes from page 1 with the chip '
      'as it is then', (tester) async {
    final host = await pumpHost(tester);
    rows.add(['a', 'b', 'c']);
    await settle(tester);
    host.loadMore();
    rows.add(['a', 'b', 'c']);
    await settle(tester);

    search!.show(query: 'x');
    await tester.pump();
    expect(host.isSearchMode, isTrue);
    expect(host.isPaginationSuspended, isTrue);
    expect(find.text('search mode'), findsOneWidget);
    final watchesInSearch = watches.length;
    rows.add(['z']);
    await settle(tester);
    expect(host.paginatedItems, ['a', 'b', 'c'], reason: 'dormant rows kept');

    // The chip changes while search shows: the search re-runs, not the
    // window.
    filterControls!.setDownloaded(true);
    await tester.pump();
    expect(search!.calls, ['rerun downloadedOnly=true']);
    expect(watches.length, watchesInSearch);

    search!.show(query: '');
    await tester.pump();
    expect(host.isPaginationSuspended, isFalse);
    expect(watches.last, (limit: 2, downloadedOnly: true));
    expect(host.paginatedItems, isEmpty, reason: 'restarted, not the old rows');
    rows.add(['p', 'q', 'r']);
    await settle(tester);
    expect(host.paginatedItems, ['p', 'q']);
    await unmount(tester);
  });

  testWidgets('with controls, an offline flip turns the chip on and re-runs '
      'the window; reconnecting undoes only that', (tester) async {
    final host = await pumpHost(tester);
    rows.add(['a']);
    await settle(tester);

    offline.set(true);
    await tester.pump();
    expect(host.filters.downloaded, isTrue);
    expect(watches.last, (limit: 2, downloadedOnly: true));

    offline.set(false);
    await tester.pump();
    expect(host.filters.downloaded, isFalse);
    expect(watches.last, (limit: 2, downloadedOnly: false));
    expect(watches, hasLength(3));
    await unmount(tester);
  });

  testWidgets('a download change reaches a search snapshot only; the live '
      'window is never re-run for it', (tester) async {
    await pumpHost(tester);
    rows.add(['a']);
    await settle(tester);

    downloadVersions.add(1);
    await tester.pump();
    expect(search!.calls, isEmpty);
    expect(watches, hasLength(1));

    search!.show(query: 'x');
    await tester.pump();
    downloadVersions.add(2);
    await tester.pump();
    expect(search!.calls, ['downloads']);
    expect(watches, hasLength(1));
    await unmount(tester);
  });

  testWidgets('Downloaded empty shows only for a settled, empty window with '
      'the chip on', (tester) async {
    final host = await pumpHost(tester, startOffline: true);
    expect(host.showDownloadedEmpty, isFalse, reason: 'not settled yet');
    rows.add([]);
    await settle(tester);
    expect(host.showDownloadedEmpty, isTrue);
    expect(find.text('downloaded empty'), findsOneWidget);

    filterControls!.setDownloaded(false);
    await tester.pump();
    rows.add([]);
    await settle(tester);
    expect(host.paginationLoadedEmpty, isTrue);
    expect(host.showDownloadedEmpty, isFalse, reason: 'chip off');
    await unmount(tester);
  });

  testWidgets('dispose releases the search and filter controls', (
    tester,
  ) async {
    await pumpHost(tester);
    final created = search!;
    hostShown.value = false;
    await settle(tester);
    expect(find.byType(_Host), findsNothing);
    expect(created.disposed, isTrue);
    // The filter controls no longer follow the offline flag, and nothing
    // re-subscribes a window.
    final count = watches.length;
    offline.set(true);
    await tester.pump();
    expect(watches.length, count);
    expect(filterControls!.filters.downloaded, isFalse);
    await unmount(tester);
  });

  group('without controls (a detail page)', () {
    testWidgets('filters stay at the default and search never shows', (
      tester,
    ) async {
      final host = await pumpHost(tester, controls: false, startOffline: true);
      expect(host.hasBrowseControls, isFalse);
      expect(host.filters.downloaded, isFalse);
      expect(host.isSearchMode, isFalse);
      expect(search, isNull);
      expect(filterControls, isNull);
      rows.add([]);
      await settle(tester);
      expect(host.showDownloadedEmpty, isFalse);
      await unmount(tester);
    });

    testWidgets('an offline flip re-runs the window only when the page asks',
        (tester) async {
      await pumpHost(tester, controls: false);
      offline.set(true);
      await tester.pump();
      expect(watches, hasLength(1));
      await unmount(tester);

      watches.clear();
      await pumpHost(tester, controls: false, refreshOnOfflineChange: true);
      expect(watches, hasLength(1));
      offline.set(true);
      await tester.pump();
      expect(watches, hasLength(2));
      await unmount(tester);
    });
  });
}
