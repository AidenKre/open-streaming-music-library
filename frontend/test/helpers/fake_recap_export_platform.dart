import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:frontend/services/recap_export_platform.dart';

/// A fake save panel and share sheet over a real temporary directory the
/// test owns. Only the platform is faked: the service's file handling runs
/// for real.
class FakeRecapExportPlatform implements RecapExportPlatform {
  FakeRecapExportPlatform(
    this.tempRoot, {
    this.canSave = true,
    this.canShare = true,
    this.confirmsReplace = true,
  });

  final Directory tempRoot;

  @override
  bool canSave;

  @override
  bool canShare;

  @override
  bool confirmsReplace;

  /// What the next save panel answers: a path, or null for Cancel.
  String? Function()? nextSaveLocation;

  /// Runs while the save panel is open (before it answers).
  Future<void> Function()? whilePanelOpen;

  /// Makes the save panel throw.
  Object? panelError;

  /// What the share sheet answers.
  RecapShareStatus shareStatus = RecapShareStatus.shared;

  /// Makes the share sheet throw.
  Object? shareError;

  /// Runs while the share sheet is open (before it answers).
  Future<void> Function()? whileShareOpen;

  /// Every save panel shown: (suggested name, type).
  final saveRequests = <(String, RecapExportType)>[];

  /// Every share sheet shown: (path, type, origin, the file's bytes then).
  final shareRequests = <(String, RecapExportType, Rect?, List<int>?)>[];

  /// The temporary files that existed while each panel or sheet was open.
  final filesWhileOpen = <List<String>>[];

  int temporaryDirectoryCalls = 0;

  /// Runs while the temporary directory is being asked for.
  Future<void> Function()? whileTemporaryDirectoryRequested;

  @override
  Future<Directory> temporaryDirectory() async {
    temporaryDirectoryCalls++;
    await whileTemporaryDirectoryRequested?.call();
    return tempRoot;
  }

  List<String> _tempFiles() => [
    if (tempRoot.existsSync())
      for (final f in tempRoot.listSync(recursive: true))
        if (f is File) f.path,
  ];

  @override
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required RecapExportType type,
  }) async {
    saveRequests.add((suggestedName, type));
    filesWhileOpen.add(_tempFiles());
    await whilePanelOpen?.call();
    final error = panelError;
    if (error != null) throw error;
    return nextSaveLocation?.call();
  }

  @override
  Future<RecapShareStatus> share({
    required String path,
    required RecapExportType type,
    Rect? origin,
  }) async {
    final file = File(path);
    shareRequests.add((
      path,
      type,
      origin,
      file.existsSync() ? file.readAsBytesSync() : null,
    ));
    filesWhileOpen.add(_tempFiles());
    await whileShareOpen?.call();
    final error = shareError;
    if (error != null) throw error;
    return shareStatus;
  }
}
