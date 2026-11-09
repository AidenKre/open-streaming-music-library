// Review major 1 (user, 2026-11-09): which codecs this device can decode.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/repositories/queue_repository.dart';

TrackUI _track({String? codec, String? filePath, String? downloadedCodec}) =>
    TrackUI(
      uuidId: 'a',
      createdAt: 0,
      lastUpdated: 0,
      duration: 1,
      bitrateKbps: null,
      sampleRateHz: null,
      channels: null,
      hasAlbumArt: false,
      codec: codec,
      filePath: filePath,
      downloadedCodec: downloadedCodec,
    );

QueuePlaybackEntry _entry(
        {String? filePath, String? downloadedCodec, String? sourceCodec}) =>
    QueuePlaybackEntry(
      itemId: 1,
      queueType: 'main',
      canonicalPosition: 0,
      playPosition: 0,
      uuidId: 'a',
      filePath: filePath,
      downloadedCodec: downloadedCodec,
      sourceCodec: sourceCodec,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioCodecFamily.of', () {
    test('maps the server codec names; wav and every pcm_* are WAV', () {
      expect(AudioCodecFamily.of('flac'), AudioCodecFamily.flac);
      expect(AudioCodecFamily.of(' ALAC '), AudioCodecFamily.alac);
      expect(AudioCodecFamily.of('pcm_s24le'), AudioCodecFamily.pcm);
      expect(AudioCodecFamily.of('wav'), AudioCodecFamily.pcm);
    });

    test('unknown or other codecs have no family', () {
      expect(AudioCodecFamily.of(null), isNull);
      expect(AudioCodecFamily.of(''), isNull);
      expect(AudioCodecFamily.of('opus'), isNull);
    });
  });

  group('CodecSupport', () {
    const androidWithoutAlac = CodecSupport({
      AudioCodecFamily.mp3,
      AudioCodecFamily.aac,
      AudioCodecFamily.flac,
      AudioCodecFamily.pcm,
    });

    test('a listed family decodes, a missing one does not', () {
      expect(androidWithoutAlac.canDecode('flac'), isTrue);
      expect(androidWithoutAlac.canDecode('alac'), isFalse);
      expect(androidWithoutAlac.unsupportedLabel('alac'), 'ALAC');
      expect(androidWithoutAlac.unsupportedLabel('flac'), isNull);
    });

    test('unknown is not unsupported', () {
      expect(androidWithoutAlac.canDecode(null), isTrue);
      expect(androidWithoutAlac.canDecode('opus'), isTrue);
      expect(const CodecSupport.unknown().canDecode('alac'), isTrue);
    });

    test('no engine decodes nothing', () {
      const none = CodecSupport.noEngine();
      expect(none.hasEngine, isFalse);
      expect(none.canDecode('mp3'), isFalse);
      expect(none.canDecode('opus'), isFalse);
    });

    test('a track names its download codec when downloaded, its source '
        'codec when it streams', () {
      expect(
          androidWithoutAlac.unsupportedCodecOf(_track(
              codec: 'alac', filePath: '/a', downloadedCodec: 'aac')),
          isNull,
          reason: 'a transcoded download plays');
      expect(
          androidWithoutAlac.unsupportedCodecOf(_track(
              codec: 'alac', filePath: '/a', downloadedCodec: 'alac')),
          'ALAC');
      expect(androidWithoutAlac.unsupportedCodecOf(_track(codec: 'alac')),
          'ALAC');
      expect(
          androidWithoutAlac.playsDownload(_track(
              codec: 'alac', filePath: '/a', downloadedCodec: 'alac')),
          isFalse);
      expect(
          androidWithoutAlac.playsDownload(_track(
              codec: 'alac', filePath: '/a', downloadedCodec: 'aac')),
          isTrue);
    });
  });

  group('CodecSupport.probe', () {
    late List<MethodCall> calls;
    Object? Function(MethodCall call)? answer;

    setUp(() {
      calls = [];
      answer = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CodecSupport.channel, (call) async {
        calls.add(call);
        return answer?.call(call);
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CodecSupport.channel, null);
    });

    test('Android asks the platform which codecs decode', () async {
      answer = (_) => ['pcm', 'mp3', 'aac', 'flac', 'something-new'];
      final support =
          await CodecSupport.probe(isWeb: false, platform: TargetPlatform.android);
      expect(calls.single.method, 'decodableAudioCodecs');
      expect(
          support,
          const CodecSupport({
            AudioCodecFamily.pcm,
            AudioCodecFamily.mp3,
            AudioCodecFamily.aac,
            AudioCodecFamily.flac,
          }));
      expect(support.canDecode('alac'), isFalse);
    });

    test('a failed Android question is unknown, never "nothing plays"',
        () async {
      answer = (_) => throw PlatformException(code: 'boom');
      expect(
          await CodecSupport.probe(
              isWeb: false, platform: TargetPlatform.android),
          const CodecSupport.unknown());
    });

    test('Apple decodes all five; Windows and Linux have no engine; web is '
        'unknown', () async {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        expect(await CodecSupport.probe(isWeb: false, platform: platform),
            CodecSupport.all);
      }
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        expect(await CodecSupport.probe(isWeb: false, platform: platform),
            const CodecSupport.noEngine());
      }
      expect(await CodecSupport.probe(isWeb: true),
          const CodecSupport.unknown());
      expect(calls, isEmpty);
    });
  });

  group('LocalSourcePolicy with codecs', () {
    final policy = LocalSourcePolicy(
        codecs: const CodecSupport({
      AudioCodecFamily.mp3,
      AudioCodecFamily.aac,
      AudioCodecFamily.pcm,
    }));

    test('a download this device cannot decode is not played from its file',
        () {
      expect(policy.localPathFor(_entry(filePath: '/a', downloadedCodec: 'flac')),
          isNull);
      expect(policy.localPathFor(_entry(filePath: '/a', downloadedCodec: 'aac')),
          '/a');
      expect(policy.localPathFor(_entry(filePath: '/a')), '/a',
          reason: 'an unknown codec is not unsupported');
    });

    test('an "original" stream of such a codec streams transcoded', () {
      final flac = _entry(sourceCodec: 'flac');
      expect(policy.streamQualityFor(flac, 'original'), '320');
      expect(policy.streamsTranscoded(flac, 'original'), isTrue);
      expect(policy.streamQualityFor(flac, '128'), '128',
          reason: 'a chosen preset is already transcoded');
      expect(policy.streamQualityFor(_entry(sourceCodec: 'mp3'), 'original'),
          'original');
      expect(policy.streamQualityFor(_entry(), 'original'), 'original');
    });

    test('without an engine nothing is substituted', () {
      final none = LocalSourcePolicy(codecs: const CodecSupport.noEngine());
      expect(none.streamQualityFor(_entry(sourceCodec: 'flac'), 'original'),
          'original');
      expect(none.localPathFor(_entry(filePath: '/a', downloadedCodec: 'mp3')),
          isNull);
    });
  });
}
