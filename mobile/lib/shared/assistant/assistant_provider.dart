import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../crypto/event_signing.dart';
import '../crypto/nip44.dart';
import '../me/me_sync.dart';
import '../relay/relay.dart';
import 'assistant_item.dart';
import 'assistant_cache.dart';
import 'assistant_state_change.dart';

class AssistantFeed {
  final List<AssistantItem> items;
  final Map<String, AssistantItemState> attention;
  final Map<String, AssistantStateChange> pending;
  final Map<String, String> stateRevisions;
  final Set<String> stateLoaded;
  final Set<String> writing;
  final bool loading;
  final bool hasMore;
  final bool cached;
  final String? error;
  final String? liveError;
  const AssistantFeed({
    this.items = const [],
    this.attention = const {},
    this.pending = const {},
    this.stateRevisions = const {},
    this.stateLoaded = const {},
    this.writing = const {},
    this.loading = true,
    this.hasMore = false,
    this.cached = false,
    this.error,
    this.liveError,
  });
  AssistantItemState stateFor(String id) =>
      attention[id] ?? const AssistantItemState();
}

final assistantFeedProvider =
    NotifierProvider<AssistantFeedNotifier, AssistantFeed>(
      AssistantFeedNotifier.new,
    );

/// Reads relay-authoritative current pages, not reconstructed revision history.
/// Unconfirmed attention changes are encrypted locally and require explicit retry.
class AssistantFeedNotifier extends Notifier<AssistantFeed> {
  late MeSync _sync;
  int _offset = 0;
  int _generation = 0;
  List<NostrEvent> _events = [];
  Map<String, NostrEvent> _stateEvents = {};
  Future<void>? _inFlightLoad;
  bool _refreshQueued = false;
  Future<void> Function()? _retryLive;
  String get _cacheKey => 'assistant-cache:${_sync.community}:${_sync.pubkey}';
  String get _pendingKey =>
      'assistant-pending:${_sync.community}:${_sync.pubkey}';

