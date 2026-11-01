import '../relay/nostr_models.dart';
import 'assistant_item.dart';

/// One reviewed change, bound permanently to the revision the user saw. The
/// signed event is retained across unknown acknowledgements and process restarts.
class AssistantStateChange {
  final String? baseRevision;
  final NostrEvent event;
  const AssistantStateChange({required this.baseRevision, required this.event});

  AssistantItemState get desired => AssistantItemState.decode(event.content);

  factory AssistantStateChange.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1) {
      throw const FormatException('Unsupported pending attention change');
    }
    final base = value['baseRevision'] as String?;
    final event = NostrEvent.fromJson(value['event'] as Map<String, dynamic>);
    validateAssistantEnvelope(event);
    if ((base != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(base)) ||
        artifactTag(event, 'op') != (base == null ? 'create' : 'update') ||
        (base != null && artifactTag(event, 'prev') != base) ||
        (base == null &&
            event.tags.any((tag) => tag.isNotEmpty && tag[0] == 'prev'))) {
      throw const FormatException('Invalid pending attention revision');
    }
    AssistantItemState.decode(event.content);
    return AssistantStateChange(baseRevision: base, event: event);
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'baseRevision': baseRevision,
    'event': event.toJson(),
  };
}
