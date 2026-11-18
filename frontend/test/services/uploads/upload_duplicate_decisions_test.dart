// Phase 7B.2d S1: the duplicate decisions (model; the one place a per-item
// duplicate choice lives). Spec §4 commit: `acknowledged_duplicates` "lists
// **every** exact match in the item's stored report (not only the ones
// displayed) once the user chose 'Import as separate track' or 'Import
// both', and is empty otherwise." Spec §7 Duplicate UX: "Acknowledgements
// always cover the full list." Spec §4 retry: "invalidate old commit
// choices": a choice holds for the review version it was made at only.
// Fingerprint matches are advisory and never acknowledged. A match whose
// track is gone (`available: false`) is still an exact match of the report
// (never counted as absent), so it is acknowledged too.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';

import '../../helpers/duplicate_check_fixtures.dart';

void main() {
  /// Seven exact library matches (two gone), three fingerprint library
  /// matches, two exact staged matches and one fingerprint staged match.
  Map<String, dynamic> manyMatches() => duplicateCheckJson(matches: [
        for (var i = 7; i >= 1; i--)
          libraryMatchJson('t-$i', available: i > 2),
        for (var i = 1; i <= 3; i++)
          libraryMatchJson('fp-$i', kind: 'fingerprint', score: 0.9),
        stagedMatchJson('s-2'),
        stagedMatchJson('s-1'),
        stagedMatchJson('s-fp', kind: 'fingerprint', score: 0.8),
      ]);

  late UploadDuplicateDecisions decisions;
  setUp(() => decisions = UploadDuplicateDecisions());

  test('without a choice nothing is acknowledged, even with exact matches',
      () {
    final item = reviewItem('i-1', check: manyMatches());
    expect(decisions.chosenFor(item), isEmpty);
    expect(decisions.acknowledgementsFor(item).isEmpty, isTrue);
  });

  test('Import as separate track acknowledges every exact library match of '
      'the report (more than five, gone ones included), and nothing else',
      () {
    final item = reviewItem('i-1', check: manyMatches());
    decisions.choose(item, DuplicateGroup.library);

    final acks = decisions.acknowledgementsFor(item);
    expect(acks.libraryTracks, {for (var i = 1; i <= 7; i++) 't-$i'});
    expect(acks.stagedItems, isEmpty);
    expect(acks.toJson()['library_tracks'],
        [for (var i = 1; i <= 7; i++) 't-$i']);
    expect(decisions.chosenFor(item), {DuplicateGroup.library});
  });

  test('Import both acknowledges every exact staged match', () {
    final item = reviewItem('i-1', check: manyMatches());
    decisions.choose(item, DuplicateGroup.staged);

    final acks = decisions.acknowledgementsFor(item);
    expect(acks.libraryTracks, isEmpty);
    expect(acks.stagedItems, {'s-1', 's-2'});
  });

  test('both choices together acknowledge both lists', () {
    final item = reviewItem('i-1', check: manyMatches());
    decisions
      ..choose(item, DuplicateGroup.library)
      ..choose(item, DuplicateGroup.staged);

    final acks = decisions.acknowledgementsFor(item);
    expect(acks.libraryTracks, hasLength(7));
    expect(acks.stagedItems, {'s-1', 's-2'});
  });

  test('a choice holds for its review version only (retry invalidates old '
      'commit choices)', () {
    decisions.choose(
        reviewItem('i-1', version: 1, check: manyMatches()),
        DuplicateGroup.library);

    final newer = reviewItem('i-1', version: 2, check: manyMatches());
    expect(decisions.chosenFor(newer), isEmpty);
    expect(decisions.acknowledgementsFor(newer).isEmpty, isTrue);
  });

  test('the list is read from the report of the item being sent, not the '
      'one the choice was made on', () {
    decisions.choose(
        reviewItem('i-1', check: duplicateCheckJson(matches: [
          libraryMatchJson('t-old'),
        ])),
        DuplicateGroup.library);

    final sent = reviewItem('i-1', check: duplicateCheckJson(matches: [
      libraryMatchJson('t-a'),
      libraryMatchJson('t-b'),
    ]));
    expect(decisions.acknowledgementsFor(sent).libraryTracks, {'t-a', 't-b'});
  });

  test('a choice is per item', () {
    decisions.choose(reviewItem('i-1', check: manyMatches()),
        DuplicateGroup.library);
    final other = reviewItem('i-2', check: manyMatches());
    expect(decisions.chosenFor(other), isEmpty);
    expect(decisions.acknowledgementsFor(other).isEmpty, isTrue);
  });

  test('an item not checked yet (null report) or with an unreadable report '
      'acknowledges nothing', () {
    final unchecked = reviewItem('i-1');
    decisions.choose(unchecked, DuplicateGroup.library);
    expect(decisions.acknowledgementsFor(unchecked).isEmpty, isTrue);

    final unreadable = UploadItem.fromJson({
      ...reviewItem('i-2').toJson(),
      'duplicate_check': {'matches': 'not a list'},
    });
    decisions.choose(unreadable, DuplicateGroup.library);
    expect(decisions.acknowledgementsFor(unreadable).isEmpty, isTrue);
  });
}
