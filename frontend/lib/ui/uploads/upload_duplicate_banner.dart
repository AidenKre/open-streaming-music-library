// One duplicate banner of the review page (SC-26: a view). It renders a
// model `DuplicateBanner` and sends every input to the review controller or
// the preview controller; the enabled states come from the model's fields.
// Only the "+N more" expansion is local.
import 'package:flutter/material.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/uploads/upload_duplicate_banners.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart'
    show ReviewItemView, previewPlaying;
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';

class UploadDuplicateBanner extends StatefulWidget {
  const UploadDuplicateBanner({
    super.key,
    required this.banner,
    required this.view,
    required this.controls,
    required this.preview,
    required this.previewState,
  });

  final DuplicateBanner banner;
  final ReviewItemView view;
  final UploadReviewControls controls;
  final PreviewControls preview;
  final PreviewState previewState;

  @override
  State<UploadDuplicateBanner> createState() => _UploadDuplicateBannerState();
}

class _UploadDuplicateBannerState extends State<UploadDuplicateBanner> {
  bool _expanded = false;

  List<Widget> _actions() {
    final banner = widget.banner;
    final view = widget.view;
    final controls = widget.controls;
    final idle = !controls.busy;
    switch (banner.kind) {
      case DuplicateBannerKind.exactLibrary:
        return [
          TextButton(
            onPressed: view.useExistingTrackUuid != null && idle
                ? controls.useExisting
                : null,
            child: const Text('Use existing track'),
          ),
          if (banner.needsChoice)
            TextButton(
              onPressed: view.canDecideDuplicates && idle
                  ? () => controls.chooseDuplicates(DuplicateGroup.library)
                  : null,
              child: const Text('Import as separate track'),
            )
          else
            const Text('It will be imported as a separate track.'),
        ];
      case DuplicateBannerKind.fingerprintLibrary:
        return [
          TextButton(
            onPressed: view.dontImportTrackUuid != null && idle
                ? controls.dontImport
                : null,
            child: const Text("Don't import"),
          ),
        ];
      case DuplicateBannerKind.exactStaged:
        return [
          if (banner.needsChoice)
            TextButton(
              onPressed: view.canDecideDuplicates && idle
                  ? () => controls.chooseDuplicates(DuplicateGroup.staged)
                  : null,
              child: const Text('Import both'),
            )
          else
            const Text('Both files will be imported.'),
        ];
      case DuplicateBannerKind.fingerprintStaged:
        return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final banner = widget.banner;
    final rows = _expanded ? banner.rows : banner.shown;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(banner.headline, style: Theme.of(context).textTheme.titleSmall),
          for (final row in rows)
            DuplicateRowTile(
              row: row,
              view: widget.view,
              preview: widget.preview,
              previewState: widget.previewState,
            ),
          if (banner.moreCount > 0 && !_expanded)
            TextButton(
              onPressed: () => setState(() => _expanded = true),
              child: Text('+${banner.moreCount} more'),
            ),
          Wrap(spacing: 8, children: _actions()),
        ],
      ),
    );
  }
}

/// One match row: title, details and Play / Pause existing (a view; the
/// button is enabled by the model's `canPlayExisting`).
class DuplicateRowTile extends StatelessWidget {
  const DuplicateRowTile({
    super.key,
    required this.row,
    required this.view,
    required this.preview,
    required this.previewState,
  });

  final DuplicateRow row;
  final ReviewItemView view;
  final PreviewControls preview;
  final PreviewState previewState;

  @override
  Widget build(BuildContext context) {
    final uuid = row.trackUuid;
    final playing =
        uuid != null && previewPlaying(previewState, LibraryTrackPreview(uuid));
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(row.title),
        if (row.details != null) Text(row.details!),
        if (uuid != null)
          TextButton(
            onPressed: playing
                ? preview.pause
                : view.canPlayExisting
                ? () => preview.playLibraryTrack(uuid)
                : null,
            child: Text(playing ? 'Pause existing' : 'Play existing'),
          ),
      ],
    );
  }
}