  @override
  AssistantFeed build() {
    _sync = ref.watch(meSyncProvider);
    _generation++;
    _offset = 0;
    _events = [];
    _stateEvents = {};
    _inFlightLoad = null;
    _refreshQueued = false;
    final pending = <String, AssistantStateChange>{};
    var initial = const AssistantFeed();
    try {
      final raw = _sync.prefs?.getString(_pendingKey);
      if (raw != null) {
        final values =
            jsonDecode(nip44Decrypt(_sync.key, raw)) as Map<String, dynamic>;
        for (final entry in values.entries) {
          pending[entry.key] = AssistantStateChange.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
      }
      final cached = _sync.prefs?.getString(_cacheKey);
      if (cached != null) {
        final value =
            jsonDecode(decodeAssistantCache(_sync.key, cached))
                as Map<String, dynamic>;
        _events = (value['items'] as List)
            .map(
              (e) => NostrEvent.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        final items = _events.map(AssistantItem.fromEvent).toList();
        final states = <String, AssistantItemState>{};
        for (final raw in value['states'] as List) {
          final event = NostrEvent.fromJson(
            Map<String, dynamic>.from(raw as Map),
          );
          final item = items
              .where((item) => item.id == event.getTagValue('item'))
              .firstOrNull;
          if (item == null) continue;
          states[item.id] = AssistantItemState.fromEvent(
            event,
            _sync.pubkey,
            item,
          );
          _stateEvents[item.id] = event;
        }
        initial = AssistantFeed(
          items: items,
          attention: states,
          cached: true,
          stateRevisions: _stateEvents.map(
            (id, event) => MapEntry(id, event.id),
          ),
          stateLoaded: items.map((item) => item.id).toSet(),
        );
      }
      initial = AssistantFeed(
        items: initial.items,
        attention: initial.attention,
        cached: initial.cached,
        pending: pending,
        stateRevisions: initial.stateRevisions,
        stateLoaded: initial.stateLoaded,
      );
    } catch (_) {
      initial = AssistantFeed(
        pending: pending,
        error: 'Couldn’t read offline assistant data. Refresh to recover.',
      );
    }
    final sync = _sync;
    var disposed = false;
    var starting = false;
    var closed = false;
    var liveEpoch = 0;
    void Function()? unsubscribe;
    Timer? debounce;
    void signalRefresh() {
      if (disposed || sync != _sync) return;
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 250), () {
        if (!disposed && ref.mounted && sync == _sync) unawaited(refresh());
      });
    }

    void liveFailed(String message) {
      if (disposed || sync != _sync) return;
      closed = true;
      unsubscribe?.call();
      unsubscribe = null;
      _set(liveError: 'Live assistant updates unavailable. $message');
    }

    Future<void> startLive({bool force = false}) async {
      if (disposed || sync != _sync) return;
      if (force) {
        liveEpoch++;
        unsubscribe?.call();
        unsubscribe = null;
        starting = false;
      }
      if (starting || unsubscribe != null) return;
      final epoch = ++liveEpoch;
      starting = true;
      closed = false;
      try {
        final cancel = await sync.session.subscribeWithStatus(
          const NostrFilter(kinds: [assistantArtifactKind, 45011], limit: 0),
          (event) {
            if (disposed || epoch != liveEpoch || sync != _sync) return;
            if (event.kind == 45011 ||
                (event.kind == assistantArtifactKind &&
                    (assistantItemTypes.contains(event.getTagValue('type')) ||
                        (event.getTagValue('type') == 'assistant.state' &&
                            event.pubkey == sync.pubkey)))) {
              // Revisions are signals only; the HTTP current endpoint owns heads.
              signalRefresh();
            }
          },
          onClosed: (message) {
            if (epoch == liveEpoch) liveFailed(message);
          },
          onStatusChanged: (status) {
            if (disposed || epoch != liveEpoch || sync != _sync) return;
            if (status == RelaySubscriptionStatus.ready) {
              _set(clearLiveError: true);
              signalRefresh();
            } else {
              _set(
                liveError:
                    'Live assistant updates reconnecting. Pull to refresh while the stream recovers.',
              );
            }
          },
        );
        if (disposed || closed || epoch != liveEpoch || sync != _sync) {
          cancel();
        } else {
          unsubscribe = cancel;
        }
      } catch (error) {
        if (epoch == liveEpoch) liveFailed(error.toString());
      } finally {
        if (epoch == liveEpoch) starting = false;
      }
    }

    _retryLive = () => startLive(force: true);
    ref.onDispose(() {
      disposed = true;
      debounce?.cancel();
      unsubscribe?.call();
    });
    scheduleMicrotask(() {
      if (!disposed && ref.mounted && sync == _sync) {
        unawaited(refresh());
        unawaited(startLive());
      }
    });
    ref.listen(relaySessionProvider.select((s) => s.status), (before, after) {
      if (before != after && after == SessionStatus.connected) {
        unawaited(refresh());
        unawaited(startLive());
      }
    });
    ref.listen(appLifecycleProvider, (_, next) {
      if (next == AppLifecycleState.resumed) {
        unawaited(refresh());
        if (closed) unawaited(startLive());
      }
    });
    return initial;
  }

  void _set({
    List<AssistantItem>? items,
    Map<String, AssistantItemState>? attention,
    Map<String, AssistantStateChange>? pending,
    Set<String>? writing,
    Map<String, String>? stateRevisions,
    Set<String>? stateLoaded,
    bool? loading,
    bool? hasMore,
    bool? cached,
    String? error,
    String? liveError,
    bool clearLiveError = false,
  }) {
    state = AssistantFeed(
      items: items ?? state.items,
      attention: attention ?? state.attention,
      pending: pending ?? state.pending,
      writing: writing ?? state.writing,
      loading: loading ?? state.loading,
      stateRevisions: stateRevisions ?? state.stateRevisions,
      stateLoaded: stateLoaded ?? state.stateLoaded,
      liveError: clearLiveError ? null : liveError ?? state.liveError,
      hasMore: hasMore ?? state.hasMore,
      cached: cached ?? state.cached,
      error: error,
    );
  }

