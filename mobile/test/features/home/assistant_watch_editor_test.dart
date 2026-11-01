import 'dart:convert';

import 'package:buzz/features/home/assistant_watch_editor.dart';
import 'package:buzz/shared/assistant/assistant_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final connection = AssistantConnection(
    origin: 'https://assistant.example',
    profile: 'personal',
    token: 'client-token',
  );
  AssistantWatch watch() => AssistantWatch({
    'revision': 7,
    'next_runs': [],
    'definition': {
      'id': 'real-monitor',
      'title': 'Account balance',
      'tool': 'accounts_read',
      'arguments': {'account': 'personal'},
      'read_only': true,
      'enabled': true,
      'interval_seconds': 900,
      'timezone': 'America/New_York',
      'interest': 'Material changes only',
      'ignore': ['Pending transactions'],
      'conditions': [
        {
          'id': 'balance-low',
          'kind': 'threshold',
          'pointer': '/balance',
          'op': 'lt',
          'value': 100,
        },
      ],
      'attention': {
        'mode': 'digest',
        'digest_seconds': 3600,
        'quiet_start': '22:00',
        'quiet_end': '07:00',
        'timezone': 'America/New_York',
      },
      'result': {
        'pointer': '/accounts',
        'mode': 'records',
        'id_pointers': ['/id'],
        'compare_pointers': ['/balance'],
      },
      'pagination': {'mode': 'offset', 'argument': 'offset', 'max_pages': 3},
      'changes': ['updated'],
      'baseline': 'silent',
      'server_extension': {'preserved': true},
    },
  });

  Future<void> visible(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'source discovery and preview are explicit; save preserves mapping with CAS',
    (tester) async {
      final commands = <Map<String, dynamic>>[];
      final original = watch();
      final client = AssistantClient(
        client: MockClient((request) async {
          final command = jsonDecode(request.body) as Map<String, dynamic>;
          commands.add(command);
          return http.Response(
            jsonEncode(switch (command['action']) {
              'tools' => {
                'ok': true,
                'tools': [
                  {
                    'name': 'accounts_read',
                    'description':
                        'Read account balances without making changes.',
                    'inputSchema': {
                      'type': 'object',
                      'required': ['account'],
                      'properties': {
                        'account': {
                          'type': 'string',
                          'description': 'Account identifier to read',
                        },
                      },
                    },
                  },
                ],
              },
              'preview' => {
                'ok': true,
                'preview': {
                  'sample': {'balance': 90},
                  'records': 1,
                  'next_runs': [1800000000],
                },
              },
              _ => {
                'ok': true,
                'watch': {
                  'definition': command['watch'],
                  'revision': 8,
                  'next_runs': [],
                },
              },
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantWatchEditor(
            client: client,
            connection: connection,
            watch: original,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(commands, isEmpty);
      await visible(tester, 'Load approved sources and schemas');
      await tester.tap(find.text('Load approved sources and schemas'));
      await tester.pumpAndSettle();
      expect(commands.single, {'resource': 'observer', 'action': 'tools'});
      expect(
        find.text('Read account balances without making changes.'),
        findsOneWidget,
      );
      await visible(tester, 'account (required)');
      expect(find.text('string · Account identifier to read'), findsOneWidget);
      await visible(tester, 'Preview source and schedule');
      await tester.tap(find.text('Preview source and schedule'));
      await tester.pumpAndSettle();
      expect(commands[1]['action'], 'preview');
      expect(commands[1]['watch']['id'], 'real-monitor');
      expect(
        commands[1]['watch']['conditions'],
        original.definition['conditions'],
      );
      await visible(tester, 'Preview only · not saved or scheduled');
      expect(
        find.text('Preview only · not saved or scheduled'),
        findsOneWidget,
      );
      await visible(tester, 'Save monitor');
      await tester.tap(find.text('Save monitor'));
      await tester.pumpAndSettle();
      final saved = commands.last;
      expect(saved['action'], 'save');
      expect(saved['expected_revision'], 7);
      final definition = saved['watch'] as Map;
      for (final key in [
        'id',
        'tool',
        'arguments',
        'result',
        'pagination',
        'changes',
        'baseline',
        'conditions',
        'attention',
        'server_extension',
      ]) {
        expect(
          definition[key],
          original.definition[key],
          reason: '$key must survive a friendly edit',
        );
      }
      expect(commands.map((c) => c['action']), ['tools', 'preview', 'save']);
      await tester.pumpWidget(const SizedBox());
      client.close();
    },
  );

  testWidgets(
    'cron preview switches away from interval and preserves IANA timezone',
    (tester) async {
      final commands = <Map<String, dynamic>>[];
      final client = AssistantClient(
        client: MockClient((request) async {
          commands.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            '{"ok":true,"preview":{"sample":{},"next_runs":[]}}',
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantWatchEditor(
            client: client,
            connection: connection,
            watch: watch(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await visible(tester, 'Use cron schedule');
      await tester.tap(find.text('Use cron schedule'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Cron expression'),
        '0 9 * * 1-5',
      );
      await visible(tester, 'Preview source and schedule');
      await tester.tap(find.text('Preview source and schedule'));
      await tester.pumpAndSettle();
      final definition = commands.single['watch'] as Map;
      expect(definition['cron'], '0 9 * * 1-5');
      expect(definition['timezone'], 'America/New_York');
      expect(definition.containsKey('interval_seconds'), isFalse);
      expect(commands.single['action'], 'preview');
      await tester.pumpWidget(const SizedBox());
      client.close();
    },
  );

  testWidgets('save conflict keeps draft visible with no automatic replay', (
    tester,
  ) async {
    var calls = 0;
    final client = AssistantClient(
      client: MockClient((_) async {
        calls++;
        return http.Response('{"ok":false,"error":"stale revision"}', 409);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantWatchEditor(
          client: client,
          connection: connection,
          watch: watch(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await visible(tester, 'Save monitor');
    await tester.tap(find.text('Save monitor'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.drag(find.byType(ListView), const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 409'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Account balance'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    client.close();
  });
}
