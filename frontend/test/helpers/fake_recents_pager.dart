// A See all recents pager and freshness watcher whose every result the test
// releases by hand, and the page rows they answer with (moved here from
// see_all_recents_generation_test.dart, APP-TEST stage 2).
import 'dart:async';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/recents_snapshot_pager.dart';
import 'package:flutter_test/flutter_test.dart' show pumpEventQueue;

TrackUI track(String uuid, {String? title}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title ?? 'Song $uuid',
  artist: 'A',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

ResolvedRecent recent(String uuid, {String? title}) {
  final t = track(uuid, title: title);
  return ResolvedRecent(
    ref: RecentRef(
      type: RecentEntityType.track,
      ref: uuid,
      occurredAt: 1,
      eventUuid: 'ev-$uuid',
    ),
    entity: t,
  );
}

typedef Page = SnapshotPageResult<ResolvedRecent, RecentRef>;

/// A page of [uuids]; with [more], the cursor is the last ref.
Page pageOf(List<String> uuids, {bool more = false}) {
  final items = [for (final u in uuids) recent(u)];
  return SnapshotPage<ResolvedRecent, RecentRef>(
    items,
    more ? items.last.ref : null,
  );
}

class CaptureCall {
  CaptureCall(this.downloadedOnly);
  final bool downloadedOnly;
  final done = Completer<HistorySnapshotToken>();
}

class PageCall {
  PageCall(this.token, this.after, this.limit);
  final HistorySnapshotToken token;
  final RecentRef? after;
  final int limit;
  final done = Completer<Page>();
}

/// A live stream that keeps delivering whatever the test pushes even after
/// it was cancelled (an in-flight read that completes late).
class LeakyStream extends Stream<List<ResolvedRecent>> {
  void Function(List<ResolvedRecent>)? _onData;
  bool cancelled = false;

  @override
  StreamSubscription<List<ResolvedRecent>> listen(
    void Function(List<ResolvedRecent>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    return _LeakySubscription(this);
  }

  void emit(List<ResolvedRecent> v) => _onData?.call(v);
}

class _LeakySubscription implements StreamSubscription<List<ResolvedRecent>> {
  _LeakySubscription(this._s);
  final LeakyStream _s;

  @override
  Future<void> cancel() async => _s.cancelled = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class WatchCall {
  WatchCall(this.token, this.refs);
  final HistorySnapshotToken token;
  final List<RecentRef> refs;
  final stream = LeakyStream();
}

class FakePager implements RecentsSnapshotPager {
  final captures = <CaptureCall>[];
  final pages = <PageCall>[];
  final watches = <WatchCall>[];
  var _boundary = 0;

  /// Freshness is served by the test's fake (the real pager scopes it to
  /// clicks; that scoping is covered over real Drift).
  late SnapshotFreshness freshness;

  @override
  Stream<SnapshotStaleness> watchFreshness(HistorySnapshotToken token) =>
      freshness.watch(token);

  HistorySnapshotToken tokenFor(CaptureCall c) => HistorySnapshotToken(
    boundaryLocalId: ++_boundary,
    historyContentVersion: 0,
    capturedNowUtcMs: 0,
    filterKey: (downloadedOnly: c.downloadedOnly),
  );

  /// Completes capture [i] with a fresh token and lets the controller react.
  Future<HistorySnapshotToken> grant(int i) async {
    final t = tokenFor(captures[i]);
    captures[i].done.complete(t);
    await pumpEventQueue();
    return t;
  }

  Future<void> answer(int i, Page page) async {
    pages[i].done.complete(page);
    await pumpEventQueue();
  }

  @override
  Future<HistorySnapshotToken> capture({required bool downloadedOnly}) {
    final c = CaptureCall(downloadedOnly);
    captures.add(c);
    return c.done.future;
  }

  @override
  Future<Page> page(HistorySnapshotToken token, RecentRef? after, int limit) {
    final p = PageCall(token, after, limit);
    pages.add(p);
    return p.done.future;
  }

  @override
  Stream<List<ResolvedRecent>> watchLoaded(
    HistorySnapshotToken token,
    List<RecentRef> refs,
  ) {
    final w = WatchCall(token, refs);
    watches.add(w);
    return w.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FreshnessCall {
  FreshnessCall(this.token);
  final HistorySnapshotToken token;
  bool cancelled = false;
  late final controller = StreamController<SnapshotStaleness>(
    onCancel: () => cancelled = true,
  );
}

class FakeFreshness implements SnapshotFreshness {
  final calls = <FreshnessCall>[];

  @override
  Stream<SnapshotStaleness> watch(HistorySnapshotToken token,
      {Set<String>? kinds}) {
    final c = FreshnessCall(token);
    calls.add(c);
    return c.controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
