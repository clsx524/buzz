import { Link, useLocation } from "@tanstack/react-router";
import { BookOpen, CalendarDays, MessageCircle, Settings } from "lucide-react";
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
  const close = () => {
    if (isMobile) setOpenMobile(false);
  };
  const destinations = [
    { to: "/today", label: "Today", icon: CalendarDays },
    { to: "/conversations", label: "Conversations", icon: MessageCircle },
    { to: "/library", label: "Library", icon: BookOpen },
  ] as const;
  return (
    <Sidebar>
      <SidebarHeader className="gap-1 p-5">
        <span className="text-lg font-semibold">Your assistant</span>
        <span className="truncate text-xs text-muted-foreground">
          {communityName || "Connected community"}
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
              (to === "/today" && location.pathname === "/") ||
              (to === "/conversations" &&
                location.pathname.startsWith("/channels/"));
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
        <p className="px-3 text-xs text-muted-foreground">
          Your assistant runs on the server. This device is a window into it.
        </p>
      </SidebarFooter>
      {connectionDialog}
    </Sidebar>
  );
}
