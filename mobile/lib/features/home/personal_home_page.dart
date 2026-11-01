import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/assistant/assistant_item.dart';
import '../../shared/me/default_agent.dart';
import '../../shared/me/me_assistants.dart';
import '../../shared/me/personal_assistant.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import 'assistant_controls_page.dart';
import 'assistant_feed_page.dart';

class PersonalHomePage extends HookConsumerWidget {
  const PersonalHomePage({
    required this.conversationsBuilder,
    required this.settingsPageBuilder,
    required this.onAgents,
    required this.onSearch,
    required this.onConversation,
    this.onControlConversation,
    super.key,
  });
  final Widget Function(
    BuildContext,
    ValueNotifier<VoidCallback?>,
    ValueNotifier<VoidCallback?>,
  )
  conversationsBuilder;
  final WidgetBuilder settingsPageBuilder;
  final ValueChanged<BuildContext> onAgents;
  final ValueChanged<BuildContext> onSearch;
  final Future<void> Function(BuildContext, AssistantItem) onConversation;
  final Future<void> Function(BuildContext, String, String?)? onControlConversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final destination = useState(0);
    final newChat = useValueNotifier<VoidCallback?>(null);
    final newProject = useValueNotifier<VoidCallback?>(null);
    useListenable(newChat);
    useListenable(newProject);
    final connection = ref.watch(relaySessionProvider.select((s) => s.status));
    final preference = ref.watch(defaultAgentProvider);
    final directory = ref.watch(meAssistantsProvider);
    final selected = ref.watch(personalAssistantProvider);
    final name = directory.value
        ?.where((entry) => entry.pubkey == selected)
        .firstOrNull
        ?.displayName;
    final status = connection == SessionStatus.connected
        ? 'Connected to your server'
        : 'Offline · showing saved updates';
    return Scaffold(
      appBar: AppBar(
        title: Text(['Today', 'Conversations', 'Library'][destination.value]),
        actions: [
          IconButton(
            tooltip: 'Search messages',
            onPressed: () => onSearch(context),
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<String>(
            tooltip: 'Assistant and settings',
            onSelected: (value) {
              if (value == 'controls') {
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => AssistantControlsPage(onConversation: onControlConversation),
                ));
              }
              if (value == 'agents') onAgents(context);
              if (value == 'settings') {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: settingsPageBuilder));
              }
              if (value == 'project') newProject.value?.call();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'controls',
                child: Text('Monitors, findings and questions'),
              ),
              const PopupMenuItem(
                value: 'agents',
                child: Text('Choose assistant'),
              ),
              if (destination.value == 1)
                PopupMenuItem(
                  value: 'project',
                  enabled: newProject.value != null,
                  child: const Text('New topic / project'),
                ),
              const PopupMenuItem(
                value: 'settings',
                child: Text('Settings and communities'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Grid.gutter,
              vertical: Grid.xs,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preference.hasError || directory.hasError
                        ? 'Couldn’t load your assistant'
                        : preference.isLoading || directory.isLoading
                        ? 'Loading your assistant…'
                        : selected == null
                        ? 'Choose an assistant to start a chat'
                        : 'Assistant: ${name ?? selected}',
                    style: context.textTheme.labelLarge,
                  ),
                  Text(status, style: context.textTheme.bodySmall),
                  if (preference.hasError || directory.hasError)
                    TextButton(
                      onPressed: () {
                        ref.invalidate(defaultAgentProvider);
                        ref.invalidate(meAssistantsProvider);
                      },
                      child: const Text('Try again'),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: destination.value,
              children: [
                AssistantFeedPage(
                  library: false,
                  onConversation: onConversation,
                ),
                CustomScrollView(
                  slivers: [conversationsBuilder(context, newChat, newProject)],
                ),
                AssistantFeedPage(
                  library: true,
                  onConversation: onConversation,
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: 'Start a private conversation',
        onPressed: newChat.value,
        icon: const Icon(Icons.chat_bubble_outline),
        label: Text(destination.value == 1 ? 'New chat' : 'Ask your assistant'),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: destination.value,
        onDestinationSelected: (index) => destination.value = index,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Conversations',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmarks_outlined),
            selectedIcon: Icon(Icons.bookmarks),
            label: 'Library',
          ),
        ],
      ),
    );
  }
}
