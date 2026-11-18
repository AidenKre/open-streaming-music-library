// Phase 7 §7 para 3 / 7-L03 (unit half): an unpacked ZIP's files, read from
// every page of the batch's items, in the server's stable order, with
// valid / failed / skipped counts. The skipped count is the archive item's
// own `skipped_members` (7A.2d), listed in the same pages; null (or no
// archive item listed) is unknown and shows nothing, never 0
// (U31-FE-UPL-MGR-B-02).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';

import '../../helpers/fake_uploads_api.dart';

Map<String, dynamic> _child(
  String uuid,
  String state, {
  String parent = 'zip',
  String? name,
  Map<String, dynamic>? error,
}) => {
  ...itemJson(uuid, state: state, filename: name ?? '$uuid.flac', error: error),
  'parent_item_uuid': parent,
  'member_order_key': name ?? '$uuid.flac',
};

UploadItemPage _page(List<Map<String, dynamic>> items, {String? next}) =>
    UploadItemPage.fromJson({'items': items, 'next_after': next});

void main() {
  late FakeUploadsApi api;
  setUp(() => api = FakeUploadsApi());

  test('reads every page and keeps only this parent\'s children, in order',
      () async {
    final seen = <String?>[];
    api.onListItems = (batch, after) async {
      expect(batch, 'b-1');
      seen.add(after);
      return switch (after) {
        null => _page([
          {...itemJson('zip', state: 'expanded'), 'filename': 'a.zip'},
          _child('c1', 'review_ready', name: 'Disc/01 Intro.flac'),
          _child('c2', 'failed', error: {'code': 'bad_audio'}),
        ], next: 'k1'),
        'k1' => _page([
          _child('x1', 'review_ready', parent: 'other-zip'),
          _child('c3', 'validating'),
        ], next: 'k2'),
        _ => _page([_child('c4', 'imported'), _child('c5', 'cancelled')]),
      };
    };
    final result = await UploadZipChildren(api).load('b-1', 'zip');
    expect(seen, [null, 'k1', 'k2']);
    expect([for (final c in result.children) c.itemUuid], [
      'c1',
      'c2',
      'c3',
      'c4',
      'c5',
    ]);
    expect(result.children.first.displayName, 'Disc/01 Intro.flac');
    expect(result.valid, 2); // review_ready, imported
    expect(result.failed, 1);
    expect(result.checking, 1);
    expect(result.cancelled, 1);
    expect(result.skipped, isNull);
  });

  // U31-FE-UPL-MGR-B-02: the spec's skipped count (§7 para 3, §5 "a
  // visible skipped count"; 7-L03 "counts match manifest").
  group('U31-FE-UPL-MGR-B-02 skipped count', () {
    Map<String, dynamic> archive(String uuid, Object? skipped) => {
      ...itemJson(uuid, state: 'expanded', filename: '$uuid.zip'),
      'kind': 'zip',
      'skipped_members': skipped,
    };

    test("the archive's skipped count comes from its own item, on whichever "
        'page it is listed', () async {
      api.onListItems = (batch, after) async => switch (after) {
        null => _page([
          archive('other-zip', 7),
          _child('c1', 'review_ready'),
        ], next: 'k1'),
        _ => _page([archive('zip', 2), _child('c2', 'failed')]),
      };
      final result = await UploadZipChildren(api).load('b-1', 'zip');
      expect(result.skipped, 2);
      expect(result.countsText, '1 valid · 1 failed · 2 skipped');
      // The archive itself is not one of its files.
      expect([for (final c in result.children) c.itemUuid], ['c1', 'c2']);
    });

    test('a known zero is shown as 0 skipped', () async {
      api.onListItems = (batch, after) async =>
          _page([archive('zip', 0), _child('c1', 'review_ready')]);
      final result = await UploadZipChildren(api).load('b-1', 'zip');
      expect(result.skipped, 0);
      expect(result.countsText, '1 valid · 0 failed · 0 skipped');
    });

    test('unknown stays unknown: a null count or an archive not listed is '
        'null, never 0', () async {
      api.onListItems = (batch, after) async =>
          _page([archive('zip', null), _child('c1', 'review_ready')]);
      expect((await UploadZipChildren(api).load('b-1', 'zip')).skipped,
          isNull);

      api.onListItems = (batch, after) async =>
          _page([archive('other-zip', 3), _child('c1', 'review_ready')]);
      final result = await UploadZipChildren(api).load('b-1', 'zip');
      expect(result.skipped, isNull);
      expect(result.countsText, '1 valid · 0 failed');
    });
  });

  test('children read through the one status text function', () async {
    api.onListItems = (batch, after) async => _page([
      _child('c1', 'review_ready'),
      _child('c2', 'failed', error: {
        'code': 'upload_write_failed',
        'message': 'disk /srv/x full',
      }),
    ]);
    final result = await UploadZipChildren(api).load('b-1', 'zip');
    expect(result.children[0].statusText, 'Ready for review');
    expect(result.children[0].needsAttention, isFalse);
    expect(result.children[1].statusText, 'Failed');
    expect(result.children[1].detailText, 'The server could not store the file.');
    expect(result.children[1].needsAttention, isTrue);
  });

  test('which states count as valid', () async {
    api.onListItems = (batch, after) async => _page([
      for (final s in [
        'review_ready',
        'committing',
        'imported',
        'duplicate',
        'duplicate_conflict',
      ])
        _child(s, s),
      _child('e', 'expired'),
      _child('r', 'receiving'),
    ]);
    final result = await UploadZipChildren(api).load('b-1', 'zip');
    expect(result.valid, 5);
    expect(result.cancelled, 1);
    expect(result.checking, 1);
  });

  test('no children (absent manifest) is an empty list, not an error',
      () async {
    final result = await UploadZipChildren(api).load('b-1', 'zip');
    expect(result.children, isEmpty);
    expect(result.valid, 0);
    expect(result.failed, 0);
  });

  test('a failed page reaches the caller', () async {
    api.onListItems = (batch, after) async => throw apiError(500, 'boom');
    await expectLater(
      UploadZipChildren(api).load('b-1', 'zip'),
      throwsA(anything),
    );
  });

  test('counts text', () {
    ZipChildren z({
      int valid = 0,
      int failed = 0,
      int checking = 0,
      int cancelled = 0,
      int? skipped,
    }) => ZipChildren(
      children: const [],
      valid: valid,
      failed: failed,
      checking: checking,
      cancelled: cancelled,
      skipped: skipped,
    );
    expect(z(valid: 3, failed: 1, skipped: 2).countsText,
        '3 valid · 1 failed · 2 skipped');
    // Unknown skipped: nothing for it; valid and failed always shown.
    expect(z(valid: 3).countsText, '3 valid · 0 failed');
    expect(z(valid: 1, checking: 2, cancelled: 1, skipped: 0).countsText,
        '1 valid · 0 failed · 0 skipped · 2 still checking · 1 cancelled');
  });

  // 7-R2-05: the refused-review rule (UI-01) holds for a ZIP child as for a
  // top-level row: a ready child the server refuses to import offers no
  // Review tags, needs attention, and is not counted as valid.
  test('7-R2-05 a child the server refuses to import offers no review and '
      'needs attention', () async {
    api.onListItems = (batch, after) async => _page([
      _child('c1', 'review_ready',
          error: {'code': 'upload_library_links_unsupported'}),
      _child('c2', 'review_ready'),
    ]);
    final result = await UploadZipChildren(api).load('b-1', 'zip');
    final [refused, ready] = result.children;

    expect(refused.offersReviewTags, isFalse);
    expect(refused.needsAttention, isTrue);
    expect(ready.offersReviewTags, isTrue);
    expect(ready.needsAttention, isFalse);
    expect(result.valid, 1);
    expect(result.failed, 1);
  });
}