  Future<List<NostrEvent>> _query(NostrFilter filter) async {
    final sync = _sync;
    sync.check();
    final events = await sync.session.queryRelay([filter]);
    sync.check();
    if (events.length > filter.limit) {
      throw StateError('Assistant query exceeded its page size.');
    }
    await Isolate.run(() {
      for (final event in events) {
        verifiedNostrEventFromJson(jsonEncode(event.toJson()));
      }
    });
    sync.check();
    return events;
  }

  Future<void> refresh() {
    final active = _inFlightLoad;
    if (active != null) {
      _refreshQueued = true;
      return active;
    }
    return _startLoad(reset: true);
  }

  Future<void> retryLiveUpdates() async {
    await _retryLive?.call();
  }

  Future<void> loadMore() => state.loading || !state.hasMore
      ? _inFlightLoad ?? Future.value()
      : _startLoad(reset: false);

  Future<void> _startLoad({required bool reset}) {
    final sync = _sync;
    Future<void> run() async {
      var firstPage = reset;
      do {
        _refreshQueued = false;
        await _loadPage(reset: firstPage);
        if (!ref.mounted || sync != _sync) return;
        firstPage = true;
      } while (_refreshQueued);
    }

    late final Future<void> operation;
    operation = run().whenComplete(() {
      if (sync == _sync && identical(_inFlightLoad, operation)) {
        _inFlightLoad = null;
      }
    });
    _inFlightLoad = operation;
    return operation;
  }

