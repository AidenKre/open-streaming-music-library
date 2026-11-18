import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

TrackUI _track(String uuid, {int? revision}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  revision: revision,
  title: uuid,
  duration: 60,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

/// SC-17 controller: the input seam over the `TrackSelection` model.
void main() {
  late ProviderContainer container;
  late TrackSelectionControls controls;
  late int notified;

  setUp(() {
    container = ProviderContainer();
    controls = container.read(trackSelectionControllerFactoryProvider)();
    notified = 0;
    controls.addListener(() => notified++);
  });

  tearDown(() {
    controls.dispose();
    container.dispose();
  });

  List<(String, int?)> pairs() => [
    for (final e in controls.selection.entries) (e.uuid, e.baseRevision),
  ];

  test('the factory makes a fresh, empty selection each time', () {
    final other = container.read(trackSelectionControllerFactoryProvider)();
    addTearDown(other.dispose);
    controls.toggle(_track('a', revision: 1));
    expect(controls.count, 1);
    expect(other.count, 0);
    expect(other.selection.isEmpty, isTrue);
  });

  test('toggle selects with the row revision, in order, and notifies', () {
    controls.toggle(_track('b', revision: 4));
    controls.toggle(_track('a', revision: 9));
    expect(pairs(), [('b', 4), ('a', 9)]);
    expect(controls.count, 2);
    expect(controls.isSelected('a'), isTrue);
    expect(controls.isSelected('c'), isFalse);
    expect(notified, 2);
  });

  // 8-R1-19: select by uuid and revision (a row that is not a TrackUI).
  test('select adds the uuid with its revision, in order, and notifies', () {
    controls.select('b', baseRevision: 4);
    controls.select('a', baseRevision: null);
    expect(pairs(), [('b', 4), ('a', null)]);
    expect(notified, 2);
  });

  test('select of an already selected uuid changes nothing', () {
    controls.select('a', baseRevision: 4);
    notified = 0;
    controls.select('a', baseRevision: 9);
    expect(pairs(), [('a', 4)]);
    expect(notified, 0);
  });

  test('toggle again deselects and notifies', () {
    controls.toggle(_track('a', revision: 1));
    controls.toggle(_track('a', revision: 2));
    expect(controls.count, 0);
    expect(controls.isSelected('a'), isFalse);
    expect(notified, 2);
  });

  test('a row with an unknown revision is selected as unknown, not 0', () {
    controls.toggle(_track('a'));
    expect(pairs(), [('a', null)]);
  });

  test('clear empties the selection and notifies once', () {
    controls.toggle(_track('a', revision: 1));
    controls.toggle(_track('b', revision: 1));
    notified = 0;
    controls.clear();
    expect(controls.count, 0);
    expect(controls.selection.isEmpty, isTrue);
    expect(controls.isSelected('a'), isFalse);
    expect(notified, 1);
  });

  test('clearing an empty selection does not notify', () {
    controls.clear();
    expect(notified, 0);
  });

  test('input after dispose is ignored', () {
    final c = container.read(trackSelectionControllerFactoryProvider)();
    c.dispose();
    c.toggle(_track('a', revision: 1));
    c.clear();
    expect(c.count, 0);
  });

  group('8B.1c: deselect and refreshRevision', () {
    test('deselect removes an entry by uuid alone and notifies', () {
      controls.toggle(_track('a', revision: 1));
      controls.toggle(_track('b', revision: 2));
      notified = 0;
      controls.deselect('a');
      expect(pairs(), [('b', 2)]);
      expect(notified, 1);
    });

    test('deselect of an unselected uuid does not notify', () {
      controls.toggle(_track('a', revision: 1));
      notified = 0;
      controls.deselect('zz');
      expect(pairs(), [('a', 1)]);
      expect(notified, 0);
    });

    test('refreshRevision replaces the revision in place and notifies', () {
      controls.toggle(_track('a', revision: 1));
      controls.toggle(_track('b'));
      notified = 0;
      controls.refreshRevision('b', 8);
      expect(pairs(), [('a', 1), ('b', 8)]);
      expect(notified, 1);
    });

    test('refreshRevision of an unselected uuid selects nothing', () {
      controls.toggle(_track('a', revision: 1));
      notified = 0;
      controls.refreshRevision('zz', 8);
      expect(pairs(), [('a', 1)]);
      expect(notified, 0);
    });

    test('input after dispose is ignored', () {
      final c = container.read(trackSelectionControllerFactoryProvider)();
      c.toggle(_track('a', revision: 1));
      c.dispose();
      c.deselect('a');
      c.refreshRevision('a', 5);
      expect([for (final e in c.selection.entries) (e.uuid, e.baseRevision)],
          [('a', 1)]);
    });
  });
}
