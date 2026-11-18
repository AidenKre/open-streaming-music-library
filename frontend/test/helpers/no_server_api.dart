import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client for tests that build a networked object but have no server: like
/// the unconfigured client these tests used to get implicitly, every request
/// fails at the transport level (a NetworkException).
ApiClient noServerApi() => testApiClient(
      '',
      MockClient((_) async => throw http.ClientException('no server in this test')),
    );
