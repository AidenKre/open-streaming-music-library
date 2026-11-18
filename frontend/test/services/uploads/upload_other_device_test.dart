// Sign-off s7-app-texts follow-up (owner 2026-11-17): instead of a hedge,
// the app checks whether another device is sending an upload. The rule is
// pure: from this device's own reads of a batch (item states) and its own
// clock. A read that shows an item `receiving`, or an item that was waiting
// for bytes (allocated or receiving) at the previous read and has its bytes
// now, is an arrival this device saw; for [otherDeviceArrivalWindow] after
// the last one seen, the upload counts as being sent.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_other_device.dart';

import '../../helpers/fake_uploads_api.dart';

UploadItem _item(String uuid, String state,
        {String batch = 'b-1', Map<String, dynamic>? error}) =>
    UploadItem.fromJson(
        itemJson(uuid, batchUuid: batch, state: state, error: error));

const _t0 = 1000000;
const _second = 1000;

void main() {
  test('the window is a minute: longer than two polls of the open page and '
      'than the gap between two files of a sending device', () {
    expect(otherDeviceArrivalWindow, const Duration(minutes: 1));
    expect(otherDeviceArrivalWindow, greaterThan(UploadManager.pollInterval * 2));
  });

  test('nothing read yet: no upload is being sent', () {
    expect(UploadArrivals.empty.sendingBatches(_t0), isEmpty);
  });

  test('this file arriving now', () {
    final a = UploadArrivals.empty
        .observe([_item('x', 'receiving'), _item('y', 'allocated')], _t0);
    expect(a.sendingBatches(_t0), {'b-1'});
  });

  test('another file of the same upload arriving now', () {
    final a = UploadArrivals.empty.observe([
      _item('x', 'allocated'),
      _item('y', 'receiving'),
    ], _t0);
    expect(a.sendingBatches(_t0), {'b-1'});
  });

  test('another upload arriving says nothing about this one', () {
    final a = UploadArrivals.empty
        .observe([_item('x', 'allocated')], _t0)
        .observe([_item('z', 'receiving', batch: 'b-2')], _t0);
    expect(a.sendingBatches(_t0), {'b-2'});
  });

  test('nothing of the upload arriving: not being sent', () {
    var a = UploadArrivals.empty.observe([
      _item('x', 'allocated'),
      _item('y', 'allocated'),
    ], _t0);
    a = a.observe([_item('x', 'allocated'), _item('y', 'allocated')],
        _t0 + 5 * _second);
    expect(a.sendingBatches(_t0 + 5 * _second), isEmpty);
  });

  test('items already past receiving at the first read are no arrival this '
      'device saw', () {
    final a = UploadArrivals.empty.observe([
      _item('x', 'allocated'),
      _item('y', 'validating'),
      _item('z', 'review_ready'),
    ], _t0);
    expect(a.sendingBatches(_t0), isEmpty);
  });

  group('a file that arrived between two reads (a small file, or the gap '
      'between two files)', () {
    UploadArrivals arrived() => UploadArrivals.empty
        .observe([_item('x', 'allocated'), _item('y', 'allocated')], _t0)
        .observe([_item('x', 'allocated'), _item('y', 'validating')],
            _t0 + 5 * _second);

    test('counts as being sent', () {
      expect(arrived().sendingBatches(_t0 + 5 * _second), {'b-1'});
    });

    test('until exactly the window after the read that saw it, not after',
        () {
      final seenAt = _t0 + 5 * _second;
      final window = otherDeviceArrivalWindow.inMilliseconds;
      expect(arrived().sendingBatches(seenAt + window), {'b-1'});
      expect(arrived().sendingBatches(seenAt + window + 1), isEmpty);
    });

    test('a later read with nothing new does not extend it', () {
      final window = otherDeviceArrivalWindow.inMilliseconds;
      final later = arrived().observe(
          [_item('x', 'allocated'), _item('y', 'review_ready')],
          _t0 + 30 * _second);
      expect(later.sendingBatches(_t0 + 5 * _second + window + 1), isEmpty);
    });
  });

  // Review #2: a change is dated only against a read at most the window
  // old (the page was closed, offline or backing off meanwhile).
  group('the previous read\'s age', () {
    final window = otherDeviceArrivalWindow.inMilliseconds;
    UploadArrivals after(int gapMs) => UploadArrivals.empty
        .observe([_item('x', 'allocated'), _item('y', 'allocated')], _t0)
        .observe([_item('x', 'allocated'), _item('y', 'validating')],
            _t0 + gapMs);

    test('a change against a read older than the window is no arrival', () {
      expect(after(window + 1).sendingBatches(_t0 + window + 1), isEmpty);
    });

    test('against a read exactly the window old, it still is', () {
      expect(after(window).sendingBatches(_t0 + window), {'b-1'});
    });
  });

  test('a person\'s retry (failed to validating) is no arrival', () {
    final a = UploadArrivals.empty
        .observe([_item('x', 'allocated'), _item('y', 'failed')], _t0)
        .observe([_item('x', 'allocated'), _item('y', 'validating')],
            _t0 + 5 * _second);
    expect(a.sendingBatches(_t0 + 5 * _second), isEmpty);
  });

  test('a cancel or an expiry is no arrival', () {
    final a = UploadArrivals.empty
        .observe([_item('x', 'allocated'), _item('y', 'allocated')], _t0)
        .observe([_item('x', 'allocated'), _item('y', 'cancelled')],
            _t0 + 5 * _second)
        .observe([_item('x', 'expired'), _item('y', 'cancelled')],
            _t0 + 10 * _second);
    expect(a.sendingBatches(_t0 + 10 * _second), isEmpty);
  });

  // The server ends a broken PUT at once when it sees the client gone, or
  // after 30 s without bytes (upload_idle_timeout), back to allocated.
  group('a dropped connection, as the server reports it', () {
    final interrupted = {
      'code': 'upload_idle_timeout',
      'message': 'stalled',
      'retryable': true,
    };

    test('receiving stays for up to 30 s, then allocated: sent until a '
        'minute after this device last saw it receiving', () {
      final window = otherDeviceArrivalWindow.inMilliseconds;
      var a = UploadArrivals.empty
          .observe([_item('x', 'receiving'), _item('y', 'allocated')], _t0);
      // The stall: still receiving at the next reads.
      a = a.observe([_item('x', 'receiving'), _item('y', 'allocated')],
          _t0 + 25 * _second);
      a = a.observe([
        _item('x', 'allocated', error: interrupted),
        _item('y', 'allocated'),
      ], _t0 + 30 * _second);
      expect(a.sendingBatches(_t0 + 30 * _second), {'b-1'});
      expect(a.sendingBatches(_t0 + 25 * _second + window), {'b-1'});
      expect(a.sendingBatches(_t0 + 25 * _second + window + 1), isEmpty);
    });
  });
}
