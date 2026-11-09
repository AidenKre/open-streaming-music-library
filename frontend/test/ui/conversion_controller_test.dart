// SC-26: ConversionControls turns conversion input into model calls and
// holds only presentation state: at most one flow per track at a time.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/conversion/conversion_service.dart';
import 'package:frontend/ui/conversion_controller.dart';

class _FakeService extends ConversionService {
  _FakeService(super.ref);
  final prepared = <String>[];
  final submitted = <ConvertTargetChoice>[];
  final cancelled = <int>[];
  ConversionPrep prep = const ConversionRefused('nope');
  Object? prepareError;

  @override
  Future<ConversionPrep> prepare(
    String uuidId, {
    String? presetCodec,
    int? presetBitrateKbps,
  }) async {
    prepared.add('$uuidId $presetCodec $presetBitrateKbps');
    final error = prepareError;
    prepareError = null;
    if (error != null) throw error;
    return prep;
  }

  @override
  Future<String?> submit(
    ConversionDraft draft,
    ConvertTargetChoice choice,
  ) async {
    submitted.add(choice);
    return 'submitted';
  }

  @override
  Future<String?> cancel(int jobId) async {
    cancelled.add(jobId);
    return 'cancelled';
  }
}

void main() {
  late ProviderContainer c;
  late _FakeService service;

  setUp(() {
    c = ProviderContainer(
      overrides: [
        conversionServiceProvider.overrideWith(
          (ref) => service = _FakeService(ref),
        ),
      ],
    );
    c.read(conversionServiceProvider);
  });
  tearDown(() => c.dispose());

  ConversionControls controls() => c.read(conversionControlsProvider);
  bool alive() => true;

  test('begin asks the model, passing the preset through', () async {
    final prep = await controls().begin(
      'u1',
      isAlive: alive,
      presetCodec: 'aac',
      presetBitrateKbps: 192,
    );
    expect(prep, same(service.prep));
    expect(service.prepared, ['u1 aac 192']);
  });

  test('a second flow for the same track while one runs is refused', () async {
    await controls().begin('u1', isAlive: alive);
    expect(await controls().begin('u1', isAlive: alive), isNull);
    expect(service.prepared, hasLength(1));
    // Another track is independent.
    expect(await controls().begin('u2', isAlive: alive), isNotNull);
  });

  test('end frees the track for the next flow', () async {
    await controls().begin('u1', isAlive: alive);
    controls().end('u1', isAlive: alive);
    expect(await controls().begin('u1', isAlive: alive), isNotNull);
  });

  test('a flow whose view is gone no longer blocks the track', () async {
    var viewAlive = true;
    await controls().begin('u1', isAlive: () => viewAlive);
    viewAlive = false;
    expect(await controls().begin('u1', isAlive: alive), isNotNull);
  });

  test('a stale end does not free a newer flow for the track', () async {
    var firstAlive = true;
    bool first() => firstAlive;
    await controls().begin('u1', isAlive: first);
    firstAlive = false;
    await controls().begin('u1', isAlive: alive); // the newer flow
    controls().end('u1', isAlive: first); // the old flow finally ends
    expect(
      await controls().begin('u1', isAlive: alive),
      isNull,
      reason: 'the newer flow is still running',
    );
    controls().end('u1', isAlive: alive);
    expect(await controls().begin('u1', isAlive: alive), isNotNull);
  });

  // Audit 5A.0(a) #8: a prepare that throws must not block the track.
  test('a failed prepare does not block the track', () async {
    service.prepareError = StateError('db locked');
    await expectLater(
      controls().begin('u1', isAlive: alive),
      throwsA(isA<StateError>()),
    );
    expect(await controls().begin('u1', isAlive: alive), isNotNull);
  });

  test('submit and cancel are the model\'s', () async {
    const draft = ConversionDraft(
      uuidId: 'u1',
      sourceCodec: 'flac',
      sourceBitrateKbps: 900,
      revision: 1,
      allowedTargets: [],
      bitratePresets: [],
    );
    const choice = ConvertTargetChoice(codec: 'aac', bitrateKbps: 192);
    expect(await controls().submit(draft, choice), 'submitted');
    expect(service.submitted, [choice]);
    expect(await controls().cancel(3), 'cancelled');
    expect(service.cancelled, [3]);
  });
}
