import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/ui/preview_controller.dart';

/// The model behind the controller, recording the commands it receives.
class _RecordingPreview extends PreviewPlayer {
  final calls = <Object>[];

  @override
  PreviewState build() => const PreviewState();

  @override
  Future<void> play(PreviewSource source) async => calls.add(source);

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> close() async => calls.add('close');
}

void main() {
  late ProviderContainer c;
  late _RecordingPreview model;

  setUp(() {
    model = _RecordingPreview();
    c = ProviderContainer(
        overrides: [previewPlayerProvider.overrideWith(() => model)]);
    c.listen(previewPlayerProvider, (_, _) {});
  });

  tearDown(() => c.dispose());

  test('every input is forwarded to the preview model (SC-26)', () async {
    final controls = c.read(previewControlsProvider);
    await controls.playStaged('i1');
    await controls.playLibraryTrack('t1');
    await controls.pause();
    await controls.resume();
    await controls.close();
    expect(model.calls, [
      const StagedUploadPreview('i1'),
      const LibraryTrackPreview('t1'),
      'pause',
      'resume',
      'close',
    ]);
  });

  test('the controller provider can be overridden with a fake', () {
    final fake = _FakeControls();
    final o = ProviderContainer(
        overrides: [previewControlsProvider.overrideWithValue(fake)]);
    addTearDown(o.dispose);
    expect(o.read(previewControlsProvider), same(fake));
  });

  test('what the user is told for each refusal (O11, OPEN-M-11)', () {
    expect(previewStatusMessage(PreviewStatus.needsConnection),
        'Preview needs a connection');
    expect(previewStatusMessage(PreviewStatus.unavailable),
        'Preview unavailable');
    expect(previewStatusMessage(PreviewStatus.failed), "Preview couldn't play");
    for (final quiet in [
      PreviewStatus.idle,
      PreviewStatus.loading,
      PreviewStatus.playing,
      PreviewStatus.paused,
      PreviewStatus.completed,
    ]) {
      expect(previewStatusMessage(quiet), isNull, reason: '$quiet');
    }
  });
}

class _FakeControls implements PreviewControls {
  @override
  Future<void> playStaged(String itemUuid) async {}

  @override
  Future<void> playLibraryTrack(String trackUuid) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> close() async {}
}
