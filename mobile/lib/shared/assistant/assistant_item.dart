import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../relay/nostr_models.dart';

const personalAssistantMode = bool.fromEnvironment(
  'BUZZ_PERSONAL_ASSISTANT',
  defaultValue: true,
);
const assistantArtifactKind = 45010;
const assistantItemTypes = [
  'assistant.finding',
  'assistant.update',
  'assistant.report',
];
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

String assistantStateId(String owner, String item) => const Uuid().v5(
  '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
  'buzz-assistant-state:$owner:$item',
);

String artifactTag(NostrEvent event, String key) {
  final tags = event.tags.where((tag) => tag.isNotEmpty && tag[0] == key);
  if (tags.length != 1 || tags.single.length != 2) {
    throw FormatException('Invalid assistant $key tag');
  }
  return tags.single[1];
}

void validateAssistantEnvelope(NostrEvent event) {
  if (event.kind != assistantArtifactKind ||
      artifactTag(event, 'ar') != '1' ||
      !_uuid.hasMatch(artifactTag(event, 'd')) ||
      !_uuid.hasMatch(artifactTag(event, 'h')) ||
      artifactTag(event, 'title').trim().isEmpty) {
    throw const FormatException('Invalid assistant artifact');
  }
  final op = artifactTag(event, 'op');
  if (op != 'create' && op != 'update') {
    throw const FormatException('Invalid assistant revision');
  }
  if (op == 'update' &&
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(artifactTag(event, 'prev'))) {
    throw const FormatException('Invalid assistant predecessor');
  }
}

class AssistantSource {
  final String label;
  final Uri? url;
  final int? checkedAt;
  const AssistantSource(this.label, this.url, this.checkedAt);

  factory AssistantSource.decode(dynamic raw) {
    final value = raw as Map<String, dynamic>;
    final label = value['label'] as String;
    final url = value['url'] == null ? null : Uri.parse(value['url'] as String);
    final checkedAt = value['checkedAt'] as int?;
    if (label.trim().isEmpty ||
        (url != null &&
            (!['http', 'https'].contains(url.scheme) || url.host.isEmpty)) ||
        (checkedAt != null && checkedAt < 0)) {
      throw const FormatException('Invalid assistant evidence');
    }
    return AssistantSource(label, url, checkedAt);
  }
}

class AssistantItem {
  final NostrEvent event;
  final String id;
  final String channelId;
  final String type;
  final String title;
  final String summary;
  final String body;
  final String? topic;
  final bool important;
  final bool requiresInput;
  final List<AssistantSource> sources;

  AssistantItem._(
    this.event,
    this.id,
    this.channelId,
    this.type,
    this.title,
    this.summary,
    this.body,
    this.topic,
    this.important,
    this.requiresInput,
    this.sources,
  );

  factory AssistantItem.fromEvent(NostrEvent event) {
    validateAssistantEnvelope(event);
    final type = artifactTag(event, 'type');
    final value = jsonDecode(event.content) as Map<String, dynamic>;
    if (!assistantItemTypes.contains(type) ||
        value['version'] != 1 ||
        !['normal', 'important'].contains(value['priority'])) {
      throw const FormatException('Unsupported assistant item');
    }
    return AssistantItem._(
      event,
      artifactTag(event, 'd'),
      artifactTag(event, 'h'),
      type,
      artifactTag(event, 'title'),
      value['summary'] as String,
      value['body'] as String,
      value['topic'] as String?,
      value['priority'] == 'important',
      value['requiresInput'] as bool,
      (value['sources'] as List).map(AssistantSource.decode).toList(),
    );
  }
}

class AssistantItemState {
  final String status;
  final bool saved;
  final int? snoozedUntil;
  const AssistantItemState({
    this.status = 'open',
    this.saved = false,
    this.snoozedUntil,
  });

  factory AssistantItemState.decode(String content) {
    final value = jsonDecode(content) as Map<String, dynamic>;
    final status = value['status'] as String;
    final saved = value['saved'] as bool;
    final until = value['snoozedUntil'] as int?;
    if (value['version'] != 1 ||
        !['open', 'snoozed', 'archived'].contains(status) ||
        (status == 'snoozed' && (until == null || until <= 0)) ||
        (status != 'snoozed' && until != null)) {
      throw const FormatException('Invalid assistant attention state');
    }
    return AssistantItemState(
      status: status,
      saved: saved,
      snoozedUntil: until,
    );
  }

  factory AssistantItemState.fromEvent(
    NostrEvent event,
    String owner,
    AssistantItem item,
  ) {
    validateAssistantEnvelope(event);
    if (event.pubkey != owner ||
        artifactTag(event, 'owner') != owner ||
        artifactTag(event, 'item') != item.id ||
        artifactTag(event, 'type') != 'assistant.state' ||
        artifactTag(event, 'd') != assistantStateId(owner, item.id) ||
        artifactTag(event, 'h') != item.channelId) {
      throw const FormatException('Assistant state identity mismatch');
    }
    return AssistantItemState.decode(event.content);
  }

  bool visibleAt(int now) =>
      status != 'archived' && (status != 'snoozed' || snoozedUntil! <= now);

  String encode() => jsonEncode({
    'version': 1,
    'status': status,
    'saved': saved,
    if (snoozedUntil != null) 'snoozedUntil': snoozedUntil,
  });
}
