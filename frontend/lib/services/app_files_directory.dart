import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The folder function for the downloads (`tracks/`) and stored covers
/// (`cover_art/`) on [platform]. On Linux and Windows the documents folder
/// is the person's own Documents folder, which a reset empties, so there it
/// is the app's support folder (where the database is).
Future<Directory> Function() appFilesDirectoryFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.linux ||
      TargetPlatform.windows => getApplicationSupportDirectory,
      TargetPlatform.macOS ||
      TargetPlatform.iOS ||
      TargetPlatform.android ||
      TargetPlatform.fuchsia => getApplicationDocumentsDirectory,
    };

/// The app's files folder on this device (see [appFilesDirectoryFor]).
Future<Directory> appFilesDirectory() =>
    appFilesDirectoryFor(defaultTargetPlatform)();
