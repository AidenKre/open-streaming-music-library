// U34-B-09: the Android side of the codec probe (MainActivity.kt) is plain
// text to Dart, so a renamed channel, method or codec key there would only
// show on a device as "codecs unknown". This reads the Kotlin file and holds
// it to what CodecSupport.probe sends and understands.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/playback/codec_support.dart';

const _mainActivity =
    'android/app/src/main/kotlin/com/example/frontend/MainActivity.kt';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final kotlin = File(_mainActivity).readAsStringSync();

  test("the Kotlin channel is CodecSupport's channel", () {
    final names = RegExp(r'MethodChannel\([^,]+,\s*"([^"]+)"\)')
        .allMatches(kotlin)
        .map((m) => m.group(1))
        .toList();
    expect(names, [CodecSupport.channel.name]);
  });

  test('the Kotlin handler answers the method the probe calls', () async {
    final asked = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(CodecSupport.channel, (call) async {
      asked.add(call.method);
      return <String>[];
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(CodecSupport.channel, null));
    await CodecSupport.probe(isWeb: false, platform: TargetPlatform.android);
    final handled = RegExp(r'call\.method == "([^"]+)"')
        .allMatches(kotlin)
        .map((m) => m.group(1))
        .toList();
    expect(asked, isNotEmpty);
    expect(handled, asked.toSet().toList());
  });

  test('every codec key the Kotlin side can answer is an AudioCodecFamily name',
      () {
    final keys = [
      ...RegExp(r'mutableListOf\(([^)]*)\)')
          .allMatches(kotlin)
          .expand((m) => RegExp(r'"([^"]+)"').allMatches(m.group(1)!))
          .map((m) => m.group(1)!),
      ...RegExp(r'"([^"]+)" to "audio/')
          .allMatches(kotlin)
          .map((m) => m.group(1)!),
    ];
    expect(keys, isNotEmpty);
    final families = {for (final f in AudioCodecFamily.values) f.name};
    expect([for (final k in keys) if (!families.contains(k)) k], isEmpty,
        reason: 'keys: $keys');
    for (final k in keys) {
      expect(AudioCodecFamily.of(k)?.name, k, reason: k);
    }
  });
}
