import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/services/conversion/conversion_service.dart';

/// Conversion input (SC-26 `ConversionControls`): the per-track Convert…
/// flow, the Conversions page's Retry and Cancel. Holds only presentation
/// state (which tracks have a flow running); every rule lives in the model
/// [ConversionService].
abstract interface class ConversionControls {
  /// Starts the flow for [uuidId] and returns the model's verdict, or null
  /// when a flow for this track is already running (a double tap, or
  /// Convert… and Retry together). [isAlive] reports whether the caller's
  /// flow can still finish: a flow whose view was torn down while awaiting a
  /// sheet never calls [end], and must not block the track for the rest of
  /// the session.
  Future<ConversionPrep?> begin(
    String uuidId, {
    required bool Function() isAlive,
    String? presetCodec,
    int? presetBitrateKbps,
  });

  /// The user confirmed: enqueue. Null when started, else the message.
  Future<String?> submit(ConversionDraft draft, ConvertTargetChoice choice);

  /// The flow for [uuidId] that [begin] was given [isAlive] for finished
  /// (always called, success or not). A stale flow's end never frees a newer
  /// flow for the same track.
  void end(String uuidId, {required bool Function() isAlive});

  /// Cancel [jobId]. Null when cancelled, else the message.
  Future<String?> cancel(int jobId);
}

final conversionControlsProvider = Provider<ConversionControls>(
  ConversionController.new,
);

class ConversionController implements ConversionControls {
  ConversionController(this._ref);

  final Ref _ref;

  /// The [ConversionControls.begin] `isAlive` of each track's running flow.
  /// An entry whose flow is no longer alive does not block.
  final _inFlight = <String, bool Function()>{};

  ConversionService get _service => _ref.read(conversionServiceProvider);

  @override
  Future<ConversionPrep?> begin(
    String uuidId, {
    required bool Function() isAlive,
    String? presetCodec,
    int? presetBitrateKbps,
  }) async {
    final running = _inFlight[uuidId];
    if (running != null && running()) return null;
    _inFlight[uuidId] = isAlive;
    try {
      return await _service.prepare(
        uuidId,
        presetCodec: presetCodec,
        presetBitrateKbps: presetBitrateKbps,
      );
    } catch (_) {
      // A failed prepare never reaches the view's end(): free the track.
      end(uuidId, isAlive: isAlive);
      rethrow;
    }
  }

  @override
  Future<String?> submit(ConversionDraft draft, ConvertTargetChoice choice) =>
      _service.submit(draft, choice);

  @override
  void end(String uuidId, {required bool Function() isAlive}) {
    if (identical(_inFlight[uuidId], isAlive)) _inFlight.remove(uuidId);
  }

  @override
  Future<String?> cancel(int jobId) => _service.cancel(jobId);
}
