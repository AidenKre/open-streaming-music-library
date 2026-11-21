// 8B.1c S3: when Manage library may offer server deletion (spec §3
// "The client shows Manage library's server-delete action ... only when
// `server_delete` is true"; O6 "Server deletion is turned off on this
// server" differs from "this server doesn't offer library tools"; a cached
// block never enables a network action), and the typed-count rule (spec §4
// para 3 "For N>1, type the displayed track count").
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/services/feature_providers.dart';

AdvertisedFeature<LibraryToolsFeature> _adv({
  required bool serverDelete,
  bool fromCache = false,
}) => AdvertisedFeature(
  LibraryToolsFeature(
    version: 1,
    serverDelete: serverDelete,
    duplicateReview: false,
  ),
  fromCache: fromCache,
);

ServerDeleteAvailability _of({
  bool loading = false,
  AdvertisedFeature<LibraryToolsFeature>? advertised,
  bool offline = false,
}) => serverDeleteAvailability(
  loading: loading,
  advertised: advertised,
  offline: offline,
);

void main() {
  group('serverDeleteAvailability', () {
    test('while the server info loads: checking (never "off")', () {
      expect(_of(loading: true), ServerDeleteAvailability.checking);
    });

    test('no block: the server does not offer library tools', () {
      expect(_of(), ServerDeleteAvailability.notOffered);
      expect(_of(offline: true), ServerDeleteAvailability.notOffered);
    });

    test('server_delete false: turned off, live or cached', () {
      expect(
        _of(advertised: _adv(serverDelete: false)),
        ServerDeleteAvailability.switchedOff,
      );
      expect(
        _of(advertised: _adv(serverDelete: false, fromCache: true)),
        ServerDeleteAvailability.switchedOff,
      );
    });

    test('server_delete true from a live answer and online: enabled', () {
      expect(
        _of(advertised: _adv(serverDelete: true)),
        ServerDeleteAvailability.enabled,
      );
    });

    test('server_delete true but only cached, or offline: unreachable', () {
      expect(
        _of(advertised: _adv(serverDelete: true, fromCache: true)),
        ServerDeleteAvailability.unreachable,
      );
      expect(
        _of(advertised: _adv(serverDelete: true), offline: true),
        ServerDeleteAvailability.unreachable,
      );
    });
  });

  group('typedCountMatches', () {
    test('only the displayed count, as digits, matches', () {
      expect(typedCountMatches('3', 3), isTrue);
      expect(typedCountMatches(' 3 ', 3), isTrue);
      expect(typedCountMatches('12', 12), isTrue);
    });

    test('anything else does not', () {
      for (final typed in ['', '2', '4', '03', '3.0', 'three', '+3', '33']) {
        expect(typedCountMatches(typed, 3), isFalse, reason: typed);
      }
    });
  });

  // The one adapter both deletion pages read the server's block through.
  group('from the block as its provider holds it', () {
    test('still loading: checking', () {
      expect(serverDeleteAvailabilityOf(const AsyncLoading(), offline: false),
          ServerDeleteAvailability.checking);
    });
    test('a failed read with no value: unknown, not "not offered"', () {
      expect(
          serverDeleteAvailabilityOf(
              AsyncError(StateError('x'), StackTrace.empty),
              offline: false),
          ServerDeleteAvailability.unreachable);
    });
    test('no block: not offered', () {
      expect(serverDeleteAvailabilityOf(const AsyncData(null), offline: false),
          ServerDeleteAvailability.notOffered);
    });
    test('a live block, online: enabled; offline: unreachable', () {
      final live = AsyncData(_adv(serverDelete: true));
      expect(serverDeleteAvailabilityOf(live, offline: false),
          ServerDeleteAvailability.enabled);
      expect(serverDeleteAvailabilityOf(live, offline: true),
          ServerDeleteAvailability.unreachable);
    });
  });
}
