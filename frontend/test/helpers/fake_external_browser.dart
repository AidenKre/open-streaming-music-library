// A recording system browser for tests (9D.2e). Nothing is ever opened.
import 'package:frontend/services/external_browser.dart';

class FakeExternalBrowser implements ExternalBrowser {
  FakeExternalBrowser({this.answer = true});

  /// What `open` answers.
  bool answer;

  /// When set, `open` throws it (a real adapter never throws; this checks
  /// that callers do not depend on that).
  Object? error;

  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    if (error != null) throw error!;
    return answer;
  }
}
