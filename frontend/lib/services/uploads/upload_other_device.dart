// Whether another device is sending an upload (sign-off s7-app-texts
// follow-up): judged from this device's own reads of the upload's items and
// its own clock, never from the server's `updated_at` (it also moves on
// validation, retries and commits). Pure model code: no I/O, no providers.
import 'package:frontend/models/dto/upload_dtos.dart';

/// How long after the last arrival this device saw an upload still counts
/// as being sent: longer than two polls of the open page and than the gap
/// between two files of a sending device.
const otherDeviceArrivalWindow = Duration(minutes: 1);

/// States of an item still waiting for its bytes.
const _waiting = {'allocated', 'receiving', 'transferring'};

/// Ends that are no arrival of bytes.
const _notArrived = {'cancelled', 'cancelling', 'expired'};

/// What this device saw of the uploads' items: each item's state at the
/// previous read, and per batch the time of the last arrival seen.
class UploadArrivals {
  const UploadArrivals._(this._states, this._readAtMs, this._lastArrivalMs);

  static const empty = UploadArrivals._({}, {}, {});

  /// Item state at this device's previous read, by item UUID.
  final Map<String, String> _states;

  /// This device's clock at that read, by item UUID.
  final Map<String, int> _readAtMs;

  /// This device's clock at the last arrival it saw, by batch UUID.
  final Map<String, int> _lastArrivalMs;

  /// Records a read of [items] at [nowMs]. An item `receiving`, or one that
  /// was waiting for its bytes at the previous read and has moved on (but
  /// not to a cancel or an expiry), is an arrival for its batch. With no
  /// previous read of an item, or one older than [otherDeviceArrivalWindow],
  /// nothing is known about when it changed.
  UploadArrivals observe(List<UploadItem> items, int nowMs) {
    final states = {..._states};
    final readAt = {..._readAtMs};
    final arrivals = {..._lastArrivalMs};
    final window = otherDeviceArrivalWindow.inMilliseconds;
    for (final item in items) {
      final now = item.rawState;
      final before = _states[item.itemUuid];
      final beforeAt = _readAtMs[item.itemUuid];
      final arrived = now == 'receiving' ||
          (before != null &&
              beforeAt != null &&
              nowMs - beforeAt <= window &&
              _waiting.contains(before) &&
              !_waiting.contains(now) &&
              !_notArrived.contains(now));
      if (arrived) arrivals[item.batchUuid] = nowMs;
      states[item.itemUuid] = now;
      readAt[item.itemUuid] = nowMs;
    }
    return UploadArrivals._(states, readAt, arrivals);
  }

  /// The batches with an arrival seen at most [otherDeviceArrivalWindow]
  /// before [nowMs].
  Set<String> sendingBatches(int nowMs) => {
    for (final e in _lastArrivalMs.entries)
      if (nowMs - e.value <= otherDeviceArrivalWindow.inMilliseconds) e.key,
  };
}
