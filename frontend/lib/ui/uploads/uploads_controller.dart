import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/uploads/upload_manager.dart'
    show uploadManagerProvider;
import 'package:frontend/services/uploads/upload_source_picker.dart';
import 'package:frontend/services/uploads/upload_status_text.dart';
import 'package:frontend/services/uploads/upload_types.dart'
    show
        LeftOutReason,
        ReselectOutcome,
        UploadIntentMissing,
        UploadsUnavailable,
        isBatchForgotten;
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/services/uploads/uploads_visibility.dart';

/// A message for the user after Add files or a reselect.
@immutable
class UploadsNotice {
  const UploadsNotice(this.title, [this.lines = const []]);
  final String title;

  /// One line per file ("name: reason").
  final List<String> lines;
}

/// The child list of one unpacked ZIP.
sealed class ChildListState {
  const ChildListState();
}

class ChildListLoading extends ChildListState {
  const ChildListLoading();
}

class ChildListFailed extends ChildListState {
  const ChildListFailed();
}

/// The server no longer keeps the archive's record (its retention ended).
class ChildListGone extends ChildListState {
  const ChildListGone();

  /// What the page says instead of the list.
  String get text => archiveFileListGoneText;
}

class ChildListLoaded extends ChildListState {
  const ChildListLoaded(this.children);
  final ZipChildren children;
}

/// The Uploads page's input and presentation state (spec §7 para 3; SC-26).
/// Page-scoped: created when the page opens, disposed when it closes.
/// Transfers belong to the upload manager and outlive the page.
abstract interface class UploadsControls implements Listenable {
  /// What the page shows; null until the local uploads have loaded.
  UploadsOverview? get overview;

  /// The last Add files / reselect message, until dismissed.
  UploadsNotice? get notice;

  /// Add files is picking or hashing.
  bool get adding;

  /// The page is on screen and the app in the foreground (drives the
  /// manager's status polling).
  void setPageVisible(bool visible);

  /// Opens the file picker and adds the picked files.
  Future<void> addFiles();

  Future<void> cancel(String itemUuid);

  /// "Reselect file to retry": picks the file again for [itemUuid].
  Future<void> reselect(String itemUuid);

  /// Retries a failed item (the server re-checks it or takes its bytes again).
  Future<void> retry(String itemUuid);

  void dismissNotice();

  /// Null until [loadChildren] was called for [parentItemUuid].
  ChildListState? childrenOf(String parentItemUuid);

  /// [quiet]: a list already shown stays on screen while it is read again
  /// and when that read fails.
  Future<void> loadChildren(
    String batchUuid,
    String parentItemUuid, {
    bool quiet = false,
  });

  void dispose();
}

typedef UploadsControlsFactory = UploadsControls Function();

/// Creates the Uploads page's controller. Override in tests.
final uploadsControllerFactoryProvider = Provider<UploadsControlsFactory>(
  (ref) => () => UploadsController(ref),
);

class UploadsController extends ChangeNotifier implements UploadsControls {
  UploadsController(this._ref) {
    _overviewSub = _ref.listen<UploadsOverview?>(uploadsOverviewProvider, (
      _,
      next,
    ) {
      _overview = next;
      _notify();
    }, fireImmediately: true);
  }

  final Ref _ref;
  late final ProviderSubscription<UploadsOverview?> _overviewSub;
  UploadsOverview? _overview;
  UploadsNotice? _notice;
  bool _adding = false;
  bool _reselecting = false;
  /// The items whose Retry is in flight (one at a time per item).
  final _retrying = <String>{};
  bool _disposed = false;
  final _children = <String, ChildListState>{};
  final _childLoads = <String, int>{};

  void _fail(Object error) {
    // The type only: never the message, which can carry paths.
    debugPrint('Uploads action failed: ${error.runtimeType}');
    _notice = switch (error) {
      UploadsUnavailable() => const UploadsNotice(
        "Uploads aren't available right now",
      ),
      UploadIntentMissing() => const UploadsNotice(reviewItemNotHereText),
      _ => const UploadsNotice(uploadActionFailedText),
    };
  }

