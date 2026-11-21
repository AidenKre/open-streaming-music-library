import 'dart:async';

import 'package:http/http.dart' as http;

/// The shared inner transport of the API tests: answers [status] with `{}`
/// (after [gate], when set), records every request it is handed and whether
/// anyone closed it (moved here from two API tests, APP-TEST stage 2).
class SpyInnerClient extends http.BaseClient {
  SpyInnerClient({this.status = 200, this.gate, this.headers = const {}});
  int status;

  /// The answer's headers (a server's instance stamp, for example).
  final Map<String, String> headers;
  final Completer<void>? gate;
  final List<http.BaseRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw StateError('inner client used after close');
    requests.add(request);
    await gate?.future;
    return http.StreamedResponse(
      Stream.value('{}'.codeUnits),
      status,
      request: request,
      headers: headers,
    );
  }

  @override
  void close() => closed = true;
}
