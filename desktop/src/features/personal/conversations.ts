import { queryRelayEvents } from "@/shared/api/assistant";
import { relayClient } from "@/shared/api/relayClient";
import {
  addChannelMembers,
  listRelayAgents,
  signRelayEvent,
} from "@/shared/api/tauri";
import { revalidateRelayAgents } from "@/shared/api/tauriRelayAgents";
import type { Channel, RelayAgent } from "@/shared/api/types";
import {
  relayAgentCanRespondInChannel,
  relayAgentIsSharedWithUser,
} from "@/features/agents/lib/agentAutocompleteEligibility";
import { tagValue } from "./artifacts";
import { readPersonalPreference, writePersonalPreference } from "./config";

export async function fetchPersonalChannelIds(
  channels: readonly Channel[],
  viewer: string,
  relay: string,
): Promise<Set<string>> {
  const candidates = channels.filter(
    (channel) =>
      channel.channelType === "stream" &&
      channel.visibility === "private" &&
      channel.isMember &&
      !channel.archivedAt,
  );
  const result = new Set<string>();
  for (let start = 0; start < candidates.length; start += 100) {
    const ids = candidates
      .slice(start, start + 100)
      .map((channel) => channel.id);
    const events = await queryRelayEvents(
      [
        {
          kinds: [39000],
          "#d": ids,
          "#t": ["buzz.solo"],
          "#P": [viewer],
          limit: 100,
        },
      ],
      { relayUrl: relay, signerPubkey: viewer },
    );
    for (const event of events) {
      const id = tagValue(event, "d");
      if (
        id &&
        ids.includes(id) &&
        event.tags.some((tag) => tag[0] === "t" && tag[1] === "buzz.solo") &&
        tagValue(event, "P") === viewer
      )
        result.add(id);
    }
  }
  return result;
}

export function availablePersonalAgents(
  agents: RelayAgent[],
  viewer: string,
  channels: readonly Channel[],
) {
  const shared = new Set(
    channels.filter((channel) => channel.isMember).map((channel) => channel.id),
  );
  return agents
    .filter((agent) => relayAgentIsSharedWithUser(agent, shared, viewer))
    .sort(
      (a, b) =>
        Number(/hermes/i.test(`${b.name} ${b.agentType}`)) -
          Number(/hermes/i.test(`${a.name} ${a.agentType}`)) ||
        a.name.localeCompare(b.name),
    );
}

export function chosenPersonalAgent(
  agents: RelayAgent[],
  relay: string,
  viewer: string,
  channelId?: string,
): RelayAgent | undefined {
  const bound = channelId
    ? readPersonalPreference(relay, viewer, `assistant:${channelId}`)
    : null;
  // A per-conversation choice must not silently route private text elsewhere.
  if (bound) return agents.find((agent) => agent.pubkey === bound);
  const preferred = readPersonalPreference(relay, viewer, "assistant");
  if (channelId) {
    // Conversations created on another device already have an assistant member.
    const members = agents.filter((agent) =>
      agent.channelIds.includes(channelId),
    );
    if (members.length > 0)
      return members.find((agent) => agent.pubkey === preferred) ?? members[0];
  }
  return preferred
    ? agents.find((agent) => agent.pubkey === preferred)
    : agents[0];
}

export async function createPersonalConversation(
  name: string,
  agent: RelayAgent,
  viewer: string,
  relay: string,
  isCurrent: () => boolean,
): Promise<string> {
  const fresh = await revalidateRelayAgents([agent.pubkey]);
  if (
    !fresh.some(
      (entry) =>
        entry.pubkey === agent.pubkey &&
        relayAgentIsSharedWithUser(entry, new Set(agent.channelIds), viewer),
    )
  )
    throw new Error(
      "This assistant is no longer available to you. Refresh the assistant list.",
    );
  const id = crypto.randomUUID();
  const event = await signRelayEvent({
    kind: 9007,
    content: "",
    tags: [
      ["h", id],
      ["name", name.trim()],
      ["visibility", "private"],
      ["channel_type", "stream"],
      ["t", "buzz.solo"],
    ],
  });
  if (!isCurrent() || event.pubkey !== viewer)
    throw new Error("Community or identity changed. No conversation was sent.");
  await relayClient.publishEvent(
    event,
    "Conversation creation is unconfirmed. Refresh the list before creating another.",
    "Could not create the conversation.",
    isCurrent,
  );
  if (!isCurrent())
    throw new Error(
      "Conversation created in the previous community. Return there to continue.",
    );
  writePersonalPreference(relay, viewer, `assistant:${id}`, agent.pubkey);
  try {
    if (!isCurrent()) throw new Error("Community changed.");
    await addChannelMembers({ channelId: id, pubkeys: [agent.pubkey] });
  } catch (error) {
    throw new Error(
      `Conversation ${id} was created, but its assistant could not be added. Open it and use conversation members to retry. ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  return id;
}

export async function personalMessageRecipient(
  channel: Channel,
  viewer: string,
  relay: string,
  channels: readonly Channel[],
): Promise<string | null> {
  if (channel.channelType !== "stream" || channel.visibility !== "private")
    return null;
  const ids = await fetchPersonalChannelIds([channel], viewer, relay);
  if (!ids.has(channel.id)) return null;
  const agents = availablePersonalAgents(
    await listRelayAgents(),
    viewer,
    channels,
  );
  const agent = chosenPersonalAgent(agents, relay, viewer, channel.id);
  if (!agent)
    throw new Error(
      "Choose an available remote assistant in Conversations before sending.",
    );
  const fresh = await revalidateRelayAgents([agent.pubkey], channel.id);
  if (
    !fresh.some(
      (entry) =>
        entry.pubkey === agent.pubkey &&
        relayAgentCanRespondInChannel(entry, channel.id, viewer),
    )
  )
    throw new Error(
      "The selected assistant cannot respond in this conversation. Check its membership and access, then retry.",
    );
  return agent.pubkey;
}
