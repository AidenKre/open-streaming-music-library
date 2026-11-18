// Refactor A.3 slice 2, characterization: which requests of the upload
// manager treat a 4xx answer as final whatever its `retryable` flag says.
//
// A review answer does (pinned in upload_manager_review_answers_test, "422
// tag_write_unsupported (retryable) is a refusal"); so does a deletion
// submission (delete_jobs_submit_test, "a refusal is final"). The content
// transfer honours the flag (upload_manager_transfer_outcome_test, the 409
// case). This file pins the remaining one: the allocation honours it too.
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

List<String> _allocations(FakeUploadsApi api) => [
  for (final c in api.calls)
    if (c.startsWith('allocate') || c.startsWith('getBatch')) c,
];

void main() {
  late UploadHarness h;

  setUp(() async => h = await UploadHarness.create());
  tearDown(() => h.dispose());

  test('allocation: a 4xx the server calls retryable is not a refusal: the '
      'files stay waiting, and the same body is sent again after the batch '
      'status was asked first', () async {
    var first = true;
    final defaultAllocate = h.api.onAllocate;
    h.api.onAllocate = (body) async {
      if (first) {
        first = false;
        throw apiError(409, 'upload_busy', retryable: true);
      }
      return defaultAllocate(body);
    };
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect((await h.intents()).single['last_state'], 'allocating');
    final row = (await h.submissions()).single;
    expect(row['state'], 'ambiguous', reason: 'not rejected');
    expect(row['error_code'], 'upload_busy');

    h.timers.fire(); // the runner's backoff retry
    await h.pump();

    expect(_allocations(h.api), [
      'allocate u-1',
      'getBatch u-1',
      'allocate u-1',
    ]);
    expect(h.api.allocations[1], h.api.allocations[0]);
    expect(
      (await h.submissions())
          .singleWhere((s) => s['kind'] == 'upload_allocation')['state'],
      'accepted',
    );
  });

  test('allocation, control: the same 4xx without the flag is a refusal and '
      'is never sent again', () async {
    h.api.onAllocate = (_) async =>
        throw apiError(409, 'upload_busy', retryable: false);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect((await h.intents()).single['last_state'], 'rejected');
    expect((await h.submissions()).single['state'], 'rejected');

    h.timers.fire();
    h.manager.start();
    await h.pump();
    expect(_allocations(h.api), ['allocate u-1']);
  });
}
