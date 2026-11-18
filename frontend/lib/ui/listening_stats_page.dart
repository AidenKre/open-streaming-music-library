/// Listening stats (and Year in music, which shares its queries).
///
/// **Time zone: UTC today; the device's time zone is a postponed feature.**
/// Every calendar boundary is in UTC: This year and a chosen year, the day
/// and month buckets of the charts (Last 7 / 30 days end now and reach back
/// 7 or 30 times 24 hours; their day buckets are UTC days), the active-day
/// count and the recap year. The pages, the recap image and its JSON export
/// say so ("All times are UTC.", "All times UTC.", `time_zone: 'UTC'`).
/// Not built: boundaries in
/// the device's time zone. The owner postponed it on 2026-11-17 ("Not now,
/// but save this feature somewhere that is easily findable").
///
/// What it would take (estimate 2026-11-17: roughly 300-500 lines with
/// tests, plus an owner decision on whether Listening stats and Year in
/// music switch together):
/// - a zone seam (a provider converting local dates to instants and back):
///   a test process cannot set the local zone, and SQLite's `'localtime'`
///   uses the process zone;
/// - `ListeningStatsRepository` (`lib/repositories/listening_stats_repository.dart`):
///   the year list (`listeningYears`, `strftime('%Y', ..., 'unixepoch')`),
///   the day and month buckets (`_buckets`: `occurred_at / 86400000` and
///   `strftime('%Y-%m', ...)` in SQL, matched to spans in Dart by
///   `~/ 86400000` and `_monthKey`) and the active days (`_totals`,
///   `occurred_at / 86400000`) group by UTC; they would group by boundary
///   instants passed from Dart (daylight saving included);
/// - the windows: `StatsRange` / `StatsWindow.bucketPlan`, `UtcYearRange`,
///   `_yearWindow` and `utcYearOf` (`lib/models/listening_stats.dart`,
///   `annual_recap.dart`, `annual_recap_service.dart`) build `DateTime.utc`;
/// - the labels: on this page the snapshot line ("All times are UTC.
///   Snapshot taken ..."), the chart captions ("Listening time per UTC
///   day/month") and About these numbers; the helpers in
///   `listening_stats/listening_stats_format.dart` (`bucketLabel`,
///   `formatUtcInstant`, `recapMonthName`); in Year in music "YYYY · UTC",
///   "Generated <time> UTC", the image footer, and the JSON export's
///   `time_zone` field and note (schema 1).
/// Decision: the owner's answer of 2026-11-17 to sign-off OPEN-9-08.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/services/history/listening_sync_note.dart';
import 'package:frontend/ui/annual_recap_page.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/listening_stats/bucket_chart.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';
import 'package:frontend/ui/listening_stats/top_lists.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

/// A page reached from Listening stats (9C.1 registers "Year in music").
@immutable
class ListeningStatsLink {
  const ListeningStatsLink({
    required this.id,
    required this.label,
    required this.icon,
    required this.open,
  });

  final String id;
  final String label;
  final IconData icon;
  final void Function(BuildContext context) open;
}

/// Pages reached from Listening stats, in order: the recap ('Year in music',
/// 9C.1). Navigation is a view concern: `open`
/// pushes on the caller's navigator.
final listeningStatsLinksProvider = Provider<List<ListeningStatsLink>>(
  (ref) => [
    ListeningStatsLink(
      id: 'annual_recap',
      label: 'Year in music',
      icon: Icons.calendar_month,
      open: (context) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'stats/annual_recap'),
          builder: (_) => const AnnualRecapPage(),
        ),
      ),
    ),
  ],
);

/// Listening stats (Phase 9 spec §4): a snapshot page over
/// `ListeningStatsControls`.
class ListeningStatsPage extends ConsumerStatefulWidget {
  const ListeningStatsPage({super.key});

  @override
  ConsumerState<ListeningStatsPage> createState() => _ListeningStatsPageState();
}

class _ListeningStatsPageState extends ConsumerState<ListeningStatsPage> {
  late final ListeningStatsControls _controls;
  final _scroll = ScrollController();
  late StatsRange _shownRange;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(listeningStatsControllerFactoryProvider)();
    _shownRange = _controls.range;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controls.dispose();
    super.dispose();
  }

  /// A range change starts the page at the top.
  void _afterBuild() {
    if (!mounted || !_scroll.hasClients) return;
    if (_controls.range != _shownRange) {
      _shownRange = _controls.range;
      _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Listening stats'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _controls.refresh,
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: _controls,
      builder: (context, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _afterBuild());
        final state = _controls.state;
        return ListView(
          controller: _scroll,
          padding: ShellChromeInsets.padEnd(context, const EdgeInsets.all(16)),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in _controls.ranges)
                  ChoiceChip(
                    label: Text(rangeLabel(r)),
                    selected: r == _controls.range,
                    onSelected: (_) => _controls.setRange(r),
                  ),
              ],
            ),
            if (_controls.notice != SnapshotStaleness.fresh)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: NewActivityNotice(
                  message: _controls.notice == SnapshotStaleness.historyChanged
                      ? 'Listening history changed'
                      : 'New listening activity',
                  actionLabel: 'Refresh',
                  onRefresh: _controls.refresh,
                ),
              )
            else if (_controls.topLists?.hasUnavailable ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: NewActivityNotice(
                  message: 'Some items are no longer available',
                  actionLabel: 'Refresh',
                  onRefresh: _controls.refresh,
                ),
              ),
            const SizedBox(height: 16),
            switch (state) {
              StatsLoading() => const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
              StatsFailed() => _Failed(onRetry: _controls.retry),
              StatsReady(
                :final stats,
                :final hasHistory,
                :final pendingListens,
              ) =>
                _Content(
                  stats: stats,
                  hasHistory: hasHistory,
                  pendingListens: pendingListens,
                  topLists: _controls.topLists,
                  token: _controls.token,
                  onPlayTrack: _controls.playTrack,
                ),
            },
          ],
        );
      },
    ),
  );
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text('Couldn’t load listening stats.'),
      TextButton(onPressed: onRetry, child: const Text('Retry')),
    ],
  );
}

