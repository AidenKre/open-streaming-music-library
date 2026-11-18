import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/ui/uploads/upload_children_page.dart';
import 'package:frontend/ui/uploads/upload_explained.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';
import 'package:frontend/ui/widgets/server_blocked_banner.dart';

/// The Uploads page (spec §7 para 3; SC-08 `SessionDestination.uploads`).
/// Renders only what [UploadsControls] says and forwards every input to it.
class UploadsPage extends ConsumerStatefulWidget {
  const UploadsPage({super.key});

  @override
  ConsumerState<UploadsPage> createState() => _UploadsPageState();
}

class _UploadsPageState extends ConsumerState<UploadsPage> {
  late final UploadsControls _controls;
  late final AppLifecycleListener _lifecycle;
  late bool _reportedVisible;

  /// On screen: a window that lost focus (inactive) still counts.
  static bool _isForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(uploadsControllerFactoryProvider)();
    _reportedVisible = _isForeground(
      WidgetsBinding.instance.lifecycleState,
    );
    _controls.setPageVisible(_reportedVisible);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final visible = _isForeground(state);
        if (visible == _reportedVisible) return;
        _reportedVisible = visible;
        _controls.setPageVisible(visible);
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controls.dispose();
    super.dispose();
  }

  void _reviewTags(UploadRow row) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UploadReviewPage(
          batchUuid: row.batchUuid,
          startAt: row.itemUuid,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Uploads')),
    body: ListenableBuilder(
      listenable: _controls,
      builder: (context, _) {
        final overview = _controls.overview;
        if (overview == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = overview.rows;
        return ListView.builder(
          itemCount: rows.isEmpty ? 2 : rows.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return _Header(
                overview: overview,
                adding: _controls.adding,
                notice: _controls.notice,
                onAdd: _controls.addFiles,
                onDismiss: _controls.dismissNotice,
              );
            }
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No uploads yet.')),
              );
            }
            final row = rows[i - 1];
            return _UploadRowTile(
              row: row,
              overview: overview,
              onCancel: () => _controls.cancel(row.itemUuid),
              onReselect: () => _controls.reselect(row.itemUuid),
              onRetry: () => _controls.retry(row.itemUuid),
              onReviewTags: () => _reviewTags(row),
              onShowFiles: () {
                _controls.loadChildren(row.batchUuid, row.itemUuid);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => UploadChildrenPage(
                      controls: _controls,
                      parent: row,
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.overview,
    required this.adding,
    required this.notice,
    required this.onAdd,
    required this.onDismiss,
  });
  final UploadsOverview overview;
  final bool adding;
  final UploadsNotice? notice;
  final VoidCallback onAdd;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final notice = this.notice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        switch (overview.availability) {
          UploadsAvailability.serverBlocked => const ServerBlockedBanner(),
          UploadsAvailability.offline => const OfflineBanner(),
          UploadsAvailability.cachedOnly ||
          UploadsAvailability.notAdvertised => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(overview.unavailableText!, style: style),
          ),
          UploadsAvailability.available => const SizedBox.shrink(),
        },
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              explainedByAvailability(
                overview,
                FilledButton(
                  onPressed: overview.canAddFiles && !adding ? onAdd : null,
                  child: Text(adding ? 'Adding files…' : 'Add files'),
                ),
              ),
              if (overview.rows.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(overview.counts.summaryText, style: style),
              ],
              if (overview.limitsText != null)
                Text(overview.limitsText!, style: style),
            ],
          ),
        ),
        if (notice != null)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(notice.title, style: style),
                        for (final line in notice.lines)
                          Text(line, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, semanticLabel: 'Dismiss'),
                    tooltip: 'Dismiss',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: onDismiss,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _UploadRowTile extends StatelessWidget {
  _UploadRowTile({
    required this.row,
    required this.overview,
    required this.onCancel,
    required this.onReselect,
    required this.onRetry,
    required this.onReviewTags,
    required this.onShowFiles,
  }) : super(key: ValueKey('upload-row-${row.itemUuid}'));

  final UploadRow row;
  final UploadsOverview overview;
  final VoidCallback onCancel;
  final VoidCallback onReselect;
  final VoidCallback onRetry;
  final VoidCallback onReviewTags;
  final VoidCallback onShowFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = row.sizeText == null
        ? row.statusText
        : '${row.statusText} · ${row.sizeText}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: row.displayName,
                      child: Text(
                        row.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    Text(status, style: theme.textTheme.bodySmall),
                    if (row.detailText != null)
                      Text(
                        row.detailText!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: row.needsAttention
                              ? theme.colorScheme.error
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              if (row.offersCancel)
                explainedByAvailability(
                  overview,
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      semanticLabel: 'Cancel ${row.displayName}',
                    ),
                    tooltip: overview.unavailableText == null
                        ? 'Cancel upload'
                        : null,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: row.canCancel ? onCancel : null,
                  ),
                ),
            ],
          ),
          if (row.sending)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: row.fraction,
                semanticsLabel: 'Upload progress for ${row.displayName}',
              ),
            ),
          if (row.offersReviewTags ||
              row.offersReselect ||
              row.offersRetry ||
              row.offersChildren)
            Wrap(
              spacing: 8,
              children: [
                if (row.offersReviewTags)
                  explainedByAvailability(
                    overview,
                    TextButton(
                      onPressed: row.canReviewTags ? onReviewTags : null,
                      child: Text(
                        'Review tags',
                        semanticsLabel: 'Review tags for ${row.displayName}',
                      ),
                    ),
                  ),
                if (row.offersReselect)
                  explainedByAvailability(
                    overview,
                    TextButton(
                      onPressed: row.canReselect ? onReselect : null,
                      child: Text(
                        'Reselect file',
                        semanticsLabel: 'Reselect file for ${row.displayName}',
                      ),
                    ),
                  ),
                if (row.offersRetry)
                  explainedByAvailability(
                    overview,
                    TextButton(
                      onPressed: row.canRetry ? onRetry : null,
                      child: Text(
                        'Retry',
                        semanticsLabel: 'Retry ${row.displayName}',
                      ),
                    ),
                  ),
                if (row.offersChildren)
                  explainedByAvailability(
                    overview,
                    TextButton(
                      onPressed: row.canOpenChildren ? onShowFiles : null,
                      child: Text(
                        'Show files',
                        semanticsLabel: 'Show files in ${row.displayName}',
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
