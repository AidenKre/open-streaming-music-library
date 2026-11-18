import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/services/download/download_status_reader.dart';

void main() {
  late DownloadStatusReader reader;

  setUp(() {
    reader = DownloadStatusReader();
  });

  tearDown(() {
    reader.dispose();
  });

  test('bumpVersion increments downloadStatusVersion', () {
    final before = reader.downloadStatusVersion.value;
    reader.bumpVersion();
    expect(reader.downloadStatusVersion.value, before + 1);
    reader.bumpVersion();
    expect(reader.downloadStatusVersion.value, before + 2);
  });
}
