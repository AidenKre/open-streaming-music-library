// Phase 9D.2d (SC-03, spec §7.2): the `integrations` feature block,
// `integrations: {version: 1, lastfm: {available: bool}}` as 9D.2a's
// `/app/info` sends it. `available` is a server-level fact ("enabled and
// validly configured"), never per-user state.
//  * an invalid `version` makes the whole block absent (unsupported);
//  * a missing or malformed `lastfm` entry (or `available` that is not a
//    bool: unknown is never read as false) leaves the block present without
//    Last.fm, so a later integration in the same block is not lost;
//  * only this feature is affected, never another block;
//  * the block round-trips through the prefs cache.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/feature_blocks.dart';

void main() {
  test('the 9D.2a block parses: available true', () {
    final f = FeatureBlocks.fromJson({
      'integrations': {
        'version': 1,
        'lastfm': {'available': true},
      },
    });
    final i = f.integrations!;
    expect(i.version, 1);
    expect(i.lastfm!.available, isTrue);
  });

  test('switched off or misconfigured: present, available false', () {
    final i = FeatureBlocks.fromJson({
      'integrations': {
        'version': 1,
        'lastfm': {'available': false},
      },
    }).integrations!;
    expect(i.lastfm!.available, isFalse);
  });

  test('unknown fields are tolerated; a later version is kept', () {
    final i = FeatureBlocks.fromJson({
      'integrations': {
        'version': 2,
        'lastfm': {'available': true, 'extra': 'x'},
        'listenbrainz': {'available': true},
      },
    }).integrations!;
    expect(i.version, 2);
    expect(i.lastfm!.available, isTrue);
  });

  test('an invalid version: no integrations block, other blocks survive', () {
    for (final block in <Object?>[
      null,
      true,
      1,
      'integrations',
      <String, Object?>{},
      {'lastfm': {'available': true}}, // no version
      {'version': '1', 'lastfm': {'available': true}},
      {'version': 0, 'lastfm': {'available': true}},
      {'version': 1.0, 'lastfm': {'available': true}},
    ]) {
      final f = FeatureBlocks.fromJson({
        'history': {'version': 1},
        'integrations': block,
      });
      expect(f.integrations, isNull, reason: '$block');
      expect(f.history, isNotNull, reason: 'history survives $block');
    }
  });

  test('a missing or malformed lastfm entry: block present, no Last.fm', () {
    for (final lastfm in <Object?>[
      null,
      true,
      'yes',
      <String, Object?>{},
      {'available': 'true'},
      {'available': 1},
      {'available': null},
    ]) {
      final f = FeatureBlocks.fromJson({
        'integrations': {'version': 1, 'lastfm': lastfm},
      });
      expect(f.integrations, isNotNull, reason: '$lastfm');
      expect(f.integrations!.lastfm, isNull, reason: '$lastfm');
    }
    final noKey = FeatureBlocks.fromJson({
      'integrations': {'version': 1},
    });
    expect(noKey.integrations!.lastfm, isNull);
  });

  test('toJson round-trips through the cache', () {
    for (final available in [true, false]) {
      final info = AppInfo.fromJson({
        'integrations': {
          'version': 1,
          'lastfm': {'available': available},
        },
      });
      final back = AppInfo.fromJson(info.toJson()).features.integrations!;
      expect(back.version, 1);
      expect(back.lastfm!.available, available);
    }
    final withoutLastfm = AppInfo.fromJson({
      'integrations': {'version': 1},
    });
    final back = AppInfo.fromJson(withoutLastfm.toJson()).features;
    expect(back.integrations, isNotNull);
    expect(back.integrations!.lastfm, isNull);
  });

  test('no integrations block: absent, and not written to the cache', () {
    final info = AppInfo.fromJson({'history': {'version': 1}});
    expect(info.features.integrations, isNull);
    expect(info.toJson().containsKey('integrations'), isFalse);
  });
}
