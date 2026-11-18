// Phase 7B.1a review #4: `package:http` joins a repeated header with commas.
// A proxy that adds the same `X-Server-Instance-Id` again must not turn the
// bound server's stamp into a mismatch; two DIFFERENT stamps on one response
// stay a value that matches no instance (never silently "no stamp").
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/instance_stamp.dart';

const _id = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const _other = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';

void main() {
  test('the same stamp repeated is that stamp', () {
    expect(instanceStampFrom({'x-server-instance-id': '$_id,$_id'}), _id);
    expect(instanceStampFrom({'x-server-instance-id': ' $_id , $_id '}), _id);
  });

  test('two different stamps match neither instance', () {
    final stamp = instanceStampFrom({'x-server-instance-id': '$_id,$_other'});
    expect(stamp, isNotNull);
    expect(sameServerInstance(stamp!, _id), isFalse);
    expect(sameServerInstance(stamp, _other), isFalse);
  });
}
