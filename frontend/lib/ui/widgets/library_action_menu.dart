import 'package:flutter/material.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';

/// One entry of a library action menu.
sealed class LibraryMenuEntry {
  const LibraryMenuEntry();
}

/// A plain menu row. A null [onSelected] renders it disabled (shown, not
/// tappable).
final class LibraryMenuAction extends LibraryMenuEntry {
  const LibraryMenuAction({
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onSelected;
}

/// The split Download row: default quality, or pick one.
final class LibraryMenuDownload extends LibraryMenuEntry {
  const LibraryMenuDownload({
    required this.onDownload,
    required this.onDownloadAtQuality,
  });

  final VoidCallback onDownload;
  final void Function(String quality) onDownloadAtQuality;
}

/// The one library action menu (SC-06), used by TrackTile, LibraryCard and
/// (4A.2) TrackCard so no surface forks it.
///
/// Every entry acts on [scope] through [actions]; enablement comes only from
/// [availability] (play/queue: `canPlay`; Download: `canDownload`; Delete:
/// `hasAnyDownloaded`; a damaged track download: its re-download and the
/// Delete of the kept file). Navigation entries are the surface's callbacks
/// (`library_routes.dart`), shown only when supplied. Surface-specific rows
/// (Convert, Cancel conversion) come in through [extraActions], last.
List<LibraryMenuEntry> buildLibraryActionMenu(
  LibraryScope scope,
  PlaybackAvailability availability, {
  required LibraryActionControls actions,
  VoidCallback? onOpenDetail,
  VoidCallback? onGetInfo,
  List<LibraryMenuEntry> extraActions = const [],
}) {
  final isTrack = scope is TrackScope;
  // Decision 6: a damaged download replaces the Download row with its
  // re-download and offers the Delete of the kept file.
  final damaged = scope is TrackScope && scope.track.isDownloadDamaged;
  final canPlay = availability.canPlay;
  return [
    if (onOpenDetail != null)
      LibraryMenuAction(
        icon: Icons.open_in_new,
        label: scope is ArtistScope ? 'Go to artist' : 'Go to album',
        onSelected: onOpenDetail,
      ),
    if (onGetInfo != null)
      LibraryMenuAction(
        icon: Icons.info_outline,
        label: 'Get Info',
        onSelected: onGetInfo,
      ),
    LibraryMenuAction(
      icon: Icons.playlist_play,
      label: 'Play Next',
      onSelected: canPlay ? () => actions.playNext(scope) : null,
    ),
    LibraryMenuAction(
      icon: Icons.queue_music,
      label: 'Add to Queue',
      onSelected: canPlay ? () => actions.addToQueue(scope) : null,
    ),
    // Download (the missing tracks) and Delete are independent: a partially
    // downloaded collection shows both.
    if (damaged) ...[
      LibraryMenuAction(
        icon: Icons.report_problem_outlined,
        label: 'Damaged download: re-download',
        onSelected:
            availability.canDownload ? () => actions.download(scope) : null,
      ),
      LibraryMenuAction(
        icon: Icons.delete_outline,
        label: 'Delete damaged file',
        onSelected: () => actions.deleteDownloads(scope),
      ),
    ] else if (availability.canDownload)
      LibraryMenuDownload(
        onDownload: () => actions.download(scope),
        onDownloadAtQuality: (q) => actions.downloadAtQuality(scope, q),
      ),
    if (availability.hasAnyDownloaded)
      LibraryMenuAction(
        icon: Icons.delete_outline,
        // Local downloads only; never anything on the server.
        label: isTrack ? 'Delete download' : 'Delete downloads',
        onSelected: () => actions.deleteDownloads(scope),
      ),
    ...extraActions,
  ];
}

/// Shows [entries] as a modal bottom sheet. Selecting an entry closes the
/// sheet first, then runs it.
Future<void> showLibraryActionMenu(
  BuildContext context,
  List<LibraryMenuEntry> entries,
) {
  return showModalBottomSheet<void>(
    context: SessionHost.sheetContext(context),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in entries)
              switch (entry) {
                LibraryMenuAction(
                  :final icon,
                  :final label,
                  :final onSelected,
                ) =>
                  ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    enabled: onSelected != null,
                    onTap: onSelected == null
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            onSelected();
                          },
                  ),
                LibraryMenuDownload(
                  :final onDownload,
                  :final onDownloadAtQuality,
                ) =>
                  SplitDownloadTile(
                    onDownload: () {
                      Navigator.pop(ctx);
                      onDownload();
                    },
                    onDownloadAtQuality: (quality) {
                      Navigator.pop(ctx);
                      onDownloadAtQuality(quality);
                    },
                  ),
              },
          ],
        ),
      ),
    ),
  );
}
