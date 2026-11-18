import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

/// The filter key of the tokens the recap captures itself (SC-10). The
/// recap reads only a token's boundary and captured now, so it can also be
/// opened with a token another surface captured.
const annualRecapFilterKey = 'annual_recap';

/// Reads annual recaps (spec §6): one statistics load under one snapshot
/// token per recap.
class AnnualRecapService {
  AnnualRecapService(this._stats, this._snapshots);

  final ListeningStatsRepository _stats;
  final HistorySnapshotService _snapshots;

  /// The recap of the UTC [year] under [token].
  Future<AnnualRecap> load(int year, HistorySnapshotToken token) async {
    final stats = await _stats.load(
      StatsRange.year(year),
      token.boundaryLocalId,
      token.capturedNowUtcMs,
    );
    return AnnualRecap.fromStats(stats, token);
  }

  /// The recap of [year] (default: the token's UTC year) and the years to
  /// choose from, read under one token in one transaction. A failing years
  /// read gives null years; the recap still returns.
  Future<AnnualRecapSnapshot> snapshot({int? year}) async {
    final (_, snapshot) = await _snapshots.captureWith(annualRecapFilterKey, (
      token,
    ) async {
      final y = year ?? utcYearOf(token.capturedNowUtcMs);
      final recap = await load(y, token);
      List<int>? yearList;
      try {
        yearList = await years(token);
      } on Object {
        yearList = null;
      }
      return AnnualRecapSnapshot(recap: recap, years: yearList);
    });
    return snapshot;
  }

  /// The years a recap can be chosen for under [token]: those holding a
  /// counted listen and the token's current UTC year, newest first.
  Future<List<int>> years(HistorySnapshotToken token) async {
    final withData = await _stats.listeningYears(
      token.boundaryLocalId,
      token.capturedNowUtcMs,
    );
    final current = utcYearOf(token.capturedNowUtcMs);
    return ({...withData, current}.toList()..sort((a, b) => b.compareTo(a)));
  }
}

/// One recap snapshot: the recap and the years to choose from, both read
/// under the recap's token.
class AnnualRecapSnapshot {
  const AnnualRecapSnapshot({required this.recap, required this.years});
  final AnnualRecap recap;

  /// Newest first; always holds the token's current UTC year. Null when
  /// the list could not be read (the recap itself was).
  final List<int>? years;
}

final annualRecapServiceProvider = Provider<AnnualRecapService>(
  (ref) => AnnualRecapService(
    ref.read(listeningStatsRepositoryProvider),
    ref.read(historySnapshotServiceProvider),
  ),
);
