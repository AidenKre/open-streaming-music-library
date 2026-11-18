import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/collection_detail_controller.dart';
import 'package:frontend/ui/library_actions.dart';

/// The in-body Play / Shuffle header of an album or artist detail page (never
/// the browse-all lists, spec §5). A view: it renders the controller's busy
/// state and message and the shared availability predicate, and forwards taps
/// to the controller only (SC-26).
class CollectionActionHeader extends ConsumerWidget {
  const CollectionActionHeader(
      {super.key, required this.scope, this.empty = false});

  final LibraryScope scope;

  /// The detail list settled with nothing in it.
  final bool empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(collectionDetailControllerProvider(scope));
    final availability = ref.watch(playbackAvailabilityProvider(scope));
    final noun = scope is AlbumScope ? 'album' : 'artist';
    return ListenableBuilder(
      listenable: controls,
      builder: (context, _) {
        final enabled = availability.canPlay && !controls.busy && !empty;
        final loading = controls.busy ||
            (availability.isUnknown && !availability.canPlay);
        final unplayable = !availability.isUnknown && !availability.canPlay;
        final note = controls.message ??
            (unplayable
                ? nothingPlaysOfflineMessage
                : (empty ? 'No tracks to play.' : null));
        final enabledRetry = availability.canPlay && !empty;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Semantics(
                    label: 'Play $noun',
                    button: true,
                    enabled: enabled,
                    onTap: enabled ? controls.play : null,
                    excludeSemantics: true,
                    child: FilledButton.icon(
                      onPressed: enabled ? controls.play : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                    ),
                  ),
                  Semantics(
                    label: 'Shuffle $noun',
                    button: true,
                    enabled: enabled,
                    onTap: enabled ? controls.shuffle : null,
                    excludeSemantics: true,
                    child: OutlinedButton.icon(
                      onPressed: enabled ? controls.shuffle : null,
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Shuffle'),
                    ),
                  ),
                  if (loading)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text(note),
                      if (controls.message != null && controls.canRetry)
                        TextButton(
                          onPressed: enabledRetry ? controls.retry : null,
                          child: const Text('Retry'),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
