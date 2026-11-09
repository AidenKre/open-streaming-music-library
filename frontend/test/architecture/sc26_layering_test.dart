// SC-26 strict MVC, enforced on the source: views observe model state and
// send input to their feature controller; they never drive model notifiers
// themselves. Model code never imports ui/.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));

void main() {
  test('views do not drive the sync or conversion-job notifiers', () {
    const forbidden = [
      'trackSyncProvider.notifier',
      'conversionJobsProvider.notifier',
    ];
    final offenders = [
      for (final file in _dartFiles('lib/ui'))
        for (final pattern in forbidden)
          if (file.readAsStringSync().contains(pattern))
            '${file.path}: $pattern',
    ];
    expect(offenders, isEmpty);
  });

  test('model code never imports ui/', () {
    final offenders = [
      for (final dir in [
        'lib/api',
        'lib/database',
        'lib/models',
        'lib/providers',
        'lib/repositories',
        'lib/services',
      ])
        for (final file in _dartFiles(dir))
          if (file.readAsStringSync().contains("import 'package:frontend/ui/"))
            file.path,
    ];
    expect(offenders, isEmpty);
  });
}
