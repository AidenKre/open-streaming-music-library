import 'package:flutter/foundation.dart';

/// Owns the change-counter that the UI watches to invalidate derived "is this
/// downloaded?" providers.
///
/// Extracted from DownloadManager so the read-side concerns sit alone — the
/// downloader and worker pool only need to call [bumpVersion] when something
/// changes.
class DownloadStatusReader {
  bool _disposed = false;

  /// Notified once when the underlying tracks table changes such that
  /// downloaded-status checks may have new answers. Lets the UI invalidate
  /// derived providers without polling the DB.
  final ValueNotifier<int> downloadStatusVersion = ValueNotifier<int>(0);

  void bumpVersion() {
    if (_disposed) return;
    downloadStatusVersion.value += 1;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    downloadStatusVersion.dispose();
  }
}
