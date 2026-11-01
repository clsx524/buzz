import 'dart:async';
import 'dart:convert';

import 'package:buzz/features/home/assistant_controls_page.dart';
import 'package:buzz/shared/assistant/assistant_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Store extends AssistantConnectionStore {
  _Store(this.connection);
  AssistantConnection? connection;
  bool failLoad = false;
  @override
  Future<AssistantConnection?> load() async {
    if (failLoad) throw StateError('Keychain unavailable');
    return connection;
  }

  @override
  Future<void> save(AssistantConnection value) async {
    connection = value;
  }

  @override
  Future<void> clear() async {
    connection = null;
    failLoad = false;
  }
}

void main() {
  final connection = AssistantConnection(
    origin: 'https://assistant.example',
    profile: 'personal',
    token: 'secret',
  );
  Map<String, dynamic> dashboard({
    List<dynamic> concerns = const [],
    List<dynamic> decisions = const [],
    List<dynamic> questions = const [],
    List<dynamic> watches = const [],
  }) => {
    'ok': true,
    'profile': 'personal',
    'runtime': {},
    'watches': watches,
    'concerns': concerns,
    'decisions': decisions,
    'questions': questions,
  };
  http.Response response(dynamic value, [int status = 200]) =>
      http.Response(jsonEncode(value), status);
  Future<void> visible(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty startup reads dashboard only, never tools or preview', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final client = AssistantClient(
      client: MockClient((request) async {
        requests.add(request);
        return response(dashboard());
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantControlsPage(client: client, store: _Store(connection)),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests.length, 1);
    expect(requests.single.method, 'GET');
    expect(
      find.textContaining('Nothing is monitored until you configure'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  testWidgets(
    'failed refresh retains findings honestly and does not replay commands',
    (tester) async {
      var offline = false;
      var requests = 0;
      final client = AssistantClient(
        client: MockClient((_) async {
          requests++;
          if (offline) throw http.ClientException('network down');
          return response(
            dashboard(
              concerns: [
                {'id': 'c', 'title': 'Retained finding', 'status': 'open'},
              ],
            ),
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantControlsPage(
            client: client,
            store: _Store(connection),
          ),
        ),
      );
      await tester.pumpAndSettle();
      offline = true;
      await tester.tap(find.byTooltip('Refresh assistant'));
      await tester.pumpAndSettle();
      expect(find.textContaining('last loaded snapshot'), findsOneWidget);
      await visible(tester, 'Retained finding');
      expect(find.text('Retained finding'), findsOneWidget);
      expect(requests, 2);
      await tester.pumpWidget(const SizedBox());
      client.close();
    },
  );

  testWidgets('handled snooze and resume address exact concern IDs', (
    tester,
  ) async {
    final commands = <Map<String, dynamic>>[];
    final client = AssistantClient(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          commands.add(jsonDecode(request.body) as Map<String, dynamic>);
          return response({'ok': true});
        }
        return response(
          dashboard(
            concerns: [
              {
                'id': 'concern-exact',
                'watch_id': 'not-the-concern',
                'record_id': 'not-the-concern-either',
                'title': 'Finding',
                'status': 'open',
              },
            ],
          ),
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantControlsPage(client: client, store: _Store(connection)),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['Mark handled', 'Snooze', 'Resume']) {
      await visible(tester, label);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      if (label == 'Snooze') {
        await tester.tap(find.text('4 hours'));
        await tester.pumpAndSettle();
      }
    }
    expect(commands, [
      {
        'resource': 'concerns',
        'action': 'handled',
        'concern_id': 'concern-exact',
      },
      {
        'resource': 'concerns',
        'action': 'snooze',
        'concern_id': 'concern-exact',
        'seconds': 14400,
      },
      {
        'resource': 'concerns',
        'action': 'resume',
        'concern_id': 'concern-exact',
      },
    ]);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  testWidgets(
    'questions and feedback retain question and integer decision IDs',
    (tester) async {
      final commands = <Map<String, dynamic>>[];
      final client = AssistantClient(
        client: MockClient((request) async {
          if (request.method == 'POST') {
            commands.add(jsonDecode(request.body) as Map<String, dynamic>);
            return response({'ok': true});
          }
          return response(
            dashboard(
              questions: [
                {
                  'id': 'question-exact',
                  'concern_id': 'concern-parent',
                  'prompt': 'Which account?',
                  'answer': null,
                  'created': 1,
                },
              ],
              decisions: [
                {
                  'id': 42,
                  'concern_id': 'concern-parent',
                  'kind': 'notify',
                  'title': 'Decision',
                  'created': 1,
                },
              ],
            ),
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantControlsPage(
            client: client,
            store: _Store(connection),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await visible(tester, 'Answer');
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Your answer'),
        'Personal account',
      );
      await tester.tap(find.text('Send answer'));
      await tester.pumpAndSettle();
      await visible(tester, 'Feedback and preference');
      await tester.tap(find.text('Feedback and preference'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Explicit preference (optional)'),
        'Only notify me about personal accounts.',
      );
      await tester.tap(find.text('Submit feedback'));
      await tester.pumpAndSettle();
      expect(commands, [
        {
          'resource': 'concerns',
          'action': 'answer',
          'question_id': 'question-exact',
          'answer': 'Personal account',
        },
        {
          'resource': 'feedback',
          'action': 'submit',
          'decision_id': 42,
          'signal': 'useful',
          'preference': 'Only notify me about personal accounts.',
        },
      ]);
      await tester.pumpWidget(const SizedBox());
      client.close();
    },
  );

  testWidgets(
    'delete sends CAS revision, preserves conflict and never retries',
    (tester) async {
      final commands = <Map<String, dynamic>>[];
      final client = AssistantClient(
        client: MockClient((request) async {
          if (request.method == 'POST') {
            commands.add(jsonDecode(request.body) as Map<String, dynamic>);
            return response({'ok': false, 'error': 'stale revision'}, 409);
          }
          return response(
            dashboard(
              watches: [
                {
                  'id': 'watch-exact',
                  'revision': 9,
                  'definition': {
                    'id': 'watch-exact',
                    'title': 'Original monitor',
                    'tool': 'source',
                    'arguments': {},
                    'read_only': true,
                    'enabled': true,
                    'interval_seconds': 900,
                  },
                  'next_runs': [],
                },
              ],
            ),
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantControlsPage(
            client: client,
            store: _Store(connection),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await visible(tester, 'Delete');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(commands, [
        {
          'resource': 'observer',
          'action': 'delete',
          'id': 'watch-exact',
          'expected_revision': 9,
        },
      ]);
      await tester.drag(find.byType(ListView).first, const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP 409'), findsOneWidget);
      await visible(tester, 'Original monitor');
      expect(find.text('Original monitor'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      client.close();
    },
  );

  testWidgets('secure storage read failure still exposes connection recovery', (
    tester,
  ) async {
    final store = _Store(null)..failLoad = true;
    await tester.pumpWidget(
      MaterialApp(home: AssistantControlsPage(store: store)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Keychain unavailable'), findsOneWidget);
    expect(find.text('Connect assistant server'), findsOneWidget);
    await tester.tap(find.text('Remove saved connection'));
    await tester.pumpAndSettle();
    expect(store.failLoad, isFalse);
  });

  testWidgets(
    'evidence inspects exact concern and only opens explicit channel links',
    (tester) async {
      final commands = <Map<String, dynamic>>[];
      final opened = <String>[];
      final client = AssistantClient(
        client: MockClient((request) async {
          if (request.method == 'POST') {
            commands.add(jsonDecode(request.body) as Map<String, dynamic>);
            return response({
              'ok': true,
              'id': 'concern',
              'events': [
                {'fact': 'Immutable source fact'},
              ],
              'conversation_links': [
                {'session_id': 'never-a-channel'},
                {'channel_id': 'joined-channel', 'root': 'signed-root'},
              ],
              'delivery_links': [],
            });
          }
          return response(
            dashboard(
              concerns: [
                {
                  'id': 'concern',
                  'title': 'Evidence finding',
                  'status': 'open',
                },
              ],
            ),
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantControlsPage(
            client: client,
            store: _Store(connection),
            onConversation: (_, channel, root) async {
              opened.add('$channel:$root');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await visible(tester, 'Evidence and history');
      await tester.tap(find.text('Evidence and history'));
      await tester.pumpAndSettle();
      expect(commands, [
        {'resource': 'concerns', 'action': 'inspect', 'concern_id': 'concern'},
      ]);
      expect(find.text('Open linked conversation'), findsOneWidget);
      await tester.tap(find.text('Open linked conversation'));
      await tester.pumpAndSettle();
      expect(opened, ['joined-channel:signed-root']);
      await tester.pumpWidget(const SizedBox());
      client.close();
    },
  );

  testWidgets('disposed dashboard ignores late network completion', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final client = AssistantClient(client: MockClient((_) => pending.future));
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantControlsPage(client: client, store: _Store(connection)),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(response(dashboard()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    client.close();
  });
}
