import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:buzz/shared/assistant/assistant_cache.dart';

import 'package:buzz/shared/assistant/assistant_item.dart';
import 'package:buzz/shared/relay/nostr_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture =
      jsonDecode(
            File('../test-fixtures/assistant-contract.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final viewer = fixture['viewer'] as String;
  final itemId = fixture['itemId'] as String;
  final channel = fixture['channelId'] as String;
  NostrEvent event({
    required String type,
    required String id,
    required String content,
    String? author,
    List<List<String>> extra = const [],
  }) => NostrEvent(
    id: 'a' * 64,
    pubkey: author ?? viewer,
    createdAt: 1793404800,
    kind: assistantArtifactKind,
    sig: '',
    content: content,
    tags: [
      ['ar', '1'],
      ['d', id],
      ['h', channel],
      ['type', type],
      ['title', 'Review transactions'],
      ['op', 'create'],
      ...extra,
    ],
  );
  test(
    'large report caches preserve UTF-8 across encryption chunk boundaries',
    () {
      final key = Uint8List(32);
      final report = jsonEncode({'body': '${'a' * 32767}${'🌳é' * 20000}'});
      expect(utf8.encode(report).length, greaterThan(65535));
      expect(
        decodeAssistantCache(key, encodeAssistantCache(key, report)),
        report,
      );
      final wrongKey = Uint8List(32)..[0] = 1;
      expect(
        () => decodeAssistantCache(wrongKey, encodeAssistantCache(key, report)),
        throwsFormatException,
      );
    },
  );
  final source = event(
    type: 'assistant.finding',
    id: itemId,
    content: jsonEncode(fixture['item']),
  );
  final item = AssistantItem.fromEvent(source);

  test(
    'shared UUID and snooze deadline resurface without changing saved state',
    () {
      expect(assistantStateId(viewer, itemId), fixture['stateId']);
      final state = AssistantItemState.decode(jsonEncode(fixture['state']));
      final deadline = state.snoozedUntil!;
      expect(state.visibleAt(deadline - 1), isFalse);
      expect(state.visibleAt(deadline), isTrue);
      expect(state.visibleAt(deadline + 1), isTrue);
      expect(state.saved, isTrue);
      expect(
        const AssistantItemState(
          status: 'archived',
          saved: true,
        ).visibleAt(deadline),
        isFalse,
      );
      expect(item.requiresInput, isTrue);
      expect(item.sources.single.url?.scheme, 'https');
    },
  );

  test('owner tag does not authenticate state or permit cross-item state', () {
    final content = jsonEncode(fixture['state']);
    final tags = [
      ['owner', viewer],
      ['item', itemId],
    ];
    final good = event(
      type: 'assistant.state',
      id: fixture['stateId'] as String,
      content: content,
      extra: tags,
    );
    expect(AssistantItemState.fromEvent(good, viewer, item).saved, isTrue);
    for (final invalid in [
      event(
        type: 'assistant.state',
        id: fixture['stateId'] as String,
        author: 'b' * 64,
        content: content,
        extra: tags,
      ),
      event(type: 'assistant.state', id: itemId, content: content, extra: tags),
      event(
        type: 'assistant.state',
        id: fixture['stateId'] as String,
        content: content,
        extra: [
          ['owner', viewer],
          ['item', channel],
        ],
      ),
      event(
        type: 'assistant.state',
        id: fixture['stateId'] as String,
        content: content,
        extra: [
          ...tags,
          ['owner', viewer],
        ],
      ),
    ]) {
      expect(
        () => AssistantItemState.fromEvent(invalid, viewer, item),
        throwsFormatException,
      );
    }
  });

  test(
    'unsupported evidence and malformed attention cannot silently display as open',
    () {
      for (final url in [
        'javascript:alert(1)',
        'file:///private/data',
        'https:no-host',
      ]) {
        final value = Map<String, dynamic>.from(fixture['item'] as Map)
          ..['sources'] = [
            {'label': 'Source', 'url': url},
          ];
        expect(
          () => AssistantItem.fromEvent(
            event(
              type: 'assistant.finding',
              id: itemId,
              content: jsonEncode(value),
            ),
          ),
          throwsFormatException,
        );
      }
      for (final value in [
        {'version': 1, 'status': 'snoozed', 'saved': false},
        {'version': 1, 'status': 'snoozed', 'saved': false, 'snoozedUntil': -1},
        {'version': 1, 'status': 'open', 'saved': false, 'snoozedUntil': 1},
        {'version': 1, 'status': 'resolved', 'saved': true},
      ]) {
        expect(
          () => AssistantItemState.decode(jsonEncode(value)),
          throwsFormatException,
        );
      }
    },
  );
}
