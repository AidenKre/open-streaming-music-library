// Phase 8 spec §6 "Possible duplicates": the page. SC-26 view: it renders
// DuplicatesControls and forwards every input to it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/duplicates/duplicates_review.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_sheet.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';

class DuplicatesPage extends ConsumerStatefulWidget {
  const DuplicatesPage({super.key});

  @override
  ConsumerState<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends ConsumerState<DuplicatesPage> {
  late final DuplicatesControls controls;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    controls = ref.read(duplicatesControllerFactoryProvider)();
  }

  @override
  void dispose() {
    // Only the controller goes; the preview is closed from the pop event.
    controls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) controls.leave();
      },
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          appBar: AppBar(title: const Text('Possible duplicates')),
          body: ListenableBuilder(
            listenable: controls,
            builder: (context, _) => _body(context),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final pairs = controls.pairs;
    final children = <Widget>[
      _header(),
      if (controls.previewMessage != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(controls.previewMessage!),
        ),
      if (controls.message != null) _messageBar(controls.message!),
      _chips(),
      ..._listState(pairs.isEmpty),
      for (final row in pairs) _pairRow(context, row),
      if (controls.hasMore)
        Center(
          child: TextButton(
            key: const Key('load-more'),
            onPressed: controls.loadMore,
            child: const Text('Load more'),
          ),
        ),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: children,
    );
  }

  Widget _header() {
    final Widget content;
    switch (controls.summaryLoad) {
      case DuplicatesLoad.loading:
        content = const Center(child: CircularProgressIndicator());
      case DuplicatesLoad.needsConnection:
        // The list's own notice carries the one Retry when it needs a
        // connection too.
        content = Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(controls.unreachableText),
            if (controls.listLoad != DuplicatesLoad.needsConnection)
              _connectionRetry(),
          ],
        );
      case DuplicatesLoad.failed:
        content = LoadFailureNotice(
          message: "Couldn't load the scan status",
          onRetry: controls.refresh,
          retryKey: const Key('retry-summary'),
          compact: true,
        );
      case DuplicatesLoad.idle:
      case DuplicatesLoad.loaded:
        final h = controls.header;
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (h?.toolMissing != null) Text(h!.toolMissing!),
            if (h?.scanLine != null) Text(h!.scanLine!),
            for (final note in h?.notes ?? const <String>[]) Text(note),
            if (h?.outcome != null)
              Text(
                h!.outcome!,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
          ],
        );
    }
    return Padding(
      key: const Key('duplicates-header'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: content,
    );
  }

  Widget _connectionRetry() => TextButton(
    key: const Key('retry-connection'),
    onPressed: controls.refresh,
    child: const Text('Retry'),
  );

  Widget _messageBar(String message) => Row(
    children: [
      Expanded(child: Text(message)),
      IconButton(
        key: const Key('close-message'),
        icon: const Icon(Icons.close),
        tooltip: 'Dismiss message',
        onPressed: controls.clearMessage,
      ),
    ],
  );

  Widget _chips() => Wrap(
    spacing: 8,
    children: [
      ChoiceChip(
        key: const Key('chip-open'),
        label: const Text('Open'),
        selected: controls.filter == DuplicatesFilter.open,
        onSelected: (_) => controls.setFilter(DuplicatesFilter.open),
      ),
      ChoiceChip(
        key: const Key('chip-dismissed'),
        label: const Text('Dismissed'),
        selected: controls.filter == DuplicatesFilter.dismissed,
        onSelected: (_) => controls.setFilter(DuplicatesFilter.dismissed),
      ),
    ],
  );

  List<Widget> _listState(bool empty) {
    switch (controls.listLoad) {
      case DuplicatesLoad.loading:
        return empty
            ? const [Center(child: CircularProgressIndicator())]
            : const [];
      case DuplicatesLoad.failed:
        return [
          LoadFailureNotice(
            message: "Couldn't load the pairs",
            onRetry: controls.refresh,
            retryKey: const Key('retry-list'),
            compact: !empty,
          ),
        ];
      case DuplicatesLoad.needsConnection:
        return [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(controls.unreachableText),
              _connectionRetry(),
            ],
          ),
        ];
      case DuplicatesLoad.idle:
      case DuplicatesLoad.loaded:
        if (!empty || controls.hasMore) return const [];
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              controls.filter == DuplicatesFilter.open
                  ? 'No pairs to review'
                  : 'No dismissed pairs',
            ),
          ),
        ];
    }
  }

  Widget _pairRow(BuildContext context, DuplicatePairView row) {
    final open = controls.filter == DuplicatesFilter.open;
    return Card(
      key: Key('pair-${row.key}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Chip(label: Text(row.badge)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _copy(context, row, row.a)),
                const SizedBox(width: 12),
                Expanded(child: _copy(context, row, row.b)),
              ],
            ),
            if (controls.deleteStatus(row) case final status?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(status),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: Key('aside-${row.key}'),
                onPressed: () => _setAside(context, row, open),
                child: Text(open ? 'Not duplicates' : 'Restore'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _setAside(BuildContext context, DuplicatePairView row, bool open) {
    final messenger = _messenger.currentState;
    if (messenger == null || !controls.setAside(row)) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(open ? 'Marked as not duplicates' : 'Restored to Open'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => controls.undo(row),
        ),
      ),
    );
  }

  Widget _copy(
    BuildContext context,
    DuplicatePairView row,
    DuplicateCopyView copy,
  ) {
    final uuid = copy.uuid;
    final playing =
        controls.previewingUuid == uuid &&
        previewIsActive(controls.previewStatus);
    final highlight = Theme.of(context).colorScheme.tertiaryContainer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          copy.track.title ?? 'Unknown title',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(copy.track.artist ?? 'Unknown artist'),
        Text(copyIdLine(uuid)),
        const SizedBox(height: 4),
        for (final f in DuplicateField.values)
          _field(row, copy, f, highlight),
        if (copyFileStatusText(copy.track) case final status?) Text(status),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              key: Key('play-$uuid'),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: controls.canPlay
                  ? () => controls.togglePlay(uuid)
                  : null,
            ),
            if (controls.canDeleteCopy && !controls.deleteBlocked(row))
              TextButton(
                key: Key('delete-$uuid'),
                onPressed: () => _delete(context, row, copy),
                child: const Text('Delete this copy'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _field(
    DuplicatePairView row,
    DuplicateCopyView copy,
    DuplicateField f,
    Color highlight,
  ) {
    final text = Text('${duplicateFieldLabel(f)}: ${copy.fields[f]}');
    if (!row.differing.contains(f)) return text;
    return Container(
      key: Key('differs-${copy.uuid}-${f.name}'),
      color: highlight,
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontWeight: FontWeight.bold),
        child: text,
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    DuplicatePairView row,
    DuplicateCopyView copy,
  ) async {
    final review = controls.startDeleteCopy(row, copy.uuid);
    if (review == null) return;
    try {
      await showDeletionReview(
        context,
        review,
        details: {copy.uuid: copy.identityLines},
      );
    } finally {
      controls.endDeleteCopy(review);
    }
  }
}
