import 'dart:async';

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
/// tappable); a row given only [onSubmit] is enabled and its [onSelected]
/// runs [onSubmit], dropping the message.
final class LibraryMenuAction extends LibraryMenuEntry {
  const LibraryMenuAction({
    required this.icon,
    required this.label,
    VoidCallback? onSelected,
    this.onSubmit,
  }) : _onSelected = onSelected;

  final IconData icon;
  final String label;
  final VoidCallback? _onSelected;

  VoidCallback? get onSelected {
    final submit = onSubmit;
    return _onSelected ?? (submit == null ? null : () => submit());
  }

  /// When set, the renderer awaits this instead of [onSelected] and shows
  /// the text it returns, if any, in a SnackBar. The text comes from the
  /// controller layer; the view only displays it.
  final Future<String?> Function()? onSubmit;
}

/// The split Download row: default quality, or pick one. Like
/// [LibraryMenuAction.onSubmit], the renderer awaits each and shows the
/// text it returns, if any.
final class LibraryMenuDownload extends LibraryMenuEntry {
  const LibraryMenuDownload({
    required this.onDownload,
    required this.onDownloadAtQuality,
  });

  final Future<String?> Function() onDownload;
  final Future<String?> Function(String quality) onDownloadAtQuality;
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
  // U30-A-01: awaited, and a failure is reported (not silent).
  Future<String?> download() => downloadActionMessage(
    () => actions.download(scope),
    damaged ? redownloadFailedMessage : downloadFailedMessage(scope),
  );
  Future<String?> deleteDownloads() => downloadActionMessage(
    () => actions.deleteDownloads(scope),
    deleteDownloadsFailedMessage(scope),
  );
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
      onSubmit: canPlay
          ? () async => playbackOutcomeMessage(await actions.playNext(scope))
          : null,
    ),
    LibraryMenuAction(
      icon: Icons.queue_music,
      label: 'Add to Queue',
      onSubmit: canPlay
          ? () async => playbackOutcomeMessage(await actions.addToQueue(scope))
          : null,
    ),
    // Download (the missing tracks) and Delete are independent: a partially
    // downloaded collection shows both.
    if (damaged) ...[
      LibraryMenuAction(
        icon: Icons.report_problem_outlined,
        label: 'Damaged download: re-download',
        onSubmit: availability.canDownload ? download : null,
      ),
      LibraryMenuAction(
        icon: Icons.delete_outline,
        label: 'Delete damaged file',
        onSubmit: deleteDownloads,
      ),
    ] else if (availability.canDownload)
      LibraryMenuDownload(
        onDownload: download,
        onDownloadAtQuality: (q) => downloadActionMessage(
          () => actions.downloadAtQuality(scope, q),
          downloadFailedMessage(scope),
        ),
      ),
    if (availability.hasAnyDownloaded)
      LibraryMenuAction(
        icon: Icons.delete_outline,
        // Local downloads only; never anything on the server.
        label: isTrack ? 'Delete download' : 'Delete downloads',
        onSubmit: deleteDownloads,
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
  // The caller's messenger, captured before the sheet closes.
  final messenger = ScaffoldMessenger.maybeOf(context);
  Future<void> report(Future<String?> pending) async {
    final message = await pending;
    if (message != null && messenger != null && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

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
                  :final onSubmit,
                ) =>
                  ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    enabled: onSelected != null,
                    onTap: onSelected == null
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            if (onSubmit != null) {
                              await report(onSubmit());
                            } else {
                              onSelected();
                            }
                          },
                  ),
                LibraryMenuDownload(
                  :final onDownload,
                  :final onDownloadAtQuality,
                ) =>
                  SplitDownloadTile(
                    onDownload: () {
                      Navigator.pop(ctx);
                      unawaited(report(onDownload()));
                    },
                    onDownloadAtQuality: (quality) {
                      Navigator.pop(ctx);
                      unawaited(report(onDownloadAtQuality(quality)));
                    },
                  ),
              },
          ],
        ),
      ),
    ),
  );
}
