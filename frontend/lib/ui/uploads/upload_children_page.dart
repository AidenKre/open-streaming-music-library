import 'package:flutter/material.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:frontend/services/uploads/uploads_overview.dart' show UploadRow;
import 'package:frontend/ui/uploads/upload_explained.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';

/// The files of one unpacked ZIP. Borrows the Uploads page's [controls]
/// (which owns and disposes it).
class UploadChildrenPage extends StatelessWidget {
  const UploadChildrenPage({
    super.key,
    required this.controls,
    required this.parent,
  });
  final UploadsControls controls;
  final UploadRow parent;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        parent.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: ListenableBuilder(
      listenable: controls,
      builder: (context, _) =>
          switch (controls.childrenOf(parent.itemUuid)) {
            ChildListLoaded(:final children) => _Files(
              zip: children,
              controls: controls,
              parent: parent,
            ),
            ChildListFailed() => _failed(),
            // Not asked for yet (a single frame: Show files asks first).
            ChildListLoading() || null => _loading(),
          },
    ),
  );

  Widget _loading() {
    // Behind a paused network the load can wait a long time: say why.
    final overview = controls.overview;
    final why = overview?.networkActionsEnabled == false
        ? overview!.unavailableText
        : null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (why != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(why, textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }

  Widget _failed() {
    final overview = controls.overview;
    final canRetry = overview?.networkActionsEnabled ?? false;
    final retry = TextButton(
      onPressed: canRetry
          ? () => controls.loadChildren(parent.batchUuid, parent.itemUuid)
          : null,
      child: const Text('Try again'),
    );
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Couldn't load the files in this archive."),
            overview == null ? retry : explainedByAvailability(overview, retry),
          ],
        ),
      ),
    );
  }
}

class _Files extends StatelessWidget {
  const _Files({
    required this.zip,
    required this.controls,
    required this.parent,
  });
  final ZipChildren zip;
  final UploadsControls controls;
  final UploadRow parent;

  void _review(BuildContext context, UploadChildRow child) {
    if (controls.reviewTags(child.itemUuid) != ReviewTagsOutcome.open) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UploadReviewPage(
          batchUuid: parent.batchUuid,
          startAt: child.itemUuid,
        ),
      ),
    );
  }

  Widget _reviewButton(BuildContext context, UploadChildRow child) {
    final button = TextButton(
      onPressed: controls.overview?.networkActionsEnabled == true
          ? () => _review(context, child)
          : null,
      child: Text(
        'Review tags',
        semanticsLabel: 'Review tags for ${child.displayName}',
      ),
    );
    final overview = controls.overview;
    return overview == null ? button : explainedByAvailability(overview, button);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: zip.children.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(zip.countsText, style: theme.textTheme.bodyMedium),
          );
        }
        final child = zip.children[i - 1];
        return Padding(
          key: ValueKey('upload-child-${child.itemUuid}'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tooltip(
                message: child.displayName,
                child: Text(
                  child.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              Text(child.statusText, style: theme.textTheme.bodySmall),
              if (child.detailText != null)
                Text(
                  child.detailText!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: child.needsAttention ? theme.colorScheme.error : null,
                  ),
                ),
              if (child.offersReviewTags)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _reviewButton(context, child),
                ),
            ],
          ),
        );
      },
    );
  }
}
