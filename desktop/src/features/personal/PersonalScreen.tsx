import * as React from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Bookmark, ChevronLeft, MessageCircle, Pin } from "lucide-react";
import { useAppNavigation } from "@/app/navigation/useAppNavigation";
import { useAppShell } from "@/app/AppShellContext";
import { channelsQueryKey, useChannelsQuery } from "@/features/channels/hooks";
import { useWorkingChannels } from "@/features/agents/agentWorkingSignal";
import { addChannelMembers, listRelayAgents } from "@/shared/api/tauri";
import { Markdown } from "@/shared/ui/markdown";
import { Button } from "@/shared/ui/button";
import { Input } from "@/shared/ui/input";
import { ExternalLinkAnchor } from "@/shared/ui/markdown/ExternalLinkAnchor";
import {
  isAttentionVisible,
  OPEN_STATE,
  type AssistantItem,
  type AssistantState,
} from "./artifacts";
import { useAssistantItems, useAssistantScope } from "./useAssistantItems";
import {
  availablePersonalAgents,
  chosenPersonalAgent,
  createPersonalConversation,
  fetchPersonalChannelIds,
} from "./conversations";
import { readPersonalPreference, writePersonalPreference } from "./config";
import { AssistantControls } from "./AssistantControls";

export type PersonalSection = "today" | "conversations" | "library";
function ErrorNotice({
  error,
  retry,
  actionLabel = "Retry",
}: {
  error: unknown;
  retry: () => void;
  actionLabel?: string;
}) {
  return (
    <div
      role="alert"
      className="rounded-xl border border-destructive/30 bg-destructive/5 p-4 text-sm"
    >
      <p>{error instanceof Error ? error.message : String(error)}</p>
      <Button variant="outline" className="mt-3" onClick={retry}>
        {actionLabel}
      </Button>
    </div>
  );
}

export function PersonalScreen({
  section,
  itemId,
}: {
  section: PersonalSection;
  itemId?: string;
}) {
  const { goChannel } = useAppNavigation();
  return (
    <main className="flex min-h-0 min-w-0 flex-1 flex-col overflow-y-auto bg-background">
      <div className="mx-auto w-full max-w-3xl space-y-6 px-4 py-8 sm:px-8">
        <header>
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Personal assistant
          </p>
          <h1 className="text-3xl font-semibold tracking-tight">
            {section === "today"
              ? "Today"
              : section === "library"
                ? "Library"
                : "Conversations"}
          </h1>
          <p className="mt-2 text-sm text-muted-foreground">
            {section === "today"
              ? "What needs your attention, without the noise."
              : section === "library"
                ? "Reports and findings you want to keep."
                : "A separate conversation for each goal. Your history stays with that conversation."}
          </p>
        </header>
        {section === "today" ? (
          <AssistantControls openConversation={(channelId) => void goChannel(channelId)} />
        ) : null}
        {section === "conversations" ? (
          <Conversations />
        ) : (
          <AssistantCollection section={section} itemId={itemId} />
        )}
      </div>
    </main>
  );
}

