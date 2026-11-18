// Coordinator round 2 (owner, 2026-11-17): "We should never reveal track ids
// to users". A track without a title on this device reads "Unknown track".
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/models/track_names.dart';

void main() {
  test('a title is shown as it is; none or an empty one is Unknown track', () {
    expect(trackTitleOrUnknown('Song'), 'Song');
    expect(trackTitleOrUnknown(null), 'Unknown track');
    expect(trackTitleOrUnknown(''), 'Unknown track');
  });
}