  @override
  UploadsOverview? get overview => _overview;
  @override
  UploadsNotice? get notice => _notice;
  @override
  bool get adding => _adding;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void setPageVisible(bool visible) =>
      _ref.read(uploadsVisibilityProvider).setVisible(visible);

  @override
  Future<void> addFiles() async {
    if (_adding || _overview?.canAddFiles != true) return;
    _adding = true;
    _notify();
    try {
      final selection = await _ref.read(uploadSourcePickerProvider).pick();
      if (selection.isEmpty) return;
      final unreadable = leftOutReasonText(LeftOutReason.unreadable);
      final lines = [for (final name in selection.unavailable) '$name: $unreadable'];
      if (selection.sources.isNotEmpty) {
        final result = await _ref
            .read(uploadManagerProvider)
            .addFiles(selection.sources);
        for (final f in result.leftOut) {
          lines.add('${f.displayName}: ${leftOutReasonText(f.reason)}');
        }
      }
      if (lines.isNotEmpty) {
        _notice = UploadsNotice(
          lines.length == 1
              ? '1 file was left out'
              : '${lines.length} files were left out',
          lines,
        );
      }
    } catch (e) {
      _fail(e);
    } finally {
      _adding = false;
      _notify();
    }
  }

  @override
  Future<void> cancel(String itemUuid) async {
    try {
      await _ref.read(uploadManagerProvider).cancel(itemUuid);
    } catch (e) {
      _fail(e);
      _notify();
    }
  }

  @override
  Future<void> reselect(String itemUuid) async {
    if (_reselecting) return;
    _reselecting = true;
    try {
      final selection = await _ref.read(uploadSourcePickerProvider).pick();
      if (_disposed || selection.isEmpty) return;
      final String? message;
      if (selection.sources.isEmpty) {
        message = reselectOutcomeText(ReselectOutcome.unreadable);
      } else {
        final outcome = await _ref
            .read(uploadManagerProvider)
            .reselect(itemUuid, selection.sources.first);
        message = reselectOutcomeText(outcome);
      }
      if (message == null) return;
      _notice = UploadsNotice(message);
      _notify();
    } catch (e) {
      _fail(e);
      _notify();
    } finally {
      _reselecting = false;
    }
  }

  @override
  Future<void> retry(String itemUuid) async {
    if (!_retrying.add(itemUuid)) return;
    try {
      final outcome = await _ref.read(uploadManagerProvider).retry(itemUuid);
      final message = retryOutcomeText(outcome);
      if (message != null) _notice = UploadsNotice(message);
    } catch (e) {
      _fail(e);
    } finally {
      _retrying.remove(itemUuid);
      _notify();
    }
  }

  @override
  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  @override
  ChildListState? childrenOf(String parentItemUuid) =>
      _children[parentItemUuid];

  @override
  Future<void> loadChildren(
    String batchUuid,
    String parentItemUuid, {
    bool quiet = false,
  }) async {
    final generation = (_childLoads[parentItemUuid] ?? 0) + 1;
    _childLoads[parentItemUuid] = generation;
    final shown = _children[parentItemUuid];
    final keep = quiet && shown is ChildListLoaded;
    if (!keep) {
      _children[parentItemUuid] = const ChildListLoading();
      _notify();
    }
    ChildListState result;
    try {
      result = ChildListLoaded(
        await _ref
            .read(uploadZipChildrenProvider)
            .load(batchUuid, parentItemUuid),
      );
    } catch (e) {
      // A list the server no longer keeps is gone, also on a quiet reload.
      result = isBatchForgotten(e)
          ? const ChildListGone()
          : (keep ? shown : const ChildListFailed());
    }
    // A newer request for this archive owns the answer.
    if (_disposed || _childLoads[parentItemUuid] != generation) return;
    _children[parentItemUuid] = result;
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _ref.read(uploadsVisibilityProvider).setVisible(false);
    _disposed = true;
    _overviewSub.close();
    super.dispose();
  }
}
