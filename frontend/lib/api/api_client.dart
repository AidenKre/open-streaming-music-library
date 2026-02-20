import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  static final ApiClient instance = ApiClient._();
  ApiClient._() : _http = http.Client();

  late String baseUrl;
  http.Client _http;

  static void init(String url) {
    instance.baseUrl = url;
  }

  @visibleForTesting
  static void initForTest(String url, http.Client httpClient) {
    instance.baseUrl = url;
    instance._http = httpClient;
  }

  Future<Map<String, dynamic>> getJson(
    List<String> pathSegments, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    final baseUri = Uri.parse(baseUrl);
    final uri = baseUri.replace(
      pathSegments: [...baseUri.pathSegments, ...pathSegments],
      queryParameters: query,
    );

    final response = await _http.get(
      uri,
      headers: {'Accept': 'application/json', ...?headers},
    );

    return _handleResponse(response);
  }

  Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    throw ApiException(response.statusCode, response.body);
  }

  void close() {
    _http.close();
  }
}
