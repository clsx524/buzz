import type { RelayEvent } from "@/shared/api/types";

export const ASSISTANT_TYPES = [
  "assistant.finding",
  "assistant.update",
  "assistant.report",
];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const tagValue = (event: RelayEvent, name: string) =>
  event.tags.find((tag) => tag[0] === name)?.[1];
export type AssistantSource = {
  label: string;
  url?: string;
  checkedAt?: number;
};
export type AssistantItem = {
  id: string;
  channelId: string;
  title: string;
  type: string;
  root?: string;
  summary: string;
  body: string;
  topic?: string;
  priority: "normal" | "important";
  requiresInput: boolean;
  sources: AssistantSource[];
  event: RelayEvent;
};
export type AssistantState = {
  version: 1;
  status: "open" | "snoozed" | "archived";
  saved: boolean;
  snoozedUntil?: number;
};
export const OPEN_STATE: AssistantState = {
  version: 1,
  status: "open",
  saved: false,
};

export function safeSourceUrl(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:"
      ? url.href
      : undefined;
  } catch {
    return undefined;
  }
}

export function parseAssistantItem(event: RelayEvent): AssistantItem | null {
  const id = tagValue(event, "d");
  const channelId = tagValue(event, "h");
  const title = tagValue(event, "title");
  const type = tagValue(event, "type");
  if (
    event.kind !== 45010 ||
    tagValue(event, "ar") !== "1" ||
    !id ||
    !UUID.test(id) ||
    !channelId ||
    !title?.trim() ||
    !type ||
    !ASSISTANT_TYPES.includes(type)
  )
    return null;
  try {
    const value = JSON.parse(event.content);
    if (
      value?.version !== 1 ||
      typeof value.summary !== "string" ||
      typeof value.body !== "string" ||
      !["normal", "important"].includes(value.priority) ||
      typeof value.requiresInput !== "boolean" ||
      !Array.isArray(value.sources)
    )
      return null;
    if (
      value.sources.some(
        (source: unknown) =>
          !source ||
          typeof source !== "object" ||
          typeof (source as AssistantSource).label !== "string",
      )
    )
      return null;
    return {
      id,
      channelId,
      title,
      type,
      root: tagValue(event, "root"),
      event,
      summary: value.summary,
      body: value.body,
      priority: value.priority,
      requiresInput: value.requiresInput,
      topic: typeof value.topic === "string" ? value.topic : undefined,
      sources: value.sources.map((source: AssistantSource) => ({
        label: source.label,
        url: safeSourceUrl(source.url),
        checkedAt:
          typeof source.checkedAt === "number" &&
          Number.isFinite(source.checkedAt) &&
          source.checkedAt >= 0
            ? source.checkedAt
            : undefined,
      })),
    };
  } catch {
    return null;
  }
}

export async function assistantStateId(
  pubkey: string,
  itemId: string,
): Promise<string> {
  const namespace = Uint8Array.from([
    0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0,
    0x4f, 0xd4, 0x30, 0xc8,
  ]);
  const name = new TextEncoder().encode(
    `buzz-assistant-state:${pubkey.toLowerCase()}:${itemId}`,
  );
  const input = new Uint8Array(namespace.length + name.length);
  input.set(namespace);
  input.set(name, namespace.length);
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-1", input),
  ).slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export async function parseAssistantState(
  event: RelayEvent,
  viewer: string,
  item: Pick<AssistantItem, "id" | "channelId">,
): Promise<AssistantState | null> {
  if (
    event.kind !== 45010 ||
    event.pubkey !== viewer ||
    tagValue(event, "ar") !== "1" ||
    tagValue(event, "type") !== "assistant.state" ||
    tagValue(event, "owner") !== viewer ||
    tagValue(event, "item") !== item.id ||
    tagValue(event, "h") !== item.channelId ||
    tagValue(event, "d") !== (await assistantStateId(viewer, item.id))
  )
    return null;
  try {
    const value = JSON.parse(event.content);
    if (
      value?.version !== 1 ||
      !["open", "snoozed", "archived"].includes(value.status) ||
      typeof value.saved !== "boolean"
    )
      return null;
    if (
      value.status === "snoozed" &&
      (typeof value.snoozedUntil !== "number" ||
        !Number.isFinite(value.snoozedUntil) ||
        value.snoozedUntil < 0)
    )
      return null;
    return {
      version: 1,
      status: value.status,
      saved: value.saved,
      ...(value.status === "snoozed"
        ? { snoozedUntil: value.snoozedUntil }
        : {}),
    };
  } catch {
    return null;
  }
}

export function isAttentionVisible(state: AssistantState, now: number) {
  return (
    state.status === "open" ||
    (state.status === "snoozed" && (state.snoozedUntil ?? Infinity) <= now)
  );
}

export function resolveAssistantStateChange(
  previous: AssistantState,
  change: Partial<AssistantState>,
  observedRevision: string | null,
  currentRevision: string | null,
): AssistantState {
  if (observedRevision !== currentRevision) {
    throw new Error(
      "This item changed on another device. Refresh its state, review the change, then try again. Nothing was sent.",
    );
  }
  const state = { ...previous, ...change, version: 1 as const };
  if (state.status !== "snoozed") delete state.snoozedUntil;
  return state;
}
