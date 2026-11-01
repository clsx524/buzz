import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/assistant/assistant_item.dart';
import '../../shared/assistant/assistant_provider.dart';
import '../../shared/me/me_sync.dart';
import '../../shared/theme/theme.dart';
import 'assistant_item_page.dart';

class AssistantFeedPage extends HookConsumerWidget {
  const AssistantFeedPage({
    required this.library,
    required this.onConversation,
    super.key,
  });
  final bool library;
  final Future<void> Function(BuildContext, AssistantItem) onConversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(assistantFeedProvider);
    final sync = ref.watch(meSyncProvider);
    final filter = useState('For you');
    final clock = useState(0);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    useEffect(() {
      final deadlines =
          feed.attention.values
              .where(
                (value) =>
                    value.status == 'snoozed' && value.snoozedUntil! > now,
              )
              .map((value) => value.snoozedUntil!)
              .toList()
            ..sort();
      if (library || deadlines.isEmpty) return null;
      final timer = Timer(
        Duration(
          milliseconds:
              deadlines.first * 1000 - DateTime.now().millisecondsSinceEpoch,
        ),
        () => clock.value++,
      );
      return timer.cancel;
    }, [feed.attention, clock.value]);
    final items =
        feed.items.where((item) {
          final attention = feed.stateFor(item.id);
          if (library) {
            return item.type == 'assistant.report' || attention.saved;
          }
          if (filter.value == 'Archived') return attention.status == 'archived';
          if (filter.value == 'Snoozed') {
            return attention.status == 'snoozed' && !attention.visibleAt(now);
          }
          return attention.visibleAt(now);
        }).toList()..sort((a, b) {
          if (!library && a.requiresInput != b.requiresInput) {
            return a.requiresInput ? -1 : 1;
          }
          if (a.important != b.important) return a.important ? -1 : 1;
          return b.event.createdAt.compareTo(a.event.createdAt);
        });
    final notifier = ref.read(assistantFeedProvider.notifier);
    return RefreshIndicator(
      onRefresh: notifier.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(Grid.gutter),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    library
                        ? 'Reports and saved findings'
                        : 'A little less to keep in your head.',
                    style: context.textTheme.titleLarge,
                  ),
                  const SizedBox(height: Grid.xs),
                  Text(
                    library
                        ? 'Durable reports stay here, even when archived.'
                        : 'Findings and updates published by your connected assistant. Opening an item does not resolve it.',
                  ),
                  if (!library)
                    Padding(
                      padding: const EdgeInsets.only(top: Grid.md),
                      child: Wrap(
                        spacing: Grid.xs,
                        children: [
                          for (final value in [
                            'For you',
                            'Snoozed',
                            'Archived',
                          ])
                            ChoiceChip(
                              label: Text(value),
                              labelStyle: filter.value == value
                                  ? context.textTheme.bodySmall?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onPrimary,
                                    )
                                  : null,
                              selected: filter.value == value,
                              onSelected: (_) => filter.value = value,
                            ),
                        ],
                      ),
                    ),
                  if (feed.cached)
                    const Padding(
                      padding: EdgeInsets.only(top: Grid.xs),
                      child: Text(
                        'Showing an offline copy; freshness is unconfirmed.',
                      ),
                    ),
                  if (feed.error != null)
                    Semantics(
                      liveRegion: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Couldn’t refresh assistant data. ${feed.error}',
                          ),
                          TextButton(
                            onPressed: feed.loading ? null : notifier.refresh,
                            child: const Text('Retry refresh'),
                          ),
                        ],
                      ),
                    ),
                  if (feed.liveError != null)
                    Semantics(
                      liveRegion: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(feed.liveError!),
                          TextButton(
                            onPressed: feed.writing.isNotEmpty
                                ? null
                                : notifier.retryLiveUpdates,
                            child: const Text('Retry live updates'),
                          ),
                        ],
                      ),
                    ),
                  if (feed.pending.isNotEmpty)
                    const Text(
                      'Some attention changes are unconfirmed. Open the affected item to retry.',
                    ),
                  if (feed.loading) const LinearProgressIndicator(),
                  if (!feed.loading && items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Grid.md),
                      child: Text(
                        library
                            ? 'No reports or saved findings in these loaded pages.'
                            : filter.value == 'For you'
                            ? 'Nothing needs your attention in these loaded pages.'
                            : 'No ${filter.value.toLowerCase()} items in these loaded pages.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final pending = feed.pending.containsKey(item.id);
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  Grid.gutter,
                  0,
                  Grid.gutter,
                  Grid.xs,
                ),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(Grid.md),
                    title: Text(
                      item.title,
                      style: context.textTheme.titleMedium,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: Grid.xxs),
                        Text(
                          [
                            if (item.requiresInput) 'Needs input',
                            if (item.important) 'Important',
                            item.type.split('.').last,
                            if (item.topic != null) item.topic!,
                          ].join(' · '),
                        ),
                        if (item.summary.isNotEmpty)
                          Text(
                            item.summary,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (pending) const Text('Change unconfirmed'),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AssistantItemPage(
                          item: item,
                          scopeKey: '${sync.community}:${sync.pubkey}',
                          onConversation: onConversation,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (feed.hasMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(Grid.gutter),
                child: OutlinedButton(
                  onPressed: feed.loading ? null : notifier.loadMore,
                  child: const Text('Load more'),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: Grid.gutter * 4)),
        ],
      ),
    );
  }
}
