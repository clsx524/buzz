import * as React from "react";
import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { queryRelayEvents } from "@/shared/api/assistant";
import { relayClient } from "@/shared/api/relayClient";
import { signRelayEvent } from "@/shared/api/tauri";
import { useIdentityQuery } from "@/shared/api/hooks";
import { useCommunities } from "@/features/communities/useCommunities";
import {
  ASSISTANT_TYPES,
  assistantStateId,
  OPEN_STATE,
  parseAssistantItem,
  parseAssistantState,
  resolveAssistantStateChange,
  type AssistantItem,
  type AssistantState,
} from "./artifacts";

const PAGE_SIZE = 100;
export function useAssistantScope() {
  const identity = useIdentityQuery();
  const { activeCommunity } = useCommunities();
  const viewer = identity.data?.pubkey ?? "";
  const relay = activeCommunity?.relayUrl ?? "";
  return { viewer, relay, ready: Boolean(viewer && relay) };
}

export function useAssistantItems(itemId?: string) {
  const { viewer, relay, ready } = useAssistantScope();
  const scope = { relayUrl: relay, signerPubkey: viewer };
  const client = useQueryClient();
  const alive = React.useRef(true);
  React.useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const query = useInfiniteQuery({
    queryKey: ["personal-artifacts", relay, viewer],
    enabled: ready,
    initialPageParam: 0,
    queryFn: ({ pageParam }) =>
      queryRelayEvents(
        [
          {
            artifact: "current",
            kinds: [45010],
            "#type": ASSISTANT_TYPES,
            limit: PAGE_SIZE,
            offset: pageParam,
          },
        ],
        scope,
      ),
    getNextPageParam: (last, pages) =>
      last.length === PAGE_SIZE ? pages.length * PAGE_SIZE : undefined,
    refetchInterval: 60_000,
  });
  const detailQuery = useQuery({
    queryKey: ["personal-artifact-detail", relay, viewer, itemId],
    enabled: ready && Boolean(itemId),
    queryFn: async () => {
      const events = await queryRelayEvents(
        [{ artifact: "head", kinds: [45010], "#d": [itemId], limit: 1 }],
        scope,
      );
      return events[0] ? parseAssistantItem(events[0]) : null;
    },
    refetchInterval: 60_000,
  });
  const events = React.useMemo(
    () => query.data?.pages.flat() ?? [],
    [query.data],
  );
  const items = React.useMemo(() => {
    const unique = new Map<string, AssistantItem>();
    for (const event of events) {
      const item = parseAssistantItem(event);
      if (item) unique.set(item.id, item);
    }
    if (detailQuery.data) unique.set(detailQuery.data.id, detailQuery.data);
    return [...unique.values()];
  }, [events, detailQuery.data]);
  const stateQuery = useQuery({
    queryKey: [
      "personal-state",
      relay,
      viewer,
      items.map((item) => `${item.id}:${item.channelId}`).sort(),
    ],
    enabled: ready && items.length > 0,
    queryFn: async () => {
      const states = new Map<
        string,
        { state: AssistantState; eventId: string }
      >();
      for (let start = 0; start < items.length; start += PAGE_SIZE) {
        if (!alive.current)
          throw new Error("Community changed while loading item state.");
        const batch = items.slice(start, start + PAGE_SIZE);
        const ids = await Promise.all(
          batch.map((item) => assistantStateId(viewer, item.id)),
        );
        const stateEvents = await queryRelayEvents(
          [
            {
              artifact: "current",
              kinds: [45010],
              "#type": ["assistant.state"],
              "#d": ids,
              "#owner": [viewer],
              limit: PAGE_SIZE,
            },
          ],
          scope,
        );
        for (const event of stateEvents) {
          for (const item of batch) {
            const state = await parseAssistantState(event, viewer, item);
            if (state) {
              states.set(item.id, { state, eventId: event.id });
              break;
            }
          }
        }
      }
      return states;
    },
    refetchInterval: 60_000,
  });
  const mutation = useMutation({
    mutationFn: async ({
      item,
      change,
      observedRevision,
    }: {
      item: AssistantItem;
      change: Partial<AssistantState>;
      observedRevision: string | null;
    }) => {
      if (!ready)
        throw new Error("Connect your identity before changing an item.");
      const id = await assistantStateId(viewer, item.id);
      const heads = await queryRelayEvents(
        [{ artifact: "head", kinds: [45010], "#d": [id], limit: 1 }],
        scope,
      );
      const head = heads[0];
      const previous = head
        ? await parseAssistantState(head, viewer, item)
        : OPEN_STATE;
      if (!previous)
        throw new Error(
          "The current item state is invalid or belongs to a different author. No change was sent.",
        );
      const state = resolveAssistantStateChange(
        previous,
        change,
        observedRevision,
        head?.id ?? null,
      );
      if (!alive.current)
        throw new Error("Community changed. No item change was sent.");
      const event = await signRelayEvent({
        kind: 45010,
        tags: [
          ["ar", "1"],
          ["d", id],
          ["h", item.channelId],
          ["type", "assistant.state"],
          ["title", "Assistant item state"],
          ["owner", viewer],
          ["item", item.id],
          ["op", head ? "update" : "create"],
          ...(head ? [["prev", head.id]] : []),
        ],
        content: JSON.stringify(state),
      });
      if (event.pubkey !== viewer)
        throw new Error(
          "Your identity changed. Retry from the current community.",
        );
      if (!alive.current)
        throw new Error("Community changed. No item change was sent.");
      await relayClient.publishEvent(
        event,
        "Item change is unconfirmed. Refresh before retrying.",
        "Item change was not confirmed by the relay.",
        () => alive.current,
      );
      return state;
    },
    onSuccess: () =>
      client.invalidateQueries({ queryKey: ["personal-state", relay, viewer] }),
  });
  return {
    query,
    detailQuery,
    stateQuery,
    items,
    malformedCount: events.filter((event) => !parseAssistantItem(event)).length,
    mutation,
    ready,
  };
}
