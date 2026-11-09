import 'package:frontend/services/conversion/conversion_service.dart';
import 'package:frontend/ui/conversion_controller.dart';

/// Scriptable conversion controller for widget tests.
class FakeConversionControls implements ConversionControls {
  FakeConversionControls({
    this.prep = const ConversionRefused('refused'),
    this.cancelError,
  });

  ConversionPrep? prep;
  String? cancelError;
  final calls = <String>[];

  @override
  Future<ConversionPrep?> begin(
    String uuidId, {
    required bool Function() isAlive,
    String? presetCodec,
    int? presetBitrateKbps,
  }) async {
    calls.add('begin $uuidId $presetCodec $presetBitrateKbps');
    return prep;
  }

  @override
  Future<String?> submit(
    ConversionDraft draft,
    ConvertTargetChoice choice,
  ) async {
    calls.add('submit ${draft.uuidId} ${choice.codec} ${choice.bitrateKbps}');
    return null;
  }

  @override
  void end(String uuidId, {required bool Function() isAlive}) =>
      calls.add('end $uuidId');

  @override
  Future<String?> cancel(int jobId) async {
    calls.add('cancel $jobId');
    return cancelError;
  }
}
