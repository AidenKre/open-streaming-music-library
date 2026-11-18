// The review page (spec §7 para 4; SC-26: a view). It renders the review
// controller's state and sends every input to it or to the preview
// controller.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/ui/uploads/upload_duplicate_banner.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';
import 'package:frontend/ui/widgets/metadata_form.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart'
    show ReviewItemView;

class UploadReviewPage extends ConsumerStatefulWidget {
  const UploadReviewPage({super.key, required this.batchUuid, this.startAt});
  final String batchUuid;
  final String? startAt;

  @override
  ConsumerState<UploadReviewPage> createState() => _UploadReviewPageState();
}

class _UploadReviewPageState extends ConsumerState<UploadReviewPage> {
  late final UploadReviewControls _controls;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(uploadReviewControllerFactoryProvider)();
    _controls.start(widget.batchUuid, startAt: widget.startAt);
  }

  @override
  void dispose() {
    _controls.dispose();
    super.dispose();
  }

  void _confirmSheet() {
    final supported = _controls.current?.tagWriteSupported;
    // The item and version the sheet is opened for: Import acts on these.
    final itemUuid = _controls.current?.itemUuid;
    final reviewVersion = _controls.current?.reviewVersion;
    var write = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (context, setState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The reviewed tags go into your library, and the file keeps '
                  'its own tags. Turn on the switch to also write them into '
                  'the imported copy. Your original file is never changed.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Write these tags into the imported file'),
                  subtitle: Text(switch (supported) {
                    false => "This file type can't take written tags.",
                    null =>
                      "It isn't known yet whether this file can take written "
                          'tags. The server checks when you import.',
                    true => 'Your original file is never changed.',
                  }),
                  value: supported == false ? false : write,
                  onChanged: supported == false
                      ? null
                      : (v) => setState(() => write = v),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(sheet).pop(),
                      child: const Text('Back'),
                    ),
                    FilledButton(
                      onPressed: () {
                        if (itemUuid != null && reviewVersion != null) {
                          _controls.confirm(
                            itemUuid: itemUuid,
                            reviewVersion: reviewVersion,
                            writeTags: write,
                          );
                        }
                        Navigator.of(sheet).pop();
                      },
                      child: const Text('Import'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewTrack(TrackUI track) => TextButton(
    onPressed: () => openTrackInfo(context, track),
    child: const Text('View track'),
  );

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(previewPlayerProvider);
    return _scaffold(preview);
  }

  Widget _scaffold(PreviewState preview) => Scaffold(
    appBar: AppBar(
      title: const Text('Review tags'),
      actions: [
        ListenableBuilder(
          listenable: _controls,
          builder: (_, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(child: Text(_controls.positionText)),
          ),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: _controls,
      builder: (_, _) => _body(preview),
    ),
  );

  Widget _body(PreviewState preview) {
    switch (_controls.load) {
      case ReviewLoad.loading:
        return const Center(child: CircularProgressIndicator());
      case ReviewLoad.failed:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Couldn't load the files to review."),
              TextButton(
                onPressed: () => _controls.start(
                  widget.batchUuid,
                  startAt: widget.startAt,
                ),
                child: const Text('Try again'),
              ),
            ],
          ),
        );
      case ReviewLoad.ready:
        break;
    }
    final view = _controls.current;
    final imported = _controls.lastImported;
    final notice = _controls.notice;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_controls.moreItemsReady)
          NewActivityNotice(
            message: 'More items ready',
            actionLabel: 'Refresh',
            onRefresh: _controls.refresh,
          ),
        if (notice != null)
          Row(
            children: [
              Expanded(child: Text(notice)),
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close),
                onPressed: _controls.dismissNotice,
              ),
            ],
          ),
        if (imported != null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                imported.alreadyInLibrary
                    ? '“${imported.displayName}” is already in your library'
                    : '“${imported.displayName}” was imported',
              ),
              if (imported.track != null) _viewTrack(imported.track!),
            ],
          ),
        if (_controls.duplicateSummary?.line != null) ...[
          Text(_controls.duplicateSummary!.line!),
          for (final note in _controls.duplicateSummary!.footnotes) Text(note),
        ],
        if (view == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Nothing to review right now.')),
          )
        else ...[
          Text(
            view.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(view.statusText),
          if (view.errorText != null) Text(view.errorText!),
          if (view.done && _controls.currentTrack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: _viewTrack(_controls.currentTrack!),
            ),
          if (view.conflict != null) ..._conflict(view, preview),
          if (view.reviewable) ..._duplicates(view, preview),
          if (view.reviewable) _form(view.itemUuid, view.reviewVersion),
          const SizedBox(height: 8),
          _preview(preview, view.itemUuid, view.canPreview),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _controls.canPrevious ? _controls.previous : null,
                child: const Text('Previous'),
              ),
              TextButton(
                onPressed: _controls.canNext ? _controls.next : null,
                child: const Text('Next'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: view.canSkip && !_controls.busy
                    ? _controls.skip
                    : null,
                child: const Text('Skip edits and import'),
              ),
              FilledButton(
                onPressed: view.canConfirm && !_controls.busy
                    ? _confirmSheet
                    : null,
                child: const Text('Confirm and import'),
              ),
              TextButton(
                onPressed: view.canCancel ? _controls.cancelItem : null,
                child: const Text('Cancel this item'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _conflict(ReviewItemView view, PreviewState preview) {
    final conflict = view.conflict!;
    final controls = ref.read(previewControlsProvider);
    return [
      Text(conflict.headline),
      for (final row in conflict.rows)
        DuplicateRowTile(
          row: row,
          view: view,
          preview: controls,
          previewState: preview,
        ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: view.useExistingTrackUuid != null && !_controls.busy
                ? _controls.useExisting
                : null,
            child: const Text('Use existing track'),
          ),
          TextButton(
            onPressed: view.canBackToReview && !_controls.busy
                ? _controls.backToReview
                : null,
            child: const Text('Back to review'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _duplicates(ReviewItemView view, PreviewState preview) {
    final duplicates = view.duplicates;
    final controls = ref.read(previewControlsProvider);
    final stagedPlaying =
        preview.source == StagedUploadPreview(view.itemUuid) &&
        previewIsActive(preview.status);
    return [
      if (duplicates.coverage != null) Text(duplicates.coverage!),
      for (final note in duplicates.notes) Text(note),
      if (duplicates.banners.isNotEmpty) ...[
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            TextButton(
              onPressed: stagedPlaying
                  ? controls.pause
                  : view.canPreview
                  ? () => controls.playStaged(view.itemUuid)
                  : null,
              child: Text(stagedPlaying ? 'Pause this file' : 'Play this file'),
            ),
            if (duplicates.thisFile != null)
              Text('This file: ${duplicates.thisFile}'),
          ],
        ),
      ],
      for (final banner in duplicates.banners)
        UploadDuplicateBanner(
          key: ValueKey(
            'dup-${view.itemUuid}-${view.reviewVersion}-${banner.kind.name}',
          ),
          banner: banner,
          view: view,
          controls: _controls,
          preview: controls,
          previewState: preview,
        ),
    ];
  }

  Widget _form(String uuid, int version) {
    return MetadataForm(
      key: ValueKey('review-form-$uuid-$version'),
      fields: _controls.fields,
      current: _controls.detectedValue,
      edit: _controls.edit,
      onChanged: _controls.editChanged,
      suggestionsFor: _controls.suggestions,
      autocompleteKeys: const {'artist', 'album_artist', 'album', 'genre'},
    );
  }

  Widget _preview(PreviewState state, String uuid, bool enabled) {
    final preview = ref.read(previewControlsProvider);
    final source = state.source;
    final playing =
        (source == StagedUploadPreview(uuid) || source is LibraryTrackPreview) &&
        previewIsActive(state.status);
    final message = previewStatusMessage(state.status);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        TextButton(
          onPressed: playing
              ? preview.pause
              : enabled
              ? () => preview.playStaged(uuid)
              : null,
          child: Text(playing ? 'Pause preview' : 'Play preview'),
        ),
        if (message != null) Text(message),
      ],
    );
  }
}
