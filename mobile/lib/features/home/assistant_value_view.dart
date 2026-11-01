import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Bounded readable evidence, preserving field labels and exact values.
class AssistantValueView extends StatelessWidget {
  const AssistantValueView(this.value, {this.depth = 0, super.key});
  final dynamic value;
  final int depth;
  @override
  Widget build(BuildContext context) {
    if (depth > 8) return SelectableText('$value');
    if (value is Map) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in (value as Map).entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.key}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  AssistantValueView(entry.value, depth: depth + 1),
                ],
              ),
            ),
        ],
      );
    }
    if (value is List) {
      final list = value as List;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < list.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AssistantValueView(list[i], depth: depth + 1),
            ),
          if (list.isEmpty) const Text('None'),
        ],
      );
    }
    final text = value == null ? 'Not available' : '$value';
    final uri = Uri.tryParse(text);
    if (uri != null &&
        ['https', 'http'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      return TextButton(
        onPressed: () async {
          try {
            if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
              throw StateError('No application can open this evidence link.');
            }
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('$error')));
            }
          }
        },
        child: Text(text),
      );
    }
    return SelectableText(text);
  }
}

String assistantTime(dynamic value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
    ).toLocal().toString();
  }
  return value == null ? 'Not available' : '$value';
}
