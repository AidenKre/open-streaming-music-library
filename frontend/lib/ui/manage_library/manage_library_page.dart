// Phase 8 spec §3, §4, §6 (piece 8B.1c): the Manage library page. SC-26 view:
// it observes ManageLibraryControls and forwards input; rules and words come
// from the model. Leaving the page disposes the controller, which drops an
// unsubmitted selection.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/ui/manage_library/delete_jobs_view.dart';
import 'package:frontend/ui/manage_library/deletion_review_sheet.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';
import 'package:frontend/ui/tracks_page.dart';

class ManageLibraryPage extends ConsumerStatefulWidget {
  const ManageLibraryPage({super.key});

  @override
  ConsumerState<ManageLibraryPage> createState() => _ManageLibraryPageState();
}

class _ManageLibraryPageState extends ConsumerState<ManageLibraryPage> {
  late final ManageLibraryControls _controls;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(manageLibraryControllerFactoryProvider)();
  }

  @override
  void dispose() {
    _controls.dispose();
    super.dispose();
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeleteJobsPage(controls: _controls),
      ),
    );
  }

  Future<void> _review() async {
    final navigator = Navigator.of(context);
    _controls.review.requestPreview();
    final confirmed = await showDeletionReview(context, _controls.review);
    if (confirmed && mounted) {
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => DeleteJobsPage(controls: _controls),
        ),
      );
    }
  }

  String _bannerText(ServerDeleteAvailability a) => switch (a) {
    ServerDeleteAvailability.enabled => deletionEnabledBannerText(),
    ServerDeleteAvailability.switchedOff => unavailableText(
      DeleteJobsUnavailableReason.switchedOff,
    ),
    ServerDeleteAvailability.notOffered => unavailableText(
      DeleteJobsUnavailableReason.notAdvertised,
    ),
    ServerDeleteAvailability.unreachable => deletionUnreachableBannerText(),
    ServerDeleteAvailability.checking => deletionCheckingBannerText(),
  };

  @override
  Widget build(BuildContext context) {
    final controls = _controls;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Deletion history',
            onPressed: _openHistory,
          ),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([controls, controls.selection]),
        builder: (context, _) {
          final availability = controls.availability;
          final scheme = Theme.of(context).colorScheme;
          return Column(
            children: [
              Container(
                key: const Key('manage-library-banner'),
                width: double.infinity,
                color: scheme.surfaceContainerHighest,
                padding: const EdgeInsets.all(12),
                child: Text(_bannerText(availability)),
              ),
              Expanded(
                child: TracksPage(browseAll: true, selection: controls.selection),
              ),
              if (controls.selection.count > 0) _SelectedPanel(controls),
              if (availability == ServerDeleteAvailability.enabled)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('review-deletion'),
                      onPressed: controls.selection.count > 0 ? _review : null,
                      child: const Text('Review deletion'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SelectedPanel extends StatelessWidget {
  const _SelectedPanel(this.controls);

  final ManageLibraryControls controls;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('selected-panel'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('${controls.selection.count} selected')),
              TextButton(
                onPressed: controls.clearSelection,
                child: const Text('Clear'),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in controls.selectedItems)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      item.title ?? 'No longer in your library on this device',
                    ),
                    subtitle: _subtitle(item),
                    trailing: IconButton(
                      key: Key('remove-selected-${item.uuid}'),
                      icon: const Icon(Icons.close),
                      tooltip: 'Remove from selection',
                      onPressed: () => controls.removeSelected(item.uuid),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget? _subtitle(SelectedItemView item) {
    final lines = [
      [item.artist, item.album].whereType<String>().join(' · '),
      if (item.idHint != null) 'ID ${item.idHint}',
    ].where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final l in lines) Text(l)],
    );
  }
}
