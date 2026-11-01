import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/assistant/assistant_item.dart';
import '../../shared/assistant/assistant_provider.dart';
import '../../shared/me/me_sync.dart';
import '../../shared/theme/theme.dart';

class AssistantItemPage extends ConsumerWidget {
  const AssistantItemPage({
    required this.item,
    required this.scopeKey,
    required this.onConversation,
    super.key,
  });
  final AssistantItem item;
  final String scopeKey;
  final Future<void> Function(BuildContext, AssistantItem) onConversation;

  Future<void> _openLink(BuildContext context, Uri uri) async {
    if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty) return;
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Surface unsupported external links without losing the report.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t open this source.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(meSyncProvider);
    if (scopeKey != '${sync.community}:${sync.pubkey}') {
      return Scaffold(
        appBar: AppBar(title: const Text('Assistant item')),
        body: const Padding(
          padding: EdgeInsets.all(Grid.gutter),
          child: Text(
            'Your account or community changed. Return to Today to open an item from this account.',
          ),
        ),
      );
    }
    final feed = ref.watch(assistantFeedProvider);
    final current =
        feed.items.where((entry) => entry.id == item.id).firstOrNull ?? item;
    final attention = feed.stateFor(item.id);
    final pending = feed.pending[item.id];
    final busy = feed.writing.isNotEmpty;
    final canChange =
        !busy && pending == null && feed.stateLoaded.contains(item.id);
    final actions = ref.read(assistantFeedProvider.notifier);
    void change(AssistantItemState value) {
      actions.change(
        current,
        value,
        baseRevision: feed.stateRevisions[item.id],
      );
    }

    Widget markdown(String text) => GptMarkdown(
      text,
      style: context.textTheme.bodyLarge,
      autolink: false,
      linkBuilder: (context, text, url, style) {
        final uri = Uri.tryParse(url);
        final safe =
            uri != null &&
            ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty;
        return InkWell(
          onTap: safe ? () => _openLink(context, uri) : null,
          child: Text.rich(text, style: style),
        );
      },
      // Reports may link evidence, but never load arbitrary remote images silently.
      imageBuilder: (context, url, _, _) => Text('Image: $url'),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          current.type == 'assistant.report' ? 'Report' : 'Assistant update',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Grid.gutter),
        children: [
          Text(current.title, style: context.textTheme.headlineSmall),
          const SizedBox(height: Grid.xs),
          Text(
            DateFormat.yMMMd().add_jm().format(
              DateTime.fromMillisecondsSinceEpoch(
                current.event.createdAt * 1000,
              ),
            ),
          ),
          if (current.topic != null) Text(current.topic!),
          if (current.requiresInput)
            const Chip(label: Text('Needs your input')),
          if (feed.cached)
            const Text('Offline copy. Refresh Today to check for changes.'),
          if (current.summary.isNotEmpty) ...[
            const SizedBox(height: Grid.md),
            markdown(current.summary),
          ],
          if (current.body.isNotEmpty) ...[
            const SizedBox(height: Grid.md),
            markdown(current.body),
          ],
          const SizedBox(height: Grid.md),
          Text('Evidence', style: context.textTheme.titleMedium),
          if (current.sources.isEmpty)
            const Text('No evidence sources supplied.'),
          for (final source in current.sources)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(source.label),
              subtitle: Text(
                [
                  if (source.url != null) source.url.toString(),
                  if (source.checkedAt != null)
                    'Checked ${DateFormat.yMMMd().add_jm().format(DateTime.fromMillisecondsSinceEpoch(source.checkedAt! * 1000))}',
                ].join('\n'),
              ),
              trailing: source.url == null
                  ? null
                  : const Icon(Icons.open_in_new),
              onTap: source.url == null
                  ? null
                  : () => _openLink(context, source.url!),
            ),
          const SizedBox(height: Grid.md),
          FilledButton.icon(
            onPressed: busy ? null : () => onConversation(context, current),
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Open conversation'),
          ),
          const SizedBox(height: Grid.xs),
          Wrap(
            spacing: Grid.xs,
            runSpacing: Grid.xs,
            children: [
              OutlinedButton.icon(
                onPressed: !canChange
                    ? null
                    : () => change(
                        AssistantItemState(
                          status: attention.status,
                          saved: !attention.saved,
                          snoozedUntil: attention.snoozedUntil,
                        ),
                      ),
                icon: Icon(
                  attention.saved ? Icons.bookmark : Icons.bookmark_outline,
                ),
                label: Text(attention.saved ? 'Unsave' : 'Save'),
              ),
              OutlinedButton(
                onPressed: !canChange
                    ? null
                    : () => change(
                        AssistantItemState(
                          status: attention.status == 'archived'
                              ? 'open'
                              : 'archived',
                          saved: attention.saved,
                        ),
                      ),
                child: Text(
                  attention.status == 'archived' ? 'Restore' : 'Archive',
                ),
              ),
              OutlinedButton(
                onPressed: !canChange
                    ? null
                    : () => change(
                        AssistantItemState(
                          status: 'snoozed',
                          saved: attention.saved,
                          snoozedUntil:
                              DateTime.now()
                                  .add(const Duration(hours: 24))
                                  .millisecondsSinceEpoch ~/
                              1000,
                        ),
                      ),
                child: const Text('Snooze 24 hours'),
              ),
              if (attention.status == 'snoozed')
                OutlinedButton(
                  onPressed: !canChange
                      ? null
                      : () =>
                            change(AssistantItemState(saved: attention.saved)),
                  child: const Text('Show now'),
                ),
            ],
          ),
          if (attention.status == 'snoozed')
            Text(
              'Snoozed until ${DateFormat.yMMMd().add_jm().format(DateTime.fromMillisecondsSinceEpoch(attention.snoozedUntil! * 1000))}',
            ),
          if (busy) const LinearProgressIndicator(),
          if (pending != null)
            Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pending choice: ${pending.desired.status}${pending.desired.saved ? ', saved' : ', not saved'}. This choice remains bound to the revision you originally saw.',
                  ),
                  const Text(
                    'Retry only confirms or resends that original choice. A newer device revision is never overwritten. Review the latest state, then discard this choice to make a different one.',
                  ),
                  TextButton(
                    onPressed: busy ? null : () => actions.retry(current),
                    child: const Text('Retry original choice'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => actions.reviewState(current),
                    child: const Text('Review latest state'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final discard = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text(
                                  'Discard this pending choice?',
                                ),
                                content: const Text(
                                  'Only the unconfirmed choice on this phone is removed. Any attention changes already accepted by the relay are kept. The latest state will be read before clearing the choice.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Keep pending'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Discard choice'),
                                  ),
                                ],
                              ),
                            );
                            if (discard == true &&
                                context.mounted &&
                                ref.read(meSyncProvider) == sync) {
                              await actions.discardPending(current);
                            }
                          },
                    child: const Text('Discard pending choice'),
                  ),
                ],
              ),
            ),
          if (!feed.stateLoaded.contains(item.id))
            TextButton(
              onPressed: busy ? null : () => actions.reviewState(current),
              child: const Text('Load attention state'),
            ),
          if (feed.error != null) Text(feed.error!),
          const SizedBox(height: Grid.md),
          const Text(
            'Saving, snoozing and archiving organize your attention. They do not authorize or run actions.',
          ),
        ],
      ),
    );
  }
}
