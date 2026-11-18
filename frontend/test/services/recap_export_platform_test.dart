// Phase 9 §6 (9C.2): the native recap export platform maps the save panel
// (`file_selector`) and the share sheet (`share_plus`, decision O5) onto
// RecapExportPlatform. The plugin calls are injected; nothing native runs.
// "Record unavailable share targets as platform limitations" (9-Y03).
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/recap_export_platform.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  group('capabilities', () {
    // (platform, web, canSave, canShare, confirmsReplace)
    for (final (target, web, save, share, replace) in [
      (TargetPlatform.macOS, false, true, true, true),
      (TargetPlatform.windows, false, true, true, true),
      // Review r1 F1: GTK's save panel (file_selector_linux) does not ask
      // before replacing a file, so Linux never counts as confirming.
      (TargetPlatform.linux, false, true, false, false),
      (TargetPlatform.iOS, false, false, true, false),
      (TargetPlatform.android, false, false, true, false),
      (TargetPlatform.macOS, true, false, false, false),
    ]) {
      test('${target.name}${web ? ' (web)' : ''}', () {
        final platform = NativeRecapExportPlatform(
          platform: target,
          isWeb: web,
        );
        expect(platform.canSave, save);
        expect(platform.canShare, share);
        expect(platform.confirmsReplace, replace);
      });
    }
  });

  group('save panel', () {
    late List<(String?, List<fs.XTypeGroup>)> calls;
    fs.FileSaveLocation? answer;

    NativeRecapExportPlatform native() => NativeRecapExportPlatform(
      platform: TargetPlatform.macOS,
      isWeb: false,
      getSaveLocation: ({suggestedName, acceptedTypeGroups = const []}) async {
        calls.add((suggestedName, acceptedTypeGroups));
        return answer;
      },
    );

    setUp(() {
      calls = [];
      answer = null;
    });

    test('offers the suggested name with a PNG type group and returns the '
        'chosen path', () async {
      answer = const fs.FileSaveLocation('/chosen/recap.png');

      final path = await native().chooseSaveLocation(
        suggestedName: 'osml-year-in-music-2025.png',
        type: RecapExportType.png,
      );

      expect(path, '/chosen/recap.png');
      final (name, groups) = calls.single;
      expect(name, 'osml-year-in-music-2025.png');
      expect(groups.single.extensions, ['png']);
      expect(groups.single.mimeTypes, ['image/png']);
      expect(groups.single.uniformTypeIdentifiers, ['public.png']);
    });

    test('a JSON export offers a JSON type group', () async {
      answer = const fs.FileSaveLocation('/chosen/recap.json');

      await native().chooseSaveLocation(
        suggestedName: 'osml-year-in-music-2025.json',
        type: RecapExportType.json,
      );

      final group = calls.single.$2.single;
      expect(group.extensions, ['json']);
      expect(group.mimeTypes, ['application/json']);
      expect(group.uniformTypeIdentifiers, ['public.json']);
    });

    test('a cancelled panel answers null', () async {
      expect(
        await native().chooseSaveLocation(
          suggestedName: 'x.png',
          type: RecapExportType.png,
        ),
        isNull,
      );
    });
  });

  group('share sheet', () {
    late List<ShareParams> calls;
    late ShareResultStatus status;

    NativeRecapExportPlatform native() => NativeRecapExportPlatform(
      platform: TargetPlatform.macOS,
      isWeb: false,
      share: (params) async {
        calls.add(params);
        return ShareResult('raw', status);
      },
    );

    setUp(() {
      calls = [];
      status = ShareResultStatus.success;
    });

    test('shares exactly the one file, typed, from the given origin, with '
        'no text, subject or link', () async {
      const origin = Rect.fromLTWH(1, 2, 3, 4);

      await native().share(
        path: '/tmp/x/osml-year-in-music-2025.png',
        type: RecapExportType.png,
        origin: origin,
      );

      final params = calls.single;
      expect(params.files!.single.path, '/tmp/x/osml-year-in-music-2025.png');
      expect(params.files!.single.mimeType, 'image/png');
      expect(params.sharePositionOrigin, origin);
      expect(params.text, isNull);
      expect(params.subject, isNull);
      expect(params.uri, isNull);
    });

    for (final (from, to) in [
      (ShareResultStatus.success, RecapShareStatus.shared),
      (ShareResultStatus.dismissed, RecapShareStatus.dismissed),
      (ShareResultStatus.unavailable, RecapShareStatus.unknown),
    ]) {
      test('${from.name} → ${to.name}', () async {
        status = from;
        expect(
          await native().share(path: '/p.png', type: RecapExportType.png),
          to,
        );
      });
    }
  });

  test('on Linux the temporary directory is the per-user cache, not the '
      'shared /tmp (review r1 F2)', () async {
    final tmp = Directory('/shared/tmp');
    final cache = Directory('/home/me/.cache/app');
    NativeRecapExportPlatform on(TargetPlatform target) =>
        NativeRecapExportPlatform(
          platform: target,
          isWeb: false,
          temporaryDirectory: () async => tmp,
          applicationCacheDirectory: () async => cache,
        );

    expect(await on(TargetPlatform.linux).temporaryDirectory(), cache);
    expect(await on(TargetPlatform.macOS).temporaryDirectory(), tmp);
    expect(await on(TargetPlatform.windows).temporaryDirectory(), tmp);
  });

  test('the temporary directory comes from the injected source', () async {
    final dir = Directory.systemTemp;
    final native = NativeRecapExportPlatform(
      platform: TargetPlatform.macOS,
      isWeb: false,
      temporaryDirectory: () async => dir,
    );
    expect(await native.temporaryDirectory(), dir);
  });
}