  Future<void> _loadPage({required bool reset}) async {
    final generation = ++_generation;
    final offset = reset ? 0 : _offset;
    _set(loading: true);
    try {
      final events = await _query(
        NostrFilter(
          kinds: const [assistantArtifactKind],
          tags: const {'#type': assistantItemTypes},
          extensions: {'artifact': 'current', 'offset': offset},
          limit: 100,
        ),
      );
      final page = events.map(AssistantItem.fromEvent).toList();
      final seen = <String>{};
      if (page.any((item) => !seen.add(item.id))) {
        throw StateError('Relay returned ambiguous assistant current items.');
      }
      final attention = reset
          ? <String, AssistantItemState>{}
          : {...state.attention};
      final stateEvents = reset ? <String, NostrEvent>{} : {..._stateEvents};
      if (page.isNotEmpty) {
        final snapshots = await _query(
          NostrFilter(
            kinds: const [assistantArtifactKind],
            tags: {
              '#type': ['assistant.state'],
              '#owner': [_sync.pubkey],
              '#d': [
                for (final item in page)
                  assistantStateId(_sync.pubkey, item.id),
              ],
            },
            extensions: const {'artifact': 'current', 'offset': 0},
            limit: 100,
          ),
        );
        final stateSeen = <String>{};
        for (final event in snapshots) {
          final item = page
              .where(
                (item) =>
                    assistantStateId(_sync.pubkey, item.id) ==
                    event.getTagValue('d'),
              )
              .firstOrNull;
          if (item == null || !stateSeen.add(item.id)) {
            throw StateError('Relay returned an unexpected assistant state.');
          }
          attention[item.id] = AssistantItemState.fromEvent(
            event,
            _sync.pubkey,
            item,
          );
          stateEvents[item.id] = event;
        }
      }
      if (!ref.mounted || generation != _generation) return;
      final merged = <String, AssistantItem>{
        if (!reset)
          for (final item in state.items) item.id: item,
        for (final item in page) item.id: item,
      };
      _events = merged.values.map((item) => item.event).toList();
      _stateEvents = stateEvents;
      _offset = offset + events.length;
      _set(
        items: merged.values.toList(),
        attention: attention,
        stateRevisions: stateEvents.map((id, event) => MapEntry(id, event.id)),
        stateLoaded: {
          if (!reset) ...state.stateLoaded,
          ...page.map((item) => item.id),
        },
        loading: false,
        cached: false,
        hasMore: events.length == 100,
      );
      final prefs = _sync.prefs;
      if (prefs != null &&
          !await prefs.setString(
            _cacheKey,
            encodeAssistantCache(
              _sync.key,
              jsonEncode({
                'items': _events.map((e) => e.toJson()).toList(),
                'states': _stateEvents.values.map((e) => e.toJson()).toList(),
              }),
            ),
          )) {
        throw StateError('Assistant items loaded, but offline storage failed.');
      }
    } catch (error) {
      if (ref.mounted && generation == _generation) {
        _set(
          loading: false,
          error: error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _persistPending(
    Map<String, AssistantStateChange> pending,
  ) async {
    final sync = _sync;
    if (sync.disposed) throw StateError('Your account or community changed.');
    final prefs = sync.prefs;
    if (prefs == null ||
        !await prefs.setString(
          _pendingKey,
          nip44Encrypt(
            sync.key,
            jsonEncode(
              pending.map((id, value) => MapEntry(id, value.toJson())),
            ),
          ),
        )) {
      throw StateError('Couldn’t save this change on your phone. Try again.');
    }
    if (sync.disposed) throw StateError('Your account or community changed.');
  }

  Future<NostrEvent?> _head(AssistantItem item) async {
    final sync = _sync;
    final events = await _query(
      NostrFilter(
        kinds: const [assistantArtifactKind],
        tags: {
          '#d': [assistantStateId(sync.pubkey, item.id)],
        },
        extensions: const {'artifact': 'head'},
        limit: 1,
      ),
    );
    sync.check();
    if (events.isEmpty) return null;
    AssistantItemState.fromEvent(events.single, sync.pubkey, item);
    return events.single;
  }

  void _installHead(AssistantItem item, NostrEvent? head) {
    final revisions = {...state.stateRevisions}..remove(item.id);
    _stateEvents.remove(item.id);
    if (head != null) {
      revisions[item.id] = head.id;
      _stateEvents[item.id] = head;
    }
    _set(
      stateRevisions: revisions,
      stateLoaded: {...state.stateLoaded, item.id},
      attention: {
        ...state.attention,
        item.id: head == null
            ? const AssistantItemState()
            : AssistantItemState.fromEvent(head, _sync.pubkey, item),
      },
    );
  }

  /// Start a new choice from exactly the revision rendered by the consumer.
  /// Pending choices must be reconciled or explicitly discarded, never rebased.
  Future<void> change(
    AssistantItem item,
    AssistantItemState desired, {
    required String? baseRevision,
  }) async {
    if (state.writing.isNotEmpty) return;
    if (state.pending.containsKey(item.id)) {
      _set(
        error:
            'Review or discard the unconfirmed choice before making another.',
      );
      return;
    }
    if (!state.stateLoaded.contains(item.id)) {
      _set(error: 'Refresh this item’s attention state before changing it.');
      return;
    }
    final sync = _sync;
    final event = NostrEvent.fromJson(
      nostr.Event.from(
        kind: assistantArtifactKind,
        content: desired.encode(),
        secretKey: sync.privateHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        tags: [
          ['ar', '1'],
          ['d', assistantStateId(sync.pubkey, item.id)],
          ['h', item.channelId],
          ['type', 'assistant.state'],
          ['title', 'Assistant item state'],
          ['op', baseRevision == null ? 'create' : 'update'],
          if (baseRevision != null) ['prev', baseRevision],
          ['owner', sync.pubkey],
          ['item', item.id],
        ],
        verify: false,
      ).toMap(),
    );
    final intent = AssistantStateChange(
      baseRevision: baseRevision,
      event: event,
    );
    _set(pending: {...state.pending, item.id: intent});
    await _attempt(item, intent);
  }

  /// Retries the original signed event, not a new snapshot of the latest head.
  Future<void> retry(AssistantItem item) async {
    if (state.writing.isNotEmpty) return;
    final intent = state.pending[item.id];
    if (intent != null) await _attempt(item, intent);
  }

  Future<void> _attempt(AssistantItem item, AssistantStateChange intent) async {
    final sync = _sync;
    _set(writing: {item.id});
    try {
      await _persistPending(state.pending);
      sync.check();
      verifiedNostrEventFromJson(jsonEncode(intent.event.toJson()));
      final desired = AssistantItemState.fromEvent(
        intent.event,
        sync.pubkey,
        item,
      );
      final previous = await _head(item);
      sync.check();
      bool matches(NostrEvent? head) =>
          head != null &&
          (head.id == intent.event.id ||
              AssistantItemState.fromEvent(head, sync.pubkey, item).encode() ==
                  desired.encode());
      if (!matches(previous)) {
        if (previous?.id != intent.baseRevision) {
          _installHead(item, previous);
          throw StateError(
            'Conflict: attention changed on another device. Review the latest state, then discard this pending choice before choosing again.',
          );
        }
        // Even a retry submits this exact event with its original predecessor.
        // A concurrent relay update is rejected by NIP-AR, never overwritten.
        sync.check();
        await sync.session.publish(intent.event);
        sync.check();
      }
      final confirmed = await _head(item);
      sync.check();
      if (!matches(confirmed)) {
        _installHead(item, confirmed);
        throw StateError(
          confirmed?.id != intent.baseRevision
              ? 'Conflict: a newer attention revision replaced this choice. Review it before making another change.'
              : 'This change is not confirmed by the relay. Retry to reconcile.',
        );
      }
      if (!ref.mounted || sync != _sync) return;
      final pending = {...state.pending}..remove(item.id);
      await _persistPending(pending);
      if (!ref.mounted || sync != _sync) return;
      _installHead(item, confirmed);
      _set(pending: pending);
      await refresh();
    } catch (error) {
      if (ref.mounted && sync == _sync) {
        _set(
          error:
              'Change unconfirmed. ${error.toString().replaceFirst('Bad state: ', '')}',
        );
      }
    } finally {
      if (ref.mounted && sync == _sync) {
        _set(writing: const {}, error: state.error);
      }
    }
  }

  /// Explicit review does not change the immutable base of an unconfirmed write.
  Future<void> reviewState(AssistantItem item) async {
    if (state.writing.isNotEmpty) return;
    final sync = _sync;
    _set(writing: {item.id});
    try {
      final head = await _head(item);
      sync.check();
      if (ref.mounted && sync == _sync) _installHead(item, head);
    } catch (error) {
      if (ref.mounted && sync == _sync) {
        _set(error: 'Couldn’t review attention state. $error');
      }
    } finally {
      if (ref.mounted && sync == _sync) {
        _set(writing: const {}, error: state.error);
      }
    }
  }

  /// Discard only the local intention. An already accepted relay revision stays.
  Future<void> discardPending(AssistantItem item) async {
    if (state.writing.isNotEmpty) return;
    final sync = _sync;
    _set(writing: {item.id});
    try {
      final head = await _head(item);
      sync.check();
      final pending = {...state.pending}..remove(item.id);
      await _persistPending(pending);
      if (!ref.mounted || sync != _sync) return;
      _installHead(item, head);
      _set(pending: pending);
    } catch (error) {
      if (ref.mounted && sync == _sync) {
        _set(error: 'Couldn’t discard the pending choice. $error');
      }
    } finally {
      if (ref.mounted && sync == _sync) {
        _set(writing: const {}, error: state.error);
      }
    }
  }
}
