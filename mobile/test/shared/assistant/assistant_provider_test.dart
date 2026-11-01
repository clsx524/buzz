import 'dart:async';
import 'dart:convert';

import 'package:buzz/shared/assistant/assistant_item.dart';
import 'package:buzz/shared/assistant/assistant_provider.dart';
import 'package:buzz/shared/me/me_sync.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

class _Lifecycle extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;
}

class _Transport {
  final NostrEvent item;
  NostrEvent? head;
  var publications = 0;
  var loseAcknowledgement = false;
  late NostrEvent currentItem = item;
  bool itemDeleted = false;
  void Function(NostrEvent)? liveEvent;
  void Function(String)? liveClosed;
  void Function(RelaySubscriptionStatus)? liveStatus;
  int subscriptions = 0;
  int cancellations = 0;
  int currentReads = 0;
  int activeReads = 0;
  int maxActiveReads = 0;
  Future<void> Function()? beforeCurrentRead;
  _Transport(this.item);
}

class _Relay extends RelaySessionNotifier {
  final _Transport transport;
  _Relay(this.transport);
  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);
  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final filter = filters.single;
    // Model the artifact endpoint's actual accepted predicate grammar. An
    // unsupported ordinary Nostr predicate must reject the consumer's request,
    // rather than silently succeeding at this external boundary.
    final unsupported = filter.toJson().keys.where(
      (key) =>
          !{'artifact', 'kinds', 'limit', 'offset'}.contains(key) &&
          !key.startsWith('#'),
    );
    if (unsupported.isNotEmpty) {
      throw FormatException(
        'Unsupported artifact predicate: ${unsupported.first}',
      );
    }
    expect(filter.extensions['artifact'], isIn(['current', 'head']));
    if (filter.extensions['artifact'] == 'head') {
      return transport.head == null ? [] : [transport.head!];
    }
    if (filter.tags['#type']!.contains('assistant.state')) {
      return transport.head == null ? [] : [transport.head!];
    }
    expect(filter.extensions['offset'], 0);
    transport.currentReads++;
    transport.activeReads++;
    if (transport.activeReads > transport.maxActiveReads) {
      transport.maxActiveReads = transport.activeReads;
    }
    try {
      await transport.beforeCurrentRead?.call();
      return transport.itemDeleted ? [] : [transport.currentItem];
    } finally {
      transport.activeReads--;
    }
  }

  @override
  Future<NostrEvent> publish(
    NostrEvent event, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    transport.publications++;
    if (event.getTagValue('prev') != transport.head?.id) {
      throw StateError('Relay revision conflict');
    }
    transport.head = event;
    if (transport.loseAcknowledgement) {
      throw TimeoutException('Relay accepted but acknowledgement was lost');
    }
    return event;
  }

  @override
  Future<void Function()> subscribeWithStatus(
    NostrFilter filter,
    void Function(NostrEvent) onEvent, {
    void Function(String message)? onClosed,
    required void Function(RelaySubscriptionStatus status) onStatusChanged,
  }) async {
    expect(filter.kinds, [45010, 45011]);
    expect(filter.limit, 0);
    expect(
      filter.tags,
      isEmpty,
      reason: 'Never use multi-character artifact tags in generic REQ filters',
    );
    transport.subscriptions++;
    transport.liveEvent = onEvent;
    transport.liveClosed = onClosed;
    transport.liveStatus = onStatusChanged;
    return () {
      transport.cancellations++;
      if (identical(transport.liveEvent, onEvent)) transport.liveEvent = null;
    };
  }
}

NostrEvent _finding(
  nostr.Keys owner, {
  String body = 'Details',
  NostrEvent? previous,
}) => NostrEvent.fromJson(
  nostr.Event.from(
    kind: assistantArtifactKind,
    secretKey: owner.secret,
    createdAt: 1,
    tags: [
      ['ar', '1'],
      ['d', '22222222-2222-4222-8222-222222222222'],
      ['h', '33333333-3333-4333-8333-333333333333'],
      ['type', 'assistant.finding'],
      ['title', 'Check source'],
      ['op', previous == null ? 'create' : 'update'],
      if (previous != null) ['prev', previous.id],
    ],
    content: jsonEncode({
      'version': 1,
      'summary': '',
      'body': body,
      'priority': 'normal',
      'requiresInput': true,
      'sources': [],
    }),
  ).toMap(),
);

