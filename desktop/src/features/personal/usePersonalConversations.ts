import * as React from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAppNavigation } from "@/app/navigation/useAppNavigation";
import { useAppShell } from "@/app/AppShellContext";
import { channelsQueryKey, useChannelsQuery } from "@/features/channels/hooks";
import { useWorkingChannels } from "@/features/agents/agentWorkingSignal";
import { addChannelMembers, listRelayAgents } from "@/shared/api/tauri";
import {
  availablePersonalAgents,
  chosenPersonalAgent,
  createPersonalConversation,
  fetchPersonalChannelIds,
} from "./conversations";
import { readPersonalPreference, writePersonalPreference } from "./config";
import { useAssistantScope } from "./useAssistantItems";

/**
 * Shared personal-conversation state for the Conversations page and the
 * sidebar session list. A conversation is a private solo channel; Hermes keys
 * its session by that channel.
 */
export function usePersonalConversations(search = "") {
  const { viewer, relay, ready } = useAssistantScope();
  const channelsQuery = useChannelsQuery();
  const channels = channelsQuery.data ?? [];
  const client = useQueryClient();
  const { goChannel } = useAppNavigation();
  const { topLevelUnreadChannelIds, unreadThreadChannelIds } = useAppShell();
  const workingChannels = useWorkingChannels();
  const [selectedAgent, setSelectedAgent] = React.useState(() =>
    ready ? (readPersonalPreference(relay, viewer, "assistant") ?? "") : "",
  );
  const [pins, setPins] = React.useState<Set<string>>(() => {
    try {
      return new Set(
        JSON.parse(readPersonalPreference(relay, viewer, "pins") ?? "[]"),
      );
    } catch {
      return new Set();
    }
  });
  const [preferenceError, setPreferenceError] = React.useState<string | null>(
    null,
  );
  const alive = React.useRef(true);
  React.useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const idsQuery = useQuery({
    queryKey: [
      "personal-conversations",
      relay,
      viewer,
      channels.map((channel) => channel.id).sort(),
    ],
    enabled: ready && channelsQuery.isSuccess,
    queryFn: () => fetchPersonalChannelIds(channels, viewer, relay),
    refetchInterval: 60_000,
  });
  const agentsQuery = useQuery({
    queryKey: ["personal-agents", relay, viewer],
    enabled: ready,
    queryFn: listRelayAgents,
    refetchInterval: 60_000,
  });
  const agents = availablePersonalAgents(
    agentsQuery.data ?? [],
    viewer,
    channels,
  );
  const chosen = selectedAgent
    ? agents.find((agent) => agent.pubkey === selectedAgent)
    : chosenPersonalAgent(agents, relay, viewer);
  const creation = useMutation({
    mutationFn: async (name: string) => {
      if (!chosen)
        throw new Error("Choose an available remote assistant first.");
      const id = await createPersonalConversation(
        name,
        chosen,
        viewer,
        relay,
        () => alive.current,
      );
      await client.invalidateQueries({ queryKey: channelsQueryKey });
      if (alive.current) await goChannel(id);
    },
    onError: () => {
      void client.invalidateQueries({ queryKey: channelsQueryKey });
    },
  });
  const assignment = useMutation({
    mutationFn: async ({ id, pubkey }: { id: string; pubkey: string }) => {
      await addChannelMembers({ channelId: id, pubkeys: [pubkey] });
      if (!alive.current) return;
      writePersonalPreference(relay, viewer, `assistant:${id}`, pubkey);
    },
    onSuccess: () => {
      void agentsQuery.refetch();
    },
  });
  const visible = channels
    .filter(
      (channel) =>
        idsQuery.data?.has(channel.id) &&
        channel.name.toLowerCase().includes(search.toLowerCase()),
    )
    .sort(
      (a, b) =>
        Number(pins.has(b.id)) - Number(pins.has(a.id)) ||
        (Date.parse(b.lastMessageAt ?? "") || 0) -
          (Date.parse(a.lastMessageAt ?? "") || 0) ||
        a.name.localeCompare(b.name),
    );
  const togglePin = (id: string) => {
    const next = new Set(pins);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    try {
      writePersonalPreference(relay, viewer, "pins", JSON.stringify([...next]));
      setPins(next);
    } catch (error) {
      setPreferenceError(
        error instanceof Error ? error.message : String(error),
      );
    }
  };
  const selectAgent = (pubkey: string) => {
    try {
      writePersonalPreference(relay, viewer, "assistant", pubkey);
      setSelectedAgent(pubkey);
      setPreferenceError(null);
    } catch (error) {
      setPreferenceError(
        error instanceof Error ? error.message : String(error),
      );
    }
  };
  return {
    viewer,
    relay,
    ready,
    channelsQuery,
    channels,
    idsQuery,
    agentsQuery,
    agents,
    chosen,
    creation,
    assignment,
    visible,
    pins,
    togglePin,
    selectAgent,
    preferenceError,
    setPreferenceError,
    selectedAgent,
    setSelectedAgent,
    topLevelUnreadChannelIds,
    unreadThreadChannelIds,
    workingChannels,
    goChannel,
  };
}
