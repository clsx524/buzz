import { Link, useLocation } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { BookOpen, CalendarDays, Pin, Plus, Settings } from "lucide-react";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  useSidebar,
} from "@/shared/ui/sidebar";
import { Button } from "@/shared/ui/button";
import type { ReactNode } from "react";
import type { Community } from "@/features/communities/types";
import type { Channel } from "@/shared/api/types";
import {
  getAssistantSessions,
  loadAssistantConnection,
  type AssistantSession,
} from "./assistantClient";
import { usePersonalConversations } from "./usePersonalConversations";

function sessionTime(value?: string | number | null) {
  if (value === null || value === undefined || value === "") return "";
  const date = typeof value === "number" ? new Date(value * 1000) : new Date(value);
  const diff = Date.now() - date.getTime();
  if (!Number.isFinite(diff) || diff < 0) return "";
  if (diff < 60_000) return "now";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h`;
  return date.toLocaleDateString();
}

function SessionRow({
  channel,
  title,
  source,
  time,
  active,
  unread,
  working,
  pinned,
  onTogglePin,
  onNavigate,
}: {
  channel?: Channel;
  title: string;
  source?: string;
  time: string;
  active: boolean;
  unread: boolean;
  working: boolean;
  pinned: boolean;
  onTogglePin?: () => void;
  onNavigate?: () => void;
}) {
  const content = (
    <>
      <span
        className={`size-2 shrink-0 rounded-full ${unread ? "bg-primary" : "bg-transparent"}`}
        aria-hidden="true"
      />
      <span className="min-w-0 flex-1 truncate">{title}</span>
      {source ? (
        <span className="shrink-0 text-[10px] uppercase tracking-wide text-muted-foreground">
          {source}
        </span>
      ) : null}
      {working ? (
        <span className="shrink-0 text-[10px] uppercase tracking-wide text-muted-foreground">
          Working
        </span>
      ) : null}
      <span className="shrink-0 text-[10px] text-muted-foreground">{time}</span>
    </>
  );
  return (
    <div
      className={`flex items-center rounded-lg ${active ? "bg-accent" : "hover:bg-accent"}`}
    >
      {channel ? (
        <Link
          to="/channels/$channelId"
          params={{ channelId: channel.id }}
          onClick={onNavigate}
          aria-current={active ? "page" : undefined}
          className={`flex min-h-11 min-w-0 flex-1 items-center gap-2 px-3 text-sm ${active ? "font-medium text-accent-foreground" : "text-muted-foreground"}`}
        >
          {content}
        </Link>
      ) : (
        <div className="flex min-h-11 min-w-0 flex-1 items-center gap-2 px-3 text-sm text-muted-foreground">
          {content}
        </div>
      )}
      {channel && onTogglePin ? (
        <button
          type="button"
          aria-label={pinned ? `Unpin ${title}` : `Pin ${title}`}
          aria-pressed={pinned}
          onClick={onTogglePin}
          className="mr-1 flex size-8 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-background"
        >
          <Pin className={`size-3.5 ${pinned ? "fill-current" : ""}`} />
        </button>
      ) : null}
    </div>
  );
}

export function PersonalSidebar({
  communityName,
  onSettings,
  onAddCommunity,
  connectionDialog,
  communities,
  activeCommunityId,
  onSwitchCommunity,
}: {
  communityName?: string;
  onSettings: () => void;
  onAddCommunity: () => void;
  connectionDialog: ReactNode;
  communities: Community[];
  activeCommunityId?: string;
  onSwitchCommunity: (id: string) => void;
}) {
  const location = useLocation();
  const { isMobile, setOpenMobile } = useSidebar();
  const {
    chosen,
    channels,
    channelsQuery,
    idsQuery,
    visible,
    pins,
    togglePin,
    topLevelUnreadChannelIds,
    unreadThreadChannelIds,
    workingChannels,
  } = usePersonalConversations();
  const connectionQuery = useQuery({
    queryKey: ["personal-assistant-connection"],
    queryFn: loadAssistantConnection,
    staleTime: 60_000,
  });
  const sessionsQuery = useQuery({
    queryKey: [
      "personal-assistant-sessions",
      connectionQuery.data?.origin,
      connectionQuery.data?.profile,
    ],
    enabled: Boolean(connectionQuery.data),
    queryFn: () => getAssistantSessions(connectionQuery.data!),
    refetchInterval: 60_000,
  });
  const close = () => {
    if (isMobile) setOpenMobile(false);
  };
  const destinations = [
    { to: "/today", label: "Today", icon: CalendarDays },
    { to: "/library", label: "Library", icon: BookOpen },
  ] as const;
  const channelById = new Map(channels.map((channel) => [channel.id, channel]));
  const channelIds = new Set(channels.map((channel) => channel.id));
  const hermesSessions = (sessionsQuery.data?.sessions ?? [])
    .filter(
      (session) =>
        !session.hidden &&
        !session.archived &&
        (!session.chat_id || channelIds.has(session.chat_id)),
    )
    .sort(
      (a, b) =>
        Number(b.pinned) - Number(a.pinned) ||
        (b.last_active ?? b.started_at) - (a.last_active ?? a.started_at),
    );
  const representedChannelIds = new Set(
    hermesSessions
      .map((session) => session.chat_id)
      .filter((id): id is string => Boolean(id)),
  );
  const unrepresentedChannels = visible.filter(
    (channel) => !representedChannelIds.has(channel.id),
  );
  const showHermesSessions =
    Boolean(connectionQuery.data) && sessionsQuery.isSuccess;
  const loading =
    connectionQuery.isLoading ||
    (Boolean(connectionQuery.data) && sessionsQuery.isLoading) ||
    channelsQuery.isLoading ||
    idsQuery.isLoading;
  const sessionError =
    Boolean(connectionQuery.data) && sessionsQuery.isError;
  const channelError = channelsQuery.isError || idsQuery.isError;
  const sessionCount = showHermesSessions
    ? hermesSessions.length + unrepresentedChannels.length
    : visible.length;
  return (
    <Sidebar>
      <SidebarHeader className="gap-1 p-5">
        <span className="text-lg font-semibold">
          {chosen?.name ?? "Your assistant"}
        </span>
        <span className="truncate text-xs text-muted-foreground">
          {chosen
            ? `${chosen.status} · ${communityName ?? "Connected community"}`
            : communityName || "Connected community"}
        </span>
      </SidebarHeader>
      {communities.length > 1 ? (
        <label className="px-4 pb-3 text-xs text-muted-foreground">
          <span className="mb-2 block">Connection</span>
          <select
            className="min-h-11 w-full rounded-md border bg-background px-2 text-foreground"
            value={activeCommunityId}
            onChange={(event) => onSwitchCommunity(event.target.value)}
          >
            {communities.map((community) => (
              <option key={community.id} value={community.id}>
                {community.name}
              </option>
            ))}
          </select>
        </label>
      ) : null}
      <SidebarContent className="px-3">
        <nav aria-label="Personal assistant" className="space-y-1">
          {destinations.map(({ to, label, icon: Icon }) => {
            const active =
              location.pathname === to ||
              (to === "/today" && location.pathname === "/");
            return (
              <Link
                key={to}
                to={to}
                onClick={close}
                aria-current={active ? "page" : undefined}
                className={`flex min-h-12 items-center gap-3 rounded-lg px-3 text-sm ${active ? "bg-accent font-medium text-accent-foreground" : "text-muted-foreground hover:bg-accent"}`}
              >
                <Icon className="size-5" aria-hidden="true" />
                {label}
              </Link>
            );
          })}
        </nav>
        <div className="mt-4 flex items-center justify-between px-3">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Sessions
          </span>
          <Link
            to="/conversations"
            onClick={close}
            aria-label="New session"
            className="flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-accent"
          >
            <Plus className="size-4" aria-hidden="true" />
          </Link>
        </div>
        {loading ? (
          <p role="status" className="px-3 py-2 text-xs text-muted-foreground">
            Loading sessions…
          </p>
        ) : null}
        {sessionError ? (
          <p className="px-3 py-2 text-xs text-muted-foreground">
            Could not load Hermes sessions. Showing Buzz conversations.
          </p>
        ) : null}
        {channelError ? (
          <button
            type="button"
            className="mx-3 my-2 rounded-md border border-destructive/30 px-3 py-2 text-left text-xs text-destructive"
            onClick={() => {
              void channelsQuery.refetch();
              void idsQuery.refetch();
            }}
          >
            Could not load conversations. Retry
          </button>
        ) : null}
        {!loading && !channelError && sessionCount === 0 ? (
          <p className="px-3 py-2 text-xs text-muted-foreground">
            No sessions yet. Start one in Conversations.
          </p>
        ) : null}
        <div className="mt-1 space-y-1">
          {showHermesSessions
            ? hermesSessions.map((session: AssistantSession) => {
                const channel = session.chat_id
                  ? channelById.get(session.chat_id)
                  : undefined;
                const active = channel
                  ? location.pathname === `/channels/${channel.id}`
                  : false;
                const unread = channel
                  ? topLevelUnreadChannelIds.has(channel.id) ||
                    unreadThreadChannelIds.has(channel.id)
                  : false;
                const working = channel
                  ? workingChannels.some(
                      (entry) => entry.channelId === channel.id,
                    )
                  : false;
                return (
                  <SessionRow
                    key={session.session_id}
                    channel={channel}
                    title={session.title || channel?.name || "Untitled session"}
                    source={session.source === "buzz" ? "Buzz" : session.source}
                    time={sessionTime(session.last_active ?? session.started_at)}
                    active={active}
                    unread={unread}
                    working={working}
                    pinned={channel ? pins.has(channel.id) : false}
                    onTogglePin={
                      channel ? () => togglePin(channel.id) : undefined
                    }
                    onNavigate={close}
                  />
                );
              })
            : null}
          {(showHermesSessions ? unrepresentedChannels : visible).map(
            (channel) => {
              const active = location.pathname === `/channels/${channel.id}`;
              const unread =
                topLevelUnreadChannelIds.has(channel.id) ||
                unreadThreadChannelIds.has(channel.id);
              const working = workingChannels.some(
                (entry) => entry.channelId === channel.id,
              );
              return (
                <SessionRow
                  key={channel.id}
                  channel={channel}
                  title={channel.name}
                  source={showHermesSessions ? "New" : "Buzz"}
                  time={sessionTime(channel.lastMessageAt)}
                  active={active}
                  unread={unread}
                  working={working}
                  pinned={pins.has(channel.id)}
                  onTogglePin={() => togglePin(channel.id)}
                  onNavigate={close}
                />
              );
            },
          )}
        </div>
        {!connectionQuery.data && !connectionQuery.isLoading ? (
          <p className="px-3 py-2 text-xs text-muted-foreground">
            <Link to="/today" onClick={close} className="underline">
              Connect your assistant
            </Link>{" "}
            to see all Hermes sessions.
          </p>
        ) : null}
      </SidebarContent>
      <SidebarFooter className="p-3">
        <Button
          className="min-h-11 justify-start gap-3"
          variant="ghost"
          onClick={() => {
            close();
            onSettings();
          }}
        >
          <Settings className="size-4" aria-hidden="true" />
          Settings
        </Button>
        {communities.length > 1 ? (
          <Button
            variant="ghost"
            className="min-h-11 justify-start"
            onClick={() => {
              close();
              onAddCommunity();
            }}
          >
            Add connection
          </Button>
        ) : null}
        <p className="px-3 text-xs text-muted-foreground">
          Your assistant runs on the server. This device is a window into it.
        </p>
      </SidebarFooter>
      {connectionDialog}
    </Sidebar>
  );
}
