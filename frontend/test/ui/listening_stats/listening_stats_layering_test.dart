// Phase 9A.2a SC-26 grep (exit proof) and SC-20/SC-27 guards: the
// statistics view talks only to its controller and observes model state;
// the controller does no I/O of its own, reads no clock (now comes from
// the snapshot token), reaches playback only through `LibraryActions`
// (SC-05/SC-06, 9A.2b) and no history writer; the model imports nothing
// from ui/.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String path) => File(path).readAsStringSync();

List<String> _imports(String source) => [
  for (final m in RegExp(r"^import '([^']+)'", multiLine: true)
      .allMatches(source))
    m.group(1)!,
];

const _views = [
  'lib/ui/listening_stats_page.dart',
  'lib/ui/listening_stats/bucket_chart.dart',
  'lib/ui/listening_stats/listening_stats_format.dart',
  'lib/ui/listening_stats/top_lists.dart',
  'lib/ui/listening_stats/listening_ranking_page.dart',
  'lib/ui/listening_stats/stats_ranked_card.dart',
];
const _controller = 'lib/ui/listening_stats/listening_stats_controller.dart';
const _controllers = [
  _controller,
  'lib/ui/listening_stats/listening_ranking_controller.dart',
];
const _model = [
  'lib/models/listening_stats.dart',
  'lib/repositories/listening_stats_repository.dart',
];

/// Data, I/O and playback layers a view or controller must not import.
final _forbiddenForViews = [
  RegExp(r'^package:drift'),
  RegExp(r'^package:http'),
  RegExp(r'^dart:io$'),
  RegExp(r'^package:frontend/database/'),
  RegExp(r'^package:frontend/repositories/'),
  RegExp(r'^package:frontend/api/'),
  RegExp(r'^package:frontend/playback/'),
  RegExp(r'^package:frontend/ui/library_actions'),
];

void main() {
  for (final path in _views) {
    test('$path imports no data, I/O or playback layer', () {
      final hits = [
        for (final i in _imports(_src(path)))
          if (_forbiddenForViews.any((r) => r.hasMatch(i)) &&
              // The SnapshotStaleness value type only (SC-10's home).
              i != 'package:frontend/repositories/history_snapshot.dart')
            i,
      ];
      expect(hits, isEmpty);
    });
  }

  test('the page uses snapshot types only, never the snapshot service', () {
    final src = _src('lib/ui/listening_stats_page.dart');
    for (final word in ['historySnapshotServiceProvider',
        'snapshotFreshnessProvider', 'listeningStatsRepositoryProvider',
        'databaseProvider']) {
      expect(src, isNot(contains(word)), reason: word);
    }
  });

  test('the page reads no model provider except to observe it', () {
    final src = _src('lib/ui/listening_stats_page.dart');
    // Inputs go to the controller; the only read is the controller factory.
    final reads = RegExp(r'ref\.read\((\w+)').allMatches(src).map(
      (m) => m.group(1),
    );
    expect(reads.toSet(), {'listeningStatsControllerFactoryProvider'});
    expect(src, isNot(contains('historyDiagnosticsActionsProvider')));
  });

  for (final path in _controllers) {
    test('$path does no I/O, reads no clock and plays only through '
        'LibraryActions', () {
      final src = _src(path);
      final imports = _imports(src);
      final hits = [
        for (final i in imports)
          if (_forbiddenForViews.any((r) => r.hasMatch(i)) &&
              i != 'package:frontend/repositories/history_snapshot.dart' &&
              i !=
                  'package:frontend/repositories/listening_stats_repository.dart' &&
              // 9A.2b See all: the shared 9A.1c pagers (SC-10), never a copy.
              i != 'package:frontend/repositories/listening_rank_pagers.dart' &&
              // 9A.2b: a track tap goes through the one SC-06 controller,
              // whose outcome type lives with the SC-05 request types.
              i != 'package:frontend/ui/library_actions.dart' &&
              i != 'package:frontend/playback/playback_requests.dart')
            i,
      ];
      expect(hits, isEmpty);
      expect(imports, isNot(contains('package:flutter/material.dart')));
      expect(imports, isNot(contains('package:frontend/services/clock.dart')));
      expect(src, contains('abstract interface class '));
      for (final word in ['clockProvider', 'PlaybackRequests',
          'playbackRequestsProvider', 'queuePlayerProvider', 'customSelect',
          'customStatement', 'into(', 'historyRepositoryProvider',
          'databaseProvider']) {
        expect(src, isNot(contains(word)), reason: word);
      }
    });
  }

  test('9-U11: no statistics copy of the shared card, menu, notice or pager',
      () {
    for (final path in [..._views, ..._controllers]) {
      final src = _src(path);
      for (final pattern in [
        RegExp(r'class \w*Notice\b'),
        RegExp(r'class \w*(Pager|SnapshotToken|Freshness)\b'),
        RegExp(r'class \w*(TrackCard|AlbumCard|ArtistCard)\b'),
        RegExp(r'buildLibraryActionMenu|LibraryMenuEntry\('),
      ]) {
        expect(pattern.hasMatch(src), isFalse,
            reason: '$path matches ${pattern.pattern}');
      }
    }
  });

  for (final path in _model) {
    test('$path imports nothing from ui/', () {
      expect(
        _imports(_src(path)).where((i) => i.startsWith('package:frontend/ui/')),
        isEmpty,
      );
    });
  }
}