class _Content extends ConsumerWidget {
  const _Content({
    required this.stats,
    required this.hasHistory,
    required this.pendingListens,
    required this.topLists,
    required this.token,
    required this.onPlayTrack,
  });

  final ListeningStats stats;
  final bool hasHistory;
  final int pendingListens;
  final StatsTopLists? topLists;
  final HistorySnapshotToken? token;
  final void Function(TrackUI track) onPlayTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final links = ref.watch(listeningStatsLinksProvider);
    final t = stats.totals;
    final u = stats.unavailable;
    final future = stats.futureTimestampCount;
    return KeyedSubtree(
      key: const ValueKey('stats-content'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hasHistory) ...[
            Text(
              'Play music to start building your listening history',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
          ],
          Text(
            'All times are UTC. Snapshot taken '
            '${formatUtcInstant(stats.capturedNowUtcMs)}.',
            style: theme.textTheme.bodySmall,
          ),
          _SyncIndicator(pendingListens: pendingListens),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              _Tile(
                'time',
                'Listening time',
                formatListeningTime(t.listeningSeconds),
              ),
              _Tile('plays', 'Qualified plays', '${t.qualifiedPlays}'),
              _Tile('tracks', 'Unique tracks', '${t.uniqueTracks}'),
              _Tile('days', 'Active days', '${t.activeDays}'),
            ],
          ),
          if (future > 0) ...[
            const SizedBox(height: 12),
            Text(
              future == 1
                  ? '1 listen is dated in the future and is not counted yet.'
                  : '$future listens are dated in the future and are not '
                        'counted yet.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (stats.buckets.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(_chartCaption(), style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            BucketChart(buckets: stats.buckets),
            const SizedBox(height: 8),
            BucketTable(buckets: stats.buckets, unit: stats.bucketUnit),
          ],
          const SizedBox(height: 24),
          KeyedSubtree(
            key: const ValueKey('stats-unavailable'),
            child: Text(
              'Unavailable history: ${formatListeningTime(u.listeningSeconds)}, '
              '${u.qualifiedPlays} qualified '
              '${u.qualifiedPlays == 1 ? 'play' : 'plays'} '
              '(deleted or unresolved tracks; included in the totals above).',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (topLists != null)
            StatsTopListsView(
              lists: topLists!,
              onPlayTrack: onPlayTrack,
              token: token,
            ),
          const SizedBox(height: 16),
          for (final link in links)
            ListTile(
              leading: Icon(link.icon),
              title: Text(link.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => link.open(context),
            ),
          const _About(),
        ],
      ),
    );
  }

  String _chartCaption() {
    if (stats.bucketUnit == StatsBucketUnit.day) {
      return stats.range is RollingDaysRange
          ? 'Listening time per UTC day. The first and last days are partial.'
          : 'Listening time per UTC day.';
    }
    return 'Listening time per UTC month.'
        '${stats.chartCapped ? ' The chart shows the latest 24 months; '
                  'totals cover all time.' : ''}';
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.id, this.caption, this.value);

  final String id;
  final String caption;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: ValueKey('stats-summary-$id'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: theme.textTheme.bodySmall),
        Text(value, style: theme.textTheme.headlineSmall),
      ],
    );
  }
}

class _About extends StatelessWidget {
  const _About();

  static const _paragraphs = [
    'A qualified play is a listen of at least 30 seconds, or half the track '
        'when it is shorter than a minute.',
    'Listening time is recorded media time: listening on two devices at once '
        'counts both, and rewinding can count more than a track’s length.',
    'A listen that was interrupted when the app was closed may be split or '
        'lose its last unsaved seconds.',
    'Each listen counts in the UTC day it started. Times are rounded down to '
        'the minute.',
    'Artists and albums come from the current catalog metadata, so a rename '
        'moves past listens to the new name.',
  ];

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('About these numbers'),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    children: [
      for (final p in _paragraphs)
        Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(p)),
    ],
  );
}

/// What the history sync state means for these numbers. Diagnostics that
/// are loading or failed are unknown, never the previous value.
class _SyncIndicator extends ConsumerWidget {
  const _SyncIndicator({required this.pendingListens});

  final int pendingListens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diagnostics = switch (ref.watch(historyDiagnosticsProvider)) {
      AsyncData(:final value) => value,
      _ => null,
    };
    final note = ListeningSyncNote.of(
      diagnostics: diagnostics,
      pendingListens: pendingListens,
    );
    final lines = [
      if (note.serverWithoutSync)
        'This server doesn’t sync listening history yet, so only this '
            'device’s listens are shown.'
      else if (note.syncProblem)
        'History sync has a problem; listens from your other devices may be '
            'missing.',
      if (note.pendingListens > 0)
        'Includes ${note.pendingListens} '
            '${note.pendingListens == 1 ? 'listen' : 'listens'} from this '
            'device not uploaded yet.'
      else if (note.allUploaded)
        'All listens from this device are uploaded.',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Text(l, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
