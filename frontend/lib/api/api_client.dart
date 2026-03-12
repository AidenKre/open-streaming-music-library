import 'dart:convert';
import 'dart:developer' as developer;
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
    final basePath = baseUri.pathSegments.where((s) => s.isNotEmpty).toList();
    final uri = baseUri.replace(
      pathSegments: [...basePath, ...pathSegments],
      queryParameters: query?.isNotEmpty == true ? query : null,
    );

    developer.log('GET $uri', name: 'ApiClient');
    try {
      final response = await _http.get(
        uri,
        headers: {'Accept': 'application/json', ...?headers},
      );
      developer.log('${response.statusCode} ${response.body.length}B', name: 'ApiClient');
      return _handleResponse(response);
    } catch (e) {
      developer.log('ERROR: $e', name: 'ApiClient');
      rethrow;
    }
  }

  Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    throw ApiException(response.statusCode, response.body);
  }

  /// Returns null if healthy, or an error message string.
  Future<String?> healthCheck() async {
    try {
      final data = await getJson([]);
      if (data['message'] == 'Healthy') return null;
      return 'Unexpected response from server';
    } on ApiException catch (e) {
      return 'Server error: ${e.statusCode}';
    } catch (e) {
      return 'Could not reach server: $e';
    }
  }

  void close() {
    _http.close();
  }
}
