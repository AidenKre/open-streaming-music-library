import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/preview_player.dart';

/// Every preview input (SC-26, spec §5 Preview): the upload review and
/// Phase 8's duplicate audition. Holds no rules and does no I/O.
abstract interface class PreviewControls {
  Future<void> playStaged(String itemUuid);
  Future<void> playLibraryTrack(String trackUuid);
  Future<void> pause();
  Future<void> resume();
  Future<void> close();
}

final previewControlsProvider =
    Provider<PreviewControls>((ref) => PreviewController(ref));

/// Forwards each intent to the preview model.
class PreviewController implements PreviewControls {
  PreviewController(this._ref);
  final Ref _ref;

  PreviewPlayer get _player => _ref.read(previewPlayerProvider.notifier);

  @override
  Future<void> playStaged(String itemUuid) =>
      _player.play(StagedUploadPreview(itemUuid));

  @override
  Future<void> playLibraryTrack(String trackUuid) =>
      _player.play(LibraryTrackPreview(trackUuid));

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> close() => _player.close();
}

/// What the user is told for a preview status, or null when nothing.
String? previewStatusMessage(PreviewStatus status) => switch (status) {
      PreviewStatus.needsConnection => 'Preview needs a connection',
      PreviewStatus.unavailable => 'Preview unavailable',
      PreviewStatus.failed => "Preview couldn't play",
      _ => null,
    };