NostrEvent _attention(
  nostr.Keys owner,
  AssistantItem item,
  AssistantItemState value, {
  NostrEvent? previous,
}) => NostrEvent.fromJson(
  nostr.Event.from(
    kind: assistantArtifactKind,
    secretKey: owner.secret,
    createdAt: 2,
    tags: [
      ['ar', '1'],
      ['d', assistantStateId(owner.public, item.id)],
      ['h', item.channelId],
      ['type', 'assistant.state'],
      ['title', 'Assistant item state'],
      ['op', previous == null ? 'create' : 'update'],
      if (previous != null) ['prev', previous.id],
      ['owner', owner.public],
      ['item', item.id],
    ],
    content: value.encode(),
  ).toMap(),
);

ProviderContainer _container(
  nostr.Keys owner,
  _Transport transport,
  SharedPreferences prefs,
) {
  final relay = _Relay(transport);
  return ProviderContainer(
    overrides: [
      relaySessionProvider.overrideWith(() => relay),
      appLifecycleProvider.overrideWith(_Lifecycle.new),
      meSyncProvider.overrideWithValue(
        MeSync(
          relay,
          RelayConfig(baseUrl: 'https://relay.test', nsec: owner.nsec),
          prefs: prefs,
        ),
      ),
    ],
  );
}

Future<void> _loaded(ProviderContainer container) async {
  final ready = Completer<void>();
  final subscription = container.listen(assistantFeedProvider, (_, next) {
    if (!next.loading && !ready.isCompleted) ready.complete();
  }, fireImmediately: true);
  await ready.future.timeout(const Duration(seconds: 10));
  subscription.close();
}