function AssistantCollection({
  section,
  itemId,
}: {
  section: "today" | "library";
  itemId?: string;
}) {
  const {
    query,
    detailQuery,
    stateQuery,
    items,
    malformedCount,
    mutation,
    ready,
  } = useAssistantItems(itemId);
  const { goChannel } = useAppNavigation();
  const [now, setNow] = React.useState(() => Date.now() / 1000);
  const [showArchived, setShowArchived] = React.useState(false);
  React.useEffect(() => {
    const timer = setInterval(() => setNow(Date.now() / 1000), 30_000);
    return () => clearInterval(timer);
  }, []);
  const stateFor = (item: AssistantItem) =>
    stateQuery.data?.get(item.id)?.state ?? OPEN_STATE;
  const filtered = items
    .filter((item) =>
      section === "library"
        ? item.type === "assistant.report" || stateFor(item).saved
        : showArchived || isAttentionVisible(stateFor(item), now),
    )
    .sort(
      (a, b) =>
        Number(b.requiresInput) - Number(a.requiresInput) ||
        Number(b.priority === "important") -
          Number(a.priority === "important") ||
        b.event.created_at - a.event.created_at,
    );
  const selected = itemId
    ? items.find((item) => item.id === itemId)
    : undefined;
  const stateReady = items.length === 0 || stateQuery.isSuccess;
  const change = (item: AssistantItem, patch: Partial<AssistantState>) =>
    mutation.mutate({
      item,
      change: patch,
      observedRevision: stateQuery.data?.get(item.id)?.eventId ?? null,
    });
  return (
    <>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <span className="text-xs text-muted-foreground">
          From your assistant
          {query.dataUpdatedAt
            ? ` · updated ${new Date(query.dataUpdatedAt).toLocaleTimeString()}`
            : ""}
        </span>
        <Button
          size="sm"
          variant="outline"
          disabled={query.isFetching || stateQuery.isFetching}
          onClick={() => {
            void query.refetch();
            void stateQuery.refetch();
            if (itemId) void detailQuery.refetch();
          }}
        >
          Refresh
        </Button>
      </div>
      {!ready || query.isLoading ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading your assistant’s items…
        </p>
      ) : null}
      {query.isError ? (
        <ErrorNotice error={query.error} retry={() => void query.refetch()} />
      ) : null}
      {stateQuery.isError ? (
        <ErrorNotice
          error={stateQuery.error}
          retry={() => void stateQuery.refetch()}
        />
      ) : null}
      {itemId && detailQuery.isError ? (
        <ErrorNotice
          error={detailQuery.error}
          retry={() => void detailQuery.refetch()}
        />
      ) : null}
      {itemId && detailQuery.isLoading ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading this item’s current revision…
        </p>
      ) : null}
      {items.length > 0 && stateQuery.isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          Checking your saved and attention state…
        </p>
      ) : null}
      {mutation.isError ? (
        <ErrorNotice
          error={mutation.error}
          actionLabel="Refresh item state"
          retry={() => {
            mutation.reset();
            void stateQuery.refetch();
          }}
        />
      ) : null}
      {mutation.isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          Confirming change with the relay…
        </p>
      ) : null}
      {malformedCount > 0 ? (
        <p className="text-xs text-muted-foreground">
          {malformedCount} unsupported or invalid artifact entries were not
          displayed.
        </p>
      ) : null}
      {selected ? (
        <section className="space-y-5 rounded-2xl border p-5 sm:p-6">
          <Link
            to={section === "today" ? "/today" : "/library"}
            className="inline-flex items-center gap-2 text-sm text-muted-foreground"
          >
            <ChevronLeft className="size-4" aria-hidden="true" />
            Back to {section === "today" ? "Today" : "Library"}
          </Link>
          <ItemMeta item={selected} />
          <h2 className="text-2xl font-semibold">{selected.title}</h2>
          {selected.summary ? (
            <p className="text-sm text-muted-foreground">{selected.summary}</p>
          ) : null}
          <Markdown content={selected.body} />
          <div className="space-y-2 border-t pt-4">
            <h3 className="text-sm font-medium">Evidence & sources</h3>
            {selected.sources.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                No sources were supplied for this item.
              </p>
            ) : (
              <ul className="space-y-3 text-sm">
                {selected.sources.map((source, index) => (
                  <li key={`${source.label}:${index}`} className="break-words">
                    {source.url ? (
                      <ExternalLinkAnchor
                        anchorProps={{}}
                        href={source.url}
                        isLinearLink={false}
                        label={source.label}
                      >
                        {source.label}
                      </ExternalLinkAnchor>
                    ) : (
                      <span>{source.label}</span>
                    )}
                    <span className="block text-xs text-muted-foreground">
                      {source.checkedAt !== undefined
                        ? `Checked ${new Date(source.checkedAt * 1000).toLocaleString()}`
                        : "No check date supplied"}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <p className="text-xs text-muted-foreground">
            Published{" "}
            {new Date(selected.event.created_at * 1000).toLocaleString()}
          </p>
          <details className="text-xs text-muted-foreground">
            <summary className="cursor-pointer">Source identity</summary>
            <p className="mt-2 break-all">{selected.event.pubkey}</p>
          </details>
          <ItemActions
            item={selected}
            state={stateFor(selected)}
            disabled={!stateReady || mutation.isPending}
            change={change}
          />
          <Button
            className="min-h-11 gap-2"
            onClick={() =>
              void goChannel(
                selected.channelId,
                selected.root
                  ? { messageId: selected.root, threadRootId: selected.root }
                  : undefined,
              )
            }
          >
            <MessageCircle className="size-4" aria-hidden="true" />
            Open conversation
          </Button>
          <p className="text-xs text-muted-foreground">
            Opening a conversation does not approve or execute any external
            action.
          </p>
        </section>
      ) : itemId ? (
        detailQuery.isLoading ? null : (
          <div className="rounded-xl border p-5 text-sm">
            <p>
              This item is unavailable, unsupported, or no longer accessible.
              Refresh or return to the list.
            </p>
            <Link
              className="mt-3 inline-block text-primary underline"
              to={section === "today" ? "/today" : "/library"}
            >
              Back to list
            </Link>
          </div>
        )
      ) : stateReady && query.isSuccess ? (
        <>
          {section === "today" ? (
            <label className="flex min-h-11 items-center gap-2 text-sm text-muted-foreground">
              <input
                type="checkbox"
                checked={showArchived}
                onChange={(event) => setShowArchived(event.target.checked)}
              />
              Include archived and snoozed items
            </label>
          ) : null}
          {filtered.length === 0 ? (
            <div className="rounded-2xl border border-dashed p-8">
              <h2 className="font-medium">
                {section === "today"
                  ? "Nothing needs your attention here."
                  : "Your library is quiet."}
              </h2>
              <p className="mt-2 text-sm text-muted-foreground">
                {section === "today"
                  ? "New findings and updates appear when your server assistant publishes them. You can start a conversation any time."
                  : "Published reports and saved findings appear here. Save a finding from Today to keep it."}
              </p>
              <Link
                to="/conversations"
                className="mt-4 inline-block text-sm text-primary underline"
              >
                Open conversations
              </Link>
              {query.hasNextPage ? (
                <p className="mt-3 text-xs text-muted-foreground">
                  More items are available below; this is only the loaded page.
                </p>
              ) : null}
            </div>
          ) : (
            <div className="space-y-3">
              {filtered.map((item) => (
                <article
                  key={item.id}
                  className={`space-y-3 rounded-2xl border p-5 ${item.requiresInput ? "border-primary/40 bg-primary/5" : ""}`}
                >
                  <ItemMeta item={item} />
                  <Link
                    to={section === "today" ? "/today" : "/library"}
                    search={{ item: item.id }}
                    className="block text-lg font-medium hover:underline"
                  >
                    {item.title}
                  </Link>
                  {item.summary ? (
                    <p className="line-clamp-3 text-sm text-muted-foreground">
                      {item.summary}
                    </p>
                  ) : null}
                  <ItemActions
                    item={item}
                    state={stateFor(item)}
                    disabled={mutation.isPending}
                    change={change}
                  />
                </article>
              ))}
            </div>
          )}
        </>
      ) : null}
      {query.hasNextPage ? (
        <Button
          variant="outline"
          disabled={query.isFetchingNextPage}
          onClick={() => void query.fetchNextPage()}
        >
          {query.isFetchingNextPage ? "Loading…" : "Load more"}
        </Button>
      ) : null}
    </>
  );
}

function ItemMeta({ item }: { item: AssistantItem }) {
  return (
    <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
      <span>
        {item.requiresInput
          ? "Needs your input"
          : item.type === "assistant.report"
            ? "Report"
            : item.type === "assistant.finding"
              ? "Finding"
              : "Update"}
      </span>
      {item.priority === "important" ? (
        <span className="rounded-full bg-accent px-2 py-1 text-accent-foreground">
          Important
        </span>
      ) : null}
      {item.topic ? <span>· {item.topic}</span> : null}
      <time dateTime={new Date(item.event.created_at * 1000).toISOString()}>
        · {new Date(item.event.created_at * 1000).toLocaleDateString()}
      </time>
    </div>
  );
}
function ItemActions({
  item,
  state,
  disabled,
  change,
}: {
  item: AssistantItem;
  state: AssistantState;
  disabled: boolean;
  change: (item: AssistantItem, patch: Partial<AssistantState>) => void;
}) {
  return (
    <div className="flex flex-wrap gap-2">
      <Button
        size="sm"
        variant="outline"
        disabled={disabled}
        aria-pressed={state.saved}
        onClick={() => change(item, { saved: !state.saved })}
      >
        <Bookmark className="mr-2 size-4" aria-hidden="true" />
        {state.saved ? "Saved" : "Save"}
      </Button>
      <Button
        size="sm"
        variant="ghost"
        disabled={disabled}
        onClick={() =>
          change(item, {
            status: state.status === "archived" ? "open" : "archived",
          })
        }
      >
        {state.status === "archived" ? "Reopen" : "Archive"}
      </Button>
      {state.status === "snoozed" ? (
        <Button
          size="sm"
          variant="ghost"
          disabled={disabled}
          onClick={() => change(item, { status: "open" })}
        >
          Unsnooze
        </Button>
      ) : (
        <Button
          size="sm"
          variant="ghost"
          disabled={disabled}
          onClick={() =>
            change(item, {
              status: "snoozed",
              snoozedUntil: Math.floor(Date.now() / 1000) + 86400,
            })
          }
        >
          Snooze 24h
        </Button>
      )}
    </div>
  );
}

function Conversations() {
  const { viewer, relay, ready } = useAssistantScope();
  const channelsQuery = useChannelsQuery();
  const channels = channelsQuery.data ?? [];
  const client = useQueryClient();
  const { goChannel } = useAppNavigation();
  const { topLevelUnreadChannelIds, unreadThreadChannelIds } = useAppShell();
  const workingChannels = useWorkingChannels();
  const [search, setSearch] = React.useState("");
  const [name, setName] = React.useState("");
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
    mutationFn: async () => {
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
      if (alive.current) {
        setName("");
        await goChannel(id);
      }
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
  const [preferenceError, setPreferenceError] = React.useState<string | null>(
    null,
  );
  return (
    <>
      <form
        className="space-y-4 rounded-2xl border p-5"
        onSubmit={(event) => {
          event.preventDefault();
          creation.mutate();
        }}
      >
        <h2 className="font-medium">Start a private conversation</h2>
        <label className="block space-y-2 text-sm">
          <span>Remote assistant</span>
          <select
            className="min-h-11 w-full rounded-md border bg-background px-3"
            value={chosen?.pubkey ?? ""}
            disabled={agentsQuery.isLoading || creation.isPending}
            onChange={(event) => {
              try {
                writePersonalPreference(
                  relay,
                  viewer,
                  "assistant",
                  event.target.value,
                );
                setSelectedAgent(event.target.value);
                setPreferenceError(null);
              } catch (error) {
                setPreferenceError(
                  error instanceof Error ? error.message : String(error),
                );
              }
            }}
          >
            <option value="" disabled>
              Choose an assistant
            </option>
            {agents.map((agent) => (
              <option key={agent.pubkey} value={agent.pubkey}>
                {agent.name} · {agent.status}
              </option>
            ))}
          </select>
        </label>
        <p className="text-xs text-muted-foreground">
          Uses your server-connected agent; does not launch a model on this
          device. Offline or unknown status does not prove the assistant is
          ready.
        </p>
        <label className="block space-y-2 text-sm">
          <span>Conversation name</span>
          <Input
            value={name}
            maxLength={255}
            onChange={(event) => setName(event.target.value)}
            placeholder="A goal, question, or topic"
          />
        </label>
        <Button
          type="submit"
          className="min-h-11"
          disabled={!ready || !chosen || !name.trim() || creation.isPending}
        >
          {creation.isPending ? "Creating…" : "New conversation"}
        </Button>
      </form>
      {agentsQuery.isError ? (
        <ErrorNotice
          error={agentsQuery.error}
          retry={() => void agentsQuery.refetch()}
        />
      ) : agentsQuery.isSuccess && agents.length === 0 ? (
        <p className="rounded-xl border p-4 text-sm text-muted-foreground">
          No authorized remote assistants were found. Connect Hermes on your
          server and check its relay access, then refresh.
        </p>
      ) : null}
      {creation.isError ? (
        <ErrorNotice
          error={creation.error}
          actionLabel="Refresh conversations"
          retry={() => {
            creation.reset();
            void channelsQuery.refetch();
            void idsQuery.refetch();
          }}
        />
      ) : null}
      {assignment.isError ? (
        <ErrorNotice
          error={assignment.error}
          retry={() => {
            if (assignment.variables) assignment.mutate(assignment.variables);
          }}
        />
      ) : null}
      {preferenceError ? (
        <ErrorNotice
          error={preferenceError}
          actionLabel="Dismiss"
          retry={() => setPreferenceError(null)}
        />
      ) : null}
      <div className="flex gap-2">
        <Input
          aria-label="Search conversations"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search conversations"
        />
        <Button
          variant="outline"
          disabled={idsQuery.isFetching}
          onClick={() => {
            void channelsQuery.refetch();
            void idsQuery.refetch();
            void agentsQuery.refetch();
          }}
        >
          Refresh
        </Button>
      </div>
      {channelsQuery.isError ? (
        <ErrorNotice
          error={channelsQuery.error}
          retry={() => void channelsQuery.refetch()}
        />
      ) : null}
      {idsQuery.isError ? (
        <ErrorNotice
          error={idsQuery.error}
          retry={() => void idsQuery.refetch()}
        />
      ) : null}
      {channelsQuery.isLoading || idsQuery.isLoading ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading private conversations…
        </p>
      ) : null}
      {idsQuery.isSuccess && visible.length === 0 ? (
        <p className="rounded-2xl border border-dashed p-6 text-sm text-muted-foreground">
          {search
            ? "No conversations match your search."
            : "No personal conversations yet. Start one above; each has its own history."}
        </p>
      ) : null}
      <div className="space-y-3">
        {visible.map((channel) => {
          const unread =
            topLevelUnreadChannelIds.has(channel.id) ||
            unreadThreadChannelIds.has(channel.id);
          const working = workingChannels.some(
            (entry) => entry.channelId === channel.id,
          );
          const boundAgent = chosenPersonalAgent(
            agents,
            relay,
            viewer,
            channel.id,
          );
          return (
            <article className="rounded-xl border p-4" key={channel.id}>
              <div className="flex items-start gap-3">
                <button
                  type="button"
                  className="min-h-11 min-w-0 flex-1 text-left"
                  onClick={() => void goChannel(channel.id)}
                >
                  <span
                    className={`block truncate text-base ${unread ? "font-semibold" : "font-medium"}`}
                  >
                    {channel.name}
                    {unread ? (
                      <span className="ml-2 text-xs text-primary">Unread</span>
                    ) : null}
                  </span>
                  <span className="mt-1 block text-xs text-muted-foreground">
                    {working ? "Working · " : ""}
                    {channel.lastMessageAt
                      ? `Recent · ${new Date(channel.lastMessageAt).toLocaleString()}`
                      : "No messages yet"}
                  </span>
                </button>
                <Button
                  size="icon"
                  variant="ghost"
                  aria-label={
                    pins.has(channel.id)
                      ? `Unpin ${channel.name}`
                      : `Pin ${channel.name}`
                  }
                  aria-pressed={pins.has(channel.id)}
                  onClick={() => togglePin(channel.id)}
                >
                  <Pin
                    className={`size-4 ${pins.has(channel.id) ? "fill-current" : ""}`}
                  />
                </Button>
              </div>
              <label className="mt-3 flex items-center gap-2 text-xs text-muted-foreground">
                <span>Assistant</span>
                <select
                  className="min-h-10 min-w-0 flex-1 rounded-md border bg-background px-2 text-foreground"
                  aria-label={`Assistant for ${channel.name}`}
                  value={boundAgent?.pubkey ?? ""}
                  disabled={assignment.isPending || agentsQuery.isFetching}
                  onChange={(event) =>
                    assignment.mutate({
                      id: channel.id,
                      pubkey: event.target.value,
                    })
                  }
                >
                  <option value="" disabled>
                    Selected assistant unavailable
                  </option>
                  {agents.map((agent) => (
                    <option key={agent.pubkey} value={agent.pubkey}>
                      {agent.name}
                    </option>
                  ))}
                </select>
              </label>
            </article>
          );
        })}
      </div>
      <p className="text-xs text-muted-foreground">
        Pins and assistant preferences are saved for this community and identity
        on this device. Voice messages and attachments are available inside
        conversations; voice notes are not automatic transcription.
      </p>
    </>
  );
}
