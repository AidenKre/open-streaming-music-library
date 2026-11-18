// Phase 8 spec §4 para 3, §6: the deletion review sheet and its confirmation.
// SC-26 view: it renders DeletionReviewControls and forwards input; every
// rule and every model word comes from the model layer.
import 'package:flutter/material.dart';
import 'package:frontend/models/id_hints.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';

const _unknownTrack = 'Unknown track';
const _missingFileEntry = 'Remove missing-file catalog entry';

/// Opens the review over [review]; true when a deletion was confirmed and
/// handed over, false when the sheet was dismissed.
///
/// This does not request the preview itself: call `review.requestPreview()`
/// first, as the Manage library page does.
///
/// This is also the single-track entry Possible duplicates (8B.3) uses:
/// create a one-track selection, a review from
/// `deletionReviewControllerFactoryProvider`, call `requestPreview()`, then
/// this.
Future<bool> showDeletionReview(
  BuildContext context,
  DeletionReviewControls review, {
  Map<String, List<String>> details = const {},
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DeletionReviewSheet(review: review, details: details),
  );
  return confirmed ?? false;
}

class DeletionReviewSheet extends StatelessWidget {
  const DeletionReviewSheet({
    super.key,
    required this.review,
    this.details = const {},
  });

  final DeletionReviewControls review;

  /// Extra lines that name a target, by uuid (e.g. a duplicate copy's
  /// format and bitrate); shown only beside that target.
  final Map<String, List<String>> details;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: review,
    builder: (context, _) {
      final theme = Theme.of(context);
      final preview = review.preview;
      final message = review.message;
      final blocked = review.blockedReason;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Review deletion', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            if (review.stage == ReviewStage.previewing)
              const Center(child: CircularProgressIndicator()),
            if (preview != null && review.stage == ReviewStage.ready) ...[
              for (final t in preview.targets)
                _TargetRow(
                  review,
                  t,
                  _hintsOf(preview)[t.uuid],
                  details[t.uuid] ?? const [],
                ),
            ],
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (blocked != null) ...[const SizedBox(height: 8), Text(blocked)],
            const SizedBox(height: 12),
            if (preview != null && review.stage == ReviewStage.ready)
              FilledButton(
                key: const Key('confirm-deletion'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: review.canConfirm
                    ? () => _openDialog(context, preview)
                    : null,
                child: Text(
                  preview.count == 1
                      ? 'Delete 1 track…'
                      : 'Delete ${preview.count} tracks…',
                ),
              ),
            if (review.stage == ReviewStage.idle ||
                review.stage == ReviewStage.failed)
              TextButton(
                key: const Key('review-again'),
                onPressed: review.requestPreview,
                child: const Text('Review again'),
              ),
            TextButton(
              key: const Key('close-review'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _openDialog(BuildContext context, DeletionPreview shown) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      // A dismissal must never look like Cancel while a deletion is being
      // handed over: Cancel is the only way out.
      barrierDismissible: false,
      builder: (_) => _ConfirmationDialog(
        review: review,
        shown: shown,
        details: details,
      ),
    );
    if (confirmed == true) navigator.pop(true);
  }
}

/// The id hint per uuid for look-alike targets of [preview].
Map<String, String> _hintsOf(DeletionPreview preview) => idHints([
  for (final t in preview.targets)
    (uuid: t.uuid, title: t.title, artist: t.artist, album: t.album),
]);

/// "Artist · Album" with whatever is known; null when neither is.
String? _byline(PreviewedTarget t) {
  final line = [t.artist, t.album].whereType<String>().join(' · ');
  return line.isEmpty ? null : line;
}

class _TargetRow extends StatelessWidget {
  const _TargetRow(this.review, this.target, this.idHint, this.details);

  final DeletionReviewControls review;
  final PreviewedTarget target;
  final String? idHint;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final byline = _byline(target);
    return Padding(
      key: Key('review-target-${target.uuid}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            target.title ?? _unknownTrack,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (byline != null) Text(byline),
          if (idHint != null) Text('ID $idHint'),
          for (final line in details) Text(line),
          Text(previewVerdictText(target.verdict)),
          Wrap(
            spacing: 8,
            children: [
              if (target.refreshed != null)
                TextButton(
                  key: Key('refresh-${target.uuid}'),
                  onPressed: () => review.refreshTarget(target.uuid),
                  child: const Text('Refresh'),
                ),
              TextButton(
                key: Key('remove-${target.uuid}'),
                onPressed: () => review.removeTarget(target.uuid),
                child: const Text('Remove'),
              ),
            ],
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

class _ConfirmationDialog extends StatefulWidget {
  const _ConfirmationDialog({
    required this.review,
    required this.shown,
    this.details = const {},
  });

  final DeletionReviewControls review;
  final DeletionPreview shown;
  final Map<String, List<String>> details;

  @override
  State<_ConfirmationDialog> createState() => _ConfirmationDialogState();
}

class _ConfirmationDialogState extends State<_ConfirmationDialog> {
  final _typed = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() => _sending = true);
    final ok = await widget.review.confirm(
      widget.shown,
      confirmedCount: widget.shown.count,
    );
    if (mounted) Navigator.of(context).pop(ok);
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.shown;
    final n = shown.count;
    final needsTyping = n > 1;
    // Judged against the preview this dialog shows, not a newer one.
    final typedOk = !needsTyping || typedCountMatches(_typed.text, n);
    final hints = _hintsOf(shown);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('deletion-confirmation'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // In the scrolling content, not AlertDialog.title: a title that
              // does not scroll would overflow at large text sizes.
              Text(
                n == 1
                    ? 'Delete 1 track from the server permanently'
                    : 'Delete $n tracks from the server permanently',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              for (final t in shown.targets) ...[
                Text(t.title ?? _unknownTrack),
                if (_byline(t) != null) Text(_byline(t)!),
                if (hints[t.uuid] != null) Text('ID ${hints[t.uuid]}'),
                for (final line in widget.details[t.uuid] ?? const <String>[])
                  Text(line),
                if (t.verdict == PreviewVerdict.missingMaster)
                  const Text(_missingFileEntry),
                const SizedBox(height: 4),
              ],
              const SizedBox(height: 8),
              const Text(
                "This removes the server's master files and the downloads "
                'synced to your devices.',
              ),
              const SizedBox(height: 8),
              const Text(
                'This is different from removing a download from this device '
                'only.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Tracks currently playing on any device will stop at the next '
                'buffer refill.',
              ),
              const SizedBox(height: 8),
              const Text("This can't be undone."),
              if (needsTyping) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('typed-count'),
                  controller: _typed,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'Type $n to confirm'),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('cancel-deletion'),
            onPressed: _sending ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete-permanently'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: typedOk && !_sending ? _confirm : null,
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
  }
}
