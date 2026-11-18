// Phase 9D.2e S1: the links the Integrations page opens and the system
// browser adapter (plan O5).
//  * Spec §7.12: "The text 'Scrobbling powered by Last.fm' links to
//    https://www.last.fm/. The connected account's name links to
//    https://www.last.fm/user/<name>, built by the client with the name
//    percent-encoded. Links open in the system browser on a tap."
//  * Spec §7.5 point 2: "Last.fm's own terms and privacy policy apply (link
//    both)."
//  * Spec §7.4 "Approve": the authorization URL is opened only after the
//    client parsed it (9D.2d's validator); it is never logged or stored.
//  * Brief: tests never open a browser; only the adapter is faked.
// Expected strings are written out by hand (UTF-8 bytes per RFC 3986), not
// computed with the encoder under test.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/lastfm_authorization_url.dart';
import 'package:frontend/services/external_browser.dart';
import 'package:frontend/services/lastfm/lastfm_links.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../helpers/fake_external_browser.dart';
import '../../helpers/fake_lastfm_api.dart' show fakeLastfmUrl;

void main() {
  group('fixed links', () {
    test('the credit links to the Last.fm home page', () {
      expect(lastfmCreditUri.toString(), 'https://www.last.fm/');
    });

    test('terms and privacy policy are Last.fm pages over https', () {
      expect(lastfmTermsUri.toString(), 'https://www.last.fm/legal/terms');
      expect(lastfmPrivacyUri.toString(), 'https://www.last.fm/legal/privacy');
    });
  });

  group('the profile link', () {
    const table = <String, String>{
      'listener_01': 'https://www.last.fm/user/listener_01',
      'Some-One': 'https://www.last.fm/user/Some-One',
      'DJ Example': 'https://www.last.fm/user/DJ%20Example',
      'a/b': 'https://www.last.fm/user/a%2Fb',
      '../admin': 'https://www.last.fm/user/..%2Fadmin',
      'a?b#c': 'https://www.last.fm/user/a%3Fb%23c',
      '100%': 'https://www.last.fm/user/100%25',
      'a+b&c=d': 'https://www.last.fm/user/a%2Bb%26c%3Dd',
      'Ünï': 'https://www.last.fm/user/%C3%9Cn%C3%AF',
      '東京': 'https://www.last.fm/user/%E6%9D%B1%E4%BA%AC',
      'Ωmega': 'https://www.last.fm/user/%CE%A9mega',
      'a\u{1F3B5}': 'https://www.last.fm/user/a%F0%9F%8E%B5',
      'x@evil.example': 'https://www.last.fm/user/x%40evil.example',
      'a\\b': 'https://www.last.fm/user/a%5Cb',
    };
    for (final MapEntry(key: name, value: expected) in table.entries) {
      test('"$name" -> $expected', () {
        final uri = lastfmProfileUri(name);
        expect(uri, isNotNull);
        expect(uri.toString(), expected);
        expect(uri!.scheme, 'https');
        expect(uri.host, 'www.last.fm');
        expect(uri.hasPort, isFalse);
        expect(uri.userInfo, isEmpty);
        expect(uri.hasQuery, isFalse);
        expect(uri.hasFragment, isFalse);
        // The name stays one path segment under /user.
        expect(uri.pathSegments, ['user', name]);
      });
    }

    for (final name in ['', '.', '..', 'a\u202Eb', 'a\nb', 'x' * 65]) {
      test('no link for ${name.length > 8 ? '${name.length} chars' : '"$name"'}',
          () {
        expect(lastfmProfileUri(name), isNull);
      });
    }

    test('64 characters still get a link', () {
      final name = 'x' * 64;
      expect(lastfmProfileUri(name).toString(),
          'https://www.last.fm/user/$name');
    });
  });

  group('LastfmLinks opens through the adapter only', () {
    late FakeExternalBrowser browser;
    late LastfmLinks links;
    setUp(() {
      browser = FakeExternalBrowser();
      final c = ProviderContainer(
        overrides: [externalBrowserProvider.overrideWithValue(browser)],
      );
      addTearDown(c.dispose);
      links = c.read(lastfmLinksProvider);
    });

    test('credit, terms and privacy open exactly their link', () async {
      expect(await links.openCredit(), isTrue);
      expect(await links.openTerms(), isTrue);
      expect(await links.openPrivacy(), isTrue);
      expect(browser.opened.map((u) => u.toString()), [
        'https://www.last.fm/',
        'https://www.last.fm/legal/terms',
        'https://www.last.fm/legal/privacy',
      ]);
    });

    test('the profile opens the percent-encoded link', () async {
      expect(await links.openProfile('DJ Example/東'), isTrue);
      expect(browser.opened.single.toString(),
          'https://www.last.fm/user/DJ%20Example%2F%E6%9D%B1');
    });

    test('an implausible name opens nothing', () async {
      expect(await links.openProfile('..'), isFalse);
      expect(await links.openProfile('a\u202Eb'), isFalse);
      expect(browser.opened, isEmpty);
    });

    test('the authorization URL opens as validated, unchanged', () async {
      final url = LastfmAuthorizationUrl.tryParse(fakeLastfmUrl)!;
      expect(await links.openAuthorization(url), isTrue);
      expect(browser.opened.single, url.uri);
      expect(browser.opened.single.toString(), fakeLastfmUrl);
    });

    test('the browser saying no is false', () async {
      browser.answer = false;
      expect(await links.openCredit(), isFalse);
      expect(browser.opened, hasLength(1));
    });

    test('a throwing adapter is false, never an exception', () async {
      browser.error = StateError('no browser');
      expect(await links.openCredit(), isFalse);
      expect(await links.openProfile('listener_01'), isFalse);
      expect(
        await links.openAuthorization(
          LastfmAuthorizationUrl.tryParse(fakeLastfmUrl)!,
        ),
        isFalse,
      );
    });
  });

  group('UrlLauncherBrowser', () {
    test('opens in the external application (the system browser)', () async {
      final calls = <(Uri, LaunchMode)>[];
      final browser = UrlLauncherBrowser(
        launch: (uri, mode) async {
          calls.add((uri, mode));
          return true;
        },
      );
      expect(await browser.open(lastfmCreditUri), isTrue);
      expect(calls, [(lastfmCreditUri, LaunchMode.externalApplication)]);
    });

    test('passes the platform answer through', () async {
      final browser = UrlLauncherBrowser(launch: (_, _) async => false);
      expect(await browser.open(lastfmCreditUri), isFalse);
    });

    test('a platform error is false, never an exception', () async {
      final browser = UrlLauncherBrowser(
        launch: (_, _) async => throw StateError('no plugin'),
      );
      expect(await browser.open(lastfmCreditUri), isFalse);
    });
  });
}
