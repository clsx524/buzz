import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../storage/secure_storage.dart';

typedef AssistantJson = Map<String, dynamic>;

/// A separate client credential, never a relay or observer service token.
class AssistantConnection {
  AssistantConnection({
    required String origin,
    required String profile,
    required String token,
  }) : origin = _origin(origin),
       profile = profile.trim(),
       token = token.trim() {
    if (this.profile.isEmpty || this.token.isEmpty) {
      throw const FormatException('Profile and client API token are required.');
    }
  }
  final String origin;
  final String profile;
  final String token;

  static String _origin(String value) {
    final uri = Uri.parse(value.trim());
    if (!['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Use a server origin, without credentials, path, query or fragment.',
      );
    }
    if (uri.scheme == 'http' &&
        !['localhost', '127.0.0.1', '::1'].contains(uri.host)) {
      throw const FormatException(
        'Use HTTPS except for loopback development servers.',
      );
    }
    return uri.origin;
  }

  AssistantJson toJson() => {
    'origin': origin,
    'profile': profile,
    'token': token,
  };
  factory AssistantConnection.fromJson(AssistantJson json) =>
      AssistantConnection(
        origin: json['origin'] as String,
        profile: json['profile'] as String,
        token: json['token'] as String,
      );
}

/// Each saved native connection is one atomic secure-storage snapshot.
/// Web deliberately keeps the entire snapshot only in process memory.
class AssistantConnectionStore {
  AssistantConnectionStore({FlutterSecureStorage? storage, bool? web})
    : _storage = storage ?? accountSecureStorage,
      _web = web ?? kIsWeb;
  final FlutterSecureStorage _storage;
  final bool _web;
  static const _key = 'personal-assistant:connection:v1';
  static AssistantConnection? _session;
  bool get sessionOnly => _web;
  Future<AssistantConnection?> load() async {
    if (_web) return _session;
    final value = await _storage.read(key: _key);
    return value == null
        ? null
        : AssistantConnection.fromJson(
            Map<String, dynamic>.from(jsonDecode(value) as Map),
          );
  }

  Future<void> save(AssistantConnection connection) async {
    if (_web) {
      _session = connection;
      return;
    }
    await _storage.write(key: _key, value: jsonEncode(connection.toJson()));
  }

  Future<void> clear() async {
    if (_web) {
      _session = null;
      return;
    }
    await _storage.delete(key: _key);
  }
}

class AssistantAPIError implements Exception {
  const AssistantAPIError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() =>
      'HTTP $status: $message${status == 409 ? ' Reload the current monitor before saving or deleting again.' : ''}';
}

/// Preserves additional runtime/definition fields across full CAS edits.
class AssistantWatch {
  AssistantWatch(this.json)
    : definition = Map<String, dynamic>.from(json['definition'] as Map),
      revision = json['revision'] as int;
  final AssistantJson json;
  final AssistantJson definition;
  final int revision;
  String get id => definition['id'] as String;
}

class AssistantDashboard {
  AssistantDashboard(AssistantJson json)
    : profile = json['profile'] as String,
      runtime = Map<String, dynamic>.from(json['runtime'] as Map),
      watches = (json['watches'] as List)
          .map((e) => AssistantWatch(Map<String, dynamic>.from(e as Map)))
          .toList(),
      concerns = _rows(json['concerns']),
      decisions = _rows(json['decisions']),
      questions = _rows(json['questions']);
  final String profile;
  final AssistantJson runtime;
  final List<AssistantWatch> watches;
  final List<AssistantJson> concerns;
  final List<AssistantJson> decisions;
  final List<AssistantJson> questions;
  static List<AssistantJson> _rows(dynamic value) =>
      (value as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

/// Requests never redirect or retry, including ambiguous mutation failures.
class AssistantClient {
  AssistantClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  void close() => _client.close();

  Future<AssistantDashboard> dashboard(AssistantConnection connection) async {
    final value = await _request(connection, 'dashboard');
    final dashboard = AssistantDashboard(value);
    if (dashboard.profile != connection.profile) {
      throw const FormatException(
        'Server returned a different assistant profile.',
      );
    }
    return dashboard;
  }

  Future<AssistantJson> command(
    AssistantConnection connection,
    AssistantJson command,
  ) => _request(connection, 'command', command);

  Future<AssistantJson> _request(
    AssistantConnection connection,
    String endpoint, [
    AssistantJson? body,
  ]) async {
    final uri = Uri.parse(connection.origin).replace(
      pathSegments: ['api', 'personal-assistant', connection.profile, endpoint],
    );
    final request = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${connection.token}'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 45));
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw AssistantAPIError(
        response.statusCode,
        'Server returned a non-JSON response.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AssistantAPIError(
        response.statusCode,
        decoded is Map
            ? '${decoded['error'] ?? response.reasonPhrase ?? 'Request failed'}'
            : 'Request failed',
      );
    }
    if (decoded is! Map || decoded['ok'] != true) {
      throw AssistantAPIError(
        response.statusCode,
        decoded is Map
            ? '${decoded['error'] ?? 'Invalid response'}'
            : 'Invalid response',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }
}