void main() {
  test(
    'stale consumer save cannot unarchive remote state; review and discard allow an explicit new choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final owner = nostr.Keys.generate();
      final transport = _Transport(_finding(owner));
      final item = AssistantItem.fromEvent(transport.item);
      transport.head = _attention(owner, item, const AssistantItemState());
      final container = _container(owner, transport, prefs);
      addTearDown(container.dispose);
      await _loaded(container);
      final rendered = container.read(assistantFeedProvider);
      final baseRevision = rendered.stateRevisions[item.id];
      final renderedState = rendered.stateFor(item.id);
      final remoteArchive = _attention(
        owner,
        item,
        const AssistantItemState(status: 'archived'),
        previous: transport.head,
      );
      transport.head = remoteArchive;
      final actions = container.read(assistantFeedProvider.notifier);
      await actions.change(
        item,
        AssistantItemState(status: renderedState.status, saved: true),
        baseRevision: baseRevision,
      );
      expect(transport.publications, 0);
      expect(transport.head?.id, remoteArchive.id);
      expect(
        container.read(assistantFeedProvider).stateFor(item.id).status,
        'archived',
      );
      final originalIntent = container
          .read(assistantFeedProvider)
          .pending[item.id]!;
      expect(originalIntent.baseRevision, baseRevision);
      expect(originalIntent.desired.status, 'open');
      expect(container.read(assistantFeedProvider).error, contains('Conflict'));
      await actions.reviewState(item);
      await actions.retry(item);
      expect(
        transport.publications,
        0,
        reason: 'Review must not rebase the pending choice',
      );
      expect(
        container.read(assistantFeedProvider).pending[item.id]?.event.id,
        originalIntent.event.id,
      );
      await actions.discardPending(item);
      final reviewed = container.read(assistantFeedProvider);
      expect(reviewed.pending, isEmpty);
      expect(reviewed.stateFor(item.id).status, 'archived');
      await actions.change(
        item,
        AssistantItemState(
          status: reviewed.stateFor(item.id).status,
          saved: true,
        ),
        baseRevision: reviewed.stateRevisions[item.id],
      );
      expect(transport.publications, 1);
      expect(
        container.read(assistantFeedProvider).stateFor(item.id).status,
        'archived',
      );
      expect(
        container.read(assistantFeedProvider).stateFor(item.id).saved,
        isTrue,
      );
    },
  );

  for (final superseded in [false, true]) {
    test(
      'unknown acceptance survives restart and ${superseded ? 'cannot overwrite a subsequent remote archive' : 'reconciles the exact original write'}',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final owner = nostr.Keys.generate();
        final transport = _Transport(_finding(owner))
          ..loseAcknowledgement = true;
        var container = _container(owner, transport, prefs);
        await _loaded(container);
        final rendered = container.read(assistantFeedProvider);
        final item = rendered.items.single;
        const desired = AssistantItemState(saved: true);
        await container
            .read(assistantFeedProvider.notifier)
            .change(
              item,
              desired,
              baseRevision: rendered.stateRevisions[item.id],
            );
        final unconfirmed = container.read(assistantFeedProvider);
        final originalIntent = unconfirmed.pending[item.id]!;
        expect(originalIntent.desired.saved, isTrue);
        expect(originalIntent.baseRevision, isNull);
        expect(unconfirmed.stateFor(item.id).saved, isFalse);
        expect(unconfirmed.error, contains('unconfirmed'));
        expect(transport.publications, 1);
        expect(transport.head?.id, originalIntent.event.id);
        container.dispose();
        if (superseded) {
          transport.head = _attention(
            owner,
            item,
            const AssistantItemState(status: 'archived', saved: true),
            previous: transport.head,
          );
        }
        final remoteRevision = transport.head!.id;
        await prefs.reload();
        container = _container(owner, transport, prefs);
        addTearDown(container.dispose);
        await _loaded(container);
        final restored = container
            .read(assistantFeedProvider)
            .pending[item.id]!;
        expect(restored.event.id, originalIntent.event.id);
        expect(restored.baseRevision, isNull);
        await container.read(assistantFeedProvider.notifier).retry(item);
        expect(
          transport.publications,
          1,
          reason: 'Retry never publishes a rebased full snapshot',
        );
        expect(transport.head?.id, remoteRevision);
        if (superseded) {
          expect(
            container.read(assistantFeedProvider).pending[item.id]?.event.id,
            originalIntent.event.id,
          );
          expect(
            container.read(assistantFeedProvider).stateFor(item.id).status,
            'archived',
          );
          expect(
            container.read(assistantFeedProvider).error,
            contains('Conflict'),
          );
        } else {
          expect(container.read(assistantFeedProvider).pending, isEmpty);
          expect(
            container.read(assistantFeedProvider).stateFor(item.id).saved,
            isTrue,
          );
        }
      },
    );
  }
  test(
    'live revisions invalidate current pages, debounce bursts, serialize refreshes and cancel with scope',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final owner = nostr.Keys.generate();
      final transport = _Transport(_finding(owner));
      final container = _container(owner, transport, prefs);
      await _loaded(container);
      expect(transport.subscriptions, 1);
      final live = transport.liveEvent!;
      final revised = _finding(
        owner,
        body: 'Authoritative revised finding',
        previous: transport.item,
      );
      final started = Completer<void>();
      final release = Completer<void>();
      transport.beforeCurrentRead = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      for (var i = 0; i < 20; i++) {
        live(revised);
      }
      await started.future.timeout(const Duration(seconds: 10));
      expect(
        transport.currentReads,
        2,
        reason: 'A burst must debounce into one HTTP refresh',
      );
      expect(
        container.read(assistantFeedProvider).items.single.body,
        'Details',
        reason:
            'A live revision is never treated as an authoritative current head',
      );
      final actions = container.read(assistantFeedProvider.notifier);
      final refreshing = actions.refresh();
      actions.refresh();
      transport.currentItem = revised;
      release.complete();
      await refreshing;
      expect(
        transport.currentReads,
        3,
        reason: 'In-flight invalidations coalesce into one queued refresh',
      );
      expect(transport.maxActiveReads, 1);
      expect(
        container.read(assistantFeedProvider).items.single.body,
        'Authoritative revised finding',
      );
      transport.beforeCurrentRead = null;
      final deleted = Completer<void>();
      final listener = container.listen(assistantFeedProvider, (_, next) {
        if (!next.loading && next.items.isEmpty && !deleted.isCompleted) {
          deleted.complete();
        }
      });
      transport.itemDeleted = true;
      live(
        NostrEvent.fromJson(
          nostr.Event.from(
            kind: 45011,
            secretKey: owner.secret,
            createdAt: 3,
            tags: [
              ['h', '33333333-3333-4333-8333-333333333333'],
            ],
            content: '',
          ).toMap(),
        ),
      );
      await deleted.future.timeout(const Duration(seconds: 10));
      listener.close();
      expect(container.read(assistantFeedProvider).items, isEmpty);
      transport.liveClosed!('Subscription closed');
      expect(
        container.read(assistantFeedProvider).liveError,
        contains('unavailable'),
      );
      await actions.retryLiveUpdates();
      expect(transport.subscriptions, 2);
      transport.liveStatus!(RelaySubscriptionStatus.ready);
      expect(container.read(assistantFeedProvider).liveError, isNull);
      container.dispose();
      expect(transport.cancellations, 2);
      live(
        revised,
      ); // A late retired-scope signal cannot schedule another query.
      expect(transport.liveEvent, isNull);
    },
  );
}
