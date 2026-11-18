import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/services/annual_recap_service.dart';
import 'package:frontend/services/recap_export_files.dart';
import 'package:frontend/services/recap_export_platform.dart';
import 'package:frontend/services/recap_export_service.dart';

/// The Year in music page's input and presentation state (spec §6; SC-10,
/// SC-26). One recap snapshot at a time, read under one token.
abstract interface class AnnualRecapControls implements Listenable {
  /// The UTC year shown; null until the first answer tells the current year.
  int? get year;

  /// The years to choose from, newest first (empty until known).
  List<int> get years;

  /// The current recap snapshot; null while loading or after a failure.
  AnnualRecap? get recap;

  bool get loading;

  /// The last read failed; [retry] repeats it.
  bool get failed;

  /// Shows [year]: reads a new snapshot of its recap.
  void selectYear(int year);

  /// Reads a new snapshot for the same year.
  void refresh();

  /// Repeats the failed request.
  void retry();

  /// This device has a save panel.
  bool get canSave;

  /// This device's share sheet can share a file.
  bool get canShare;

  /// A save or share is in progress; other export inputs are ignored.
  bool get exporting;

  /// Saves [png] (the export image the view rendered from [recap]) where
  /// the user chooses. Returns what to tell the user, or null for nothing.
  Future<String?> savePng(Uint8List png);

  /// Saves the JSON of [recap] where the user chooses. Returns what to tell
  /// the user, or null for nothing.
  Future<String?> saveJson();

  /// Opens the share sheet for [png] from [origin]. Returns what to tell
  /// the user, or null for nothing.
  Future<String?> sharePng(Uint8List png, {Rect? origin});

  void dispose();
}

typedef AnnualRecapFactory = AnnualRecapControls Function();

/// Creates the page's controller (page-scoped). Override in tests.
final annualRecapControllerFactoryProvider = Provider<AnnualRecapFactory>(
  (ref) =>
      () => AnnualRecapController(ref),
);

class AnnualRecapController extends ChangeNotifier
    implements AnnualRecapControls {
  AnnualRecapController(this._ref) {
    _begin(null);
  }

  final Ref _ref;
  AnnualRecapService get _service => _ref.read(annualRecapServiceProvider);
  RecapExportFiles get _files => _ref.read(recapExportFilesProvider);

  /// Bumped by every new snapshot and by dispose; stale continuations return.
  int _generation = 0;
  bool _disposed = false;

  int? _year;

  /// The year the last request asked for (what [retry] repeats).
  int? _requested;
  List<int> _years = const [];
  AnnualRecap? _recap;
  bool _loading = true;
  bool _failed = false;
  bool _exporting = false;

  @override
  int? get year => _year;

  @override
  List<int> get years {
    final shown = _year;
    return ({..._years, ?shown}.toList()..sort((a, b) => b.compareTo(a)));
  }

  @override
  AnnualRecap? get recap => _recap;

  @override
  bool get loading => _loading;

  @override
  bool get failed => _failed;

  @override
  void selectYear(int year) {
    _year = year;
    _begin(year);
  }

  @override
  void refresh() => _begin(_year);

  @override
  void retry() {
    if (_disposed || !_failed) return;
    _begin(_requested);
  }

  /// Asks the service for a new snapshot of [year] (null: the current UTC
  /// year, known from the answer).
  void _begin(int? year) {
    if (_disposed) return;
    final generation = ++_generation;
    _requested = year;
    _recap = null;
    _failed = false;
    _loading = true;
    notifyListeners();
    _read(generation, year);
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  Future<void> _read(int generation, int? year) async {
    try {
      final snapshot = await _service.snapshot(year: year);
      if (_stale(generation)) return;
      _recap = snapshot.recap;
      _year = snapshot.recap.year;
      // An unreadable years list keeps the previous one.
      _years = snapshot.years ?? _years;
      _loading = false;
    } catch (_) {
      if (_stale(generation)) return;
      _failed = true;
      _loading = false;
      _recap = null;
    }
    notifyListeners();
  }

  @override
  bool get canSave => _files.canSave;

  @override
  bool get canShare => _files.canShare;

  @override
  bool get exporting => _exporting;

  @override
  Future<String?> savePng(Uint8List png) => _export((recap) async {
    final outcome = await _files.save(
      png,
      suggestedName: recapExportFileName(recap.year, RecapExportType.png),
      type: RecapExportType.png,
    );
    return _saveMessage(outcome, 'Image saved');
  });

  @override
  Future<String?> saveJson() => _export((recap) async {
    final json = _ref.read(recapExportServiceProvider).buildJson(recap);
    final outcome = await _files.save(
      Uint8List.fromList(utf8.encode(json)),
      suggestedName: recapExportFileName(recap.year, RecapExportType.json),
      type: RecapExportType.json,
    );
    return _saveMessage(outcome, 'JSON saved');
  });

  @override
  Future<String?> sharePng(Uint8List png, {Rect? origin}) =>
      _export((recap) async {
        final outcome = await _files.share(
          png,
          suggestedName: recapExportFileName(recap.year, RecapExportType.png),
          type: RecapExportType.png,
          origin: origin,
        );
        return switch (outcome) {
          RecapShareOutcome.shared ||
          RecapShareOutcome.dismissed ||
          RecapShareOutcome.unknown => null,
          RecapShareOutcome.unavailable =>
            'Sharing files is not available on this device',
          RecapShareOutcome.failed => 'Could not share the image',
        };
      });

  String? _saveMessage(RecapSaveOutcome outcome, String saved) =>
      switch (outcome) {
        RecapSaveOutcome.saved => saved,
        RecapSaveOutcome.cancelled => null,
        RecapSaveOutcome.destinationExists =>
          'A file with that name already exists; nothing was saved',
        RecapSaveOutcome.unavailable =>
          'Saving files is not available on this device',
        RecapSaveOutcome.failed => 'Could not save the export',
      };

  /// Runs one export of the shown recap; ignored while another is running.
  Future<String?> _export(Future<String?> Function(AnnualRecap) run) async {
    final recap = _recap;
    if (_disposed || recap == null || _exporting) return null;
    _exporting = true;
    notifyListeners();
    try {
      return await run(recap);
    } finally {
      _exporting = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    try {
      unawaited(_files.release());
    } catch (_) {
      // The provider scope is already gone: nothing is kept.
    }
    super.dispose();
  }
}
