/// Phase 9 §6: the platform side of saving and sharing a recap export. This
/// interface is the one seam tests fake (plan 9C.2). Model code: nothing
/// from `ui/`.
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart' as pp;
import 'package:share_plus/share_plus.dart';

/// The kinds of file a recap exports.
enum RecapExportType {
  png('png', 'image/png', 'PNG image', 'public.png'),
  json('json', 'application/json', 'JSON', 'public.json');

  const RecapExportType(this.extension, this.mimeType, this.label, this.uti);

  final String extension;
  final String mimeType;
  final String label;

  /// The Apple uniform type identifier.
  final String uti;
}

/// What the OS share sheet reported.
enum RecapShareStatus {
  /// The user chose a share target.
  shared,

  /// The user closed the sheet without choosing one.
  dismissed,

  /// The sheet was shown but the platform cannot tell what the user did.
  unknown,
}

/// The platform's save panel, share sheet and temporary directory.
abstract interface class RecapExportPlatform {
  /// The platform has a save panel.
  bool get canSave;

  /// The platform's share sheet can share a file.
  bool get canShare;

  /// The save panel itself asks the user before replacing an existing file.
  bool get confirmsReplace;

  /// The directory temporary export files are written under.
  Future<Directory> temporaryDirectory();

  /// Shows the save panel; the chosen path, or null when cancelled.
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required RecapExportType type,
  });

  /// Opens the share sheet for the file at [path]. [origin] is where the
  /// sheet points from (global coordinates), where the platform needs one.
  Future<RecapShareStatus> share({
    required String path,
    required RecapExportType type,
    Rect? origin,
  });
}

/// The platform's save panel (`file_selector`) and share sheet
/// (`share_plus`). The plugin calls are injectable for tests.
class NativeRecapExportPlatform implements RecapExportPlatform {
  NativeRecapExportPlatform({
    TargetPlatform? platform,
    bool? isWeb,
    Future<fs.FileSaveLocation?> Function({
      String? suggestedName,
      List<fs.XTypeGroup> acceptedTypeGroups,
    })?
    getSaveLocation,
    Future<ShareResult> Function(ShareParams params)? share,
    Future<Directory> Function()? temporaryDirectory,
    Future<Directory> Function()? applicationCacheDirectory,
  }) : _target = platform ?? defaultTargetPlatform,
       _isWeb = isWeb ?? kIsWeb,
       _getSaveLocation = getSaveLocation ?? fs.getSaveLocation,
       _share = share ?? SharePlus.instance.share,
       _temporaryDirectory = temporaryDirectory ?? pp.getTemporaryDirectory,
       _applicationCacheDirectory =
           applicationCacheDirectory ?? pp.getApplicationCacheDirectory;

  final TargetPlatform _target;
  final bool _isWeb;
  final Future<fs.FileSaveLocation?> Function({
    String? suggestedName,
    List<fs.XTypeGroup> acceptedTypeGroups,
  })
  _getSaveLocation;
  final Future<ShareResult> Function(ShareParams params) _share;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Directory> Function() _applicationCacheDirectory;

  @override
  bool get canSave =>
      !_isWeb &&
      (_target == TargetPlatform.macOS ||
          _target == TargetPlatform.windows ||
          _target == TargetPlatform.linux);

  // share_plus cannot share files on Linux.
  @override
  bool get canShare =>
      !_isWeb &&
      (_target == TargetPlatform.macOS ||
          _target == TargetPlatform.windows ||
          _target == TargetPlatform.iOS ||
          _target == TargetPlatform.android);

  // The macOS and Windows save panels ask before replacing a file; GTK's
  // (file_selector_linux) does not.
  @override
  bool get confirmsReplace =>
      !_isWeb &&
      (_target == TargetPlatform.macOS || _target == TargetPlatform.windows);

  // On Linux the shared /tmp is world-writable; use the per-user cache.
  @override
  Future<Directory> temporaryDirectory() => _target == TargetPlatform.linux
      ? _applicationCacheDirectory()
      : _temporaryDirectory();

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required RecapExportType type,
  }) async {
    final location = await _getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        fs.XTypeGroup(
          label: type.label,
          extensions: [type.extension],
          mimeTypes: [type.mimeType],
          uniformTypeIdentifiers: [type.uti],
        ),
      ],
    );
    return location?.path;
  }

  @override
  Future<RecapShareStatus> share({
    required String path,
    required RecapExportType type,
    Rect? origin,
  }) async {
    final result = await _share(
      ShareParams(
        files: [XFile(path, mimeType: type.mimeType)],
        sharePositionOrigin: origin,
      ),
    );
    return switch (result.status) {
      ShareResultStatus.success => RecapShareStatus.shared,
      ShareResultStatus.dismissed => RecapShareStatus.dismissed,
      // share_plus: shown, outcome unknown.
      ShareResultStatus.unavailable => RecapShareStatus.unknown,
    };
  }
}

final recapExportPlatformProvider = Provider<RecapExportPlatform>(
  (ref) => NativeRecapExportPlatform(),
);
