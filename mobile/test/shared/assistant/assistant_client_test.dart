import 'dart:convert';

import 'package:buzz/shared/assistant/assistant_client.dart';
import 'package:buzz/shared/storage/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final connection = AssistantConnection(
    origin: 'https://assistant.example/',
    profile: 'personal space',
    token: 'client-secret',
  );

  test('rejects credential-bearing origins, paths and remote plaintext', () {
    for (final origin in [
      'https://u:p@example.com',
      'https://example.com/path',
      'https://example.com?token=x',
      'https://example.com#x',
      'http://example.com',
      'file:///tmp',
    ]) {
      expect(
        () => AssistantConnection(origin: origin, profile: 'p', token: 't'),
        throwsFormatException,
      );
    }
    expect(
      AssistantConnection(
        origin: 'http://127.0.0.1:8090',
        profile: 'p',
        token: 't',
      ).origin,
      'http://127.0.0.1:8090',
    );
  });

  test(
    'commands encode profile, reject redirects and never replay mutations',
    () async {
      var calls = 0;
      final client = AssistantClient(
        client: MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          expect(request.headers['Authorization'], 'Bearer client-secret');
          expect(request.url.pathSegments, [
            'api',
            'personal-assistant',
            'personal space',
            'command',
          ]);
          expect(jsonDecode(request.body), {
            'resource': 'concerns',
            'action': 'handled',
            'concern_id': 'exact-id',
          });
          return http.Response(
            '{"ok":false,"error":"redirect refused"}',
            307,
            headers: {'location': 'https://untrusted.example'},
          );
        }),
      );
      await expectLater(
        client.command(connection, {
          'resource': 'concerns',
          'action': 'handled',
          'concern_id': 'exact-id',
        }),
        throwsA(
          isA<AssistantAPIError>().having((e) => e.status, 'status', 307),
        ),
      );
      expect(calls, 1);
      client.close();
    },
  );

  test(
    'preserves HTTP 401, 409 and 503 errors including non-JSON errors',
    () async {
      for (final status in [401, 409, 503]) {
        final client = AssistantClient(
          client: MockClient(
            (_) async => http.Response(
              status == 503 ? 'offline' : '{"ok":false,"error":"failure"}',
              status,
            ),
          ),
        );
        await expectLater(
          client.command(connection, {
            'resource': 'observer',
            'action': 'delete',
            'id': 'watch',
            'expected_revision': 7,
          }),
          throwsA(
            isA<AssistantAPIError>().having((e) => e.status, 'status', status),
          ),
        );
        client.close();
      }
    },
  );

  test(
    'native connection is a single secure snapshot and clears together',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = AssistantConnectionStore(web: false);
      await store.save(connection);
      final saved = await accountSecureStorage.readAll();
      expect(saved.length, 1);
      expect(jsonDecode(saved.values.single), connection.toJson());
      final restored = await store.load();
      expect(restored!.toJson(), connection.toJson());
      await store.clear();
      expect(await store.load(), isNull);
      expect(await accountSecureStorage.readAll(), isEmpty);
    },
  );

  test(
    'web connection token only lives in module memory, never secure web storage',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = AssistantConnectionStore(web: true);
      await store.clear();
      await store.save(connection);
      expect(
        (await AssistantConnectionStore(web: true).load())!.token,
        'client-secret',
      );
      expect(await accountSecureStorage.readAll(), isEmpty);
      await store.clear();
      expect(await store.load(), isNull);
    },
  );

  test('watch model retains non-editor fields for CAS round trips', () {
    final watch = AssistantWatch({
      'id': 'w',
      'revision': 4,
      'definition': {
        'id': 'w',
        'title': 'Monitor',
        'tool': 'source',
        'arguments': {},
        'read_only': true,
        'enabled': true,
        'baseline': 'silent',
        'changes': ['updated'],
        'future_field': {'a': 1},
      },
      'next_runs': [],
    });
    expect(watch.revision, 4);
    expect(watch.definition['future_field'], {'a': 1});
    expect(watch.definition['baseline'], 'silent');
  });
}
