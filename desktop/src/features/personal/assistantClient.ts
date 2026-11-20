import { invoke } from "@tauri-apps/api/core";

export interface AssistantConnection {
  origin: string;
  profile: string;
  token: string;
}

export interface WatchCondition {
  id: string;
  kind: "threshold" | "count" | "rate" | "sustained" | "absence";
  pointer?: string;
  op?: "gt" | "gte" | "lt" | "lte" | "eq";
  value?: number;
  window_seconds?: number;
  duration_seconds?: number;
}

export interface WatchDefinition {
  [key: string]: unknown;
  id: string;
  title: string;
  tool: string;
  arguments: Record<string, unknown>;
  read_only: true;
  enabled: boolean;
  interval_seconds?: number;
  cron?: string;
  timezone?: string;
  interest?: string;
  ignore?: string[];
  attention?: {
    mode: "digest" | "notify";
    digest_seconds: number;
    quiet_start?: string;
    quiet_end?: string;
    timezone?: string;
  };
  conditions?: WatchCondition[];
  result?: Record<string, unknown>;
  pagination?: Record<string, unknown>;
  changes?: string[];
  baseline?: "silent" | "emit";
}

export interface WatchState {
  [key: string]: unknown;
  id: string;
  definition: WatchDefinition;
  revision: number;
  next_runs: number[];
}

export interface AssistantConcern {
  [key: string]: unknown;
  id: string;
  watch_id?: string;
  record_id?: string;
  status: string;
  title: string;
  summary?: string;
}

export interface AssistantDecision {
  [key: string]: unknown;
  id: number;
  concern_id: string;
  kind: string;
  title: string;
  summary?: string;
  rationale?: string;
  created: number;
}

export interface AssistantQuestion {
  [key: string]: unknown;
  id: string;
  concern_id: string;
  prompt: string;
  answer: string | null;
  created: number;
}

export interface AssistantDashboard {
  ok: true;
  profile: string;
  runtime: Record<string, unknown>;
  watches: WatchState[];
  concerns: AssistantConcern[];
  decisions: AssistantDecision[];
  questions: AssistantQuestion[];
}

export interface AssistantSession {
  session_id: string;
  title: string | null;
  source: string;
  chat_id: string | null;
  thread_id: string | null;
  started_at: number;
  ended_at: number | null;
  last_active: number | null;
  message_count: number;
  parent_session_id: string | null;
  archived: boolean;
  pinned: boolean;
  hidden: boolean;
}

export interface AssistantSessions {
  ok: true;
  profile: string;
  sessions: AssistantSession[];
}

export class AssistantAPIError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "AssistantAPIError";
    this.status = status;
  }
}

// Browser development deliberately keeps the entire connection in memory. No
// web storage, service worker, URL, or relay event ever receives this token.
let sessionConnection: AssistantConnection | null = null;

export function assistantStorageMode(): "secure" | "session" {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window
    ? "secure"
    : "session";
}

export function normalizeAssistantConnection(
  connection: AssistantConnection,
): AssistantConnection {
  const url = new URL(connection.origin.trim());
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (
    (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) ||
    url.username || url.password || url.search || url.hash ||
    (url.pathname !== "/" && url.pathname !== "")
  ) {
    throw new Error("Use an HTTPS server origin without credentials, path, query, or fragment (HTTP is allowed on localhost).");
  }
  const profile = connection.profile.trim();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(profile)) {
    throw new Error("Profile must be 1–128 letters, numbers, dots, underscores, or hyphens.");
  }
  const token = connection.token.trim();
  if (!token || /[\r\n]/.test(token)) throw new Error("Enter the assistant client API token.");
  return { origin: url.origin, profile, token };
}

export async function loadAssistantConnection(): Promise<AssistantConnection | null> {
  if (assistantStorageMode() === "session") {
    return sessionConnection ? { ...sessionConnection } : null;
  }
  const connection = await invoke<AssistantConnection | null>("load_personal_assistant_connection");
  return connection ? normalizeAssistantConnection(connection) : null;
}

export async function saveAssistantConnection(connection: AssistantConnection): Promise<void> {
  const normalized = normalizeAssistantConnection(connection);
  if (assistantStorageMode() === "session") {
    sessionConnection = normalized;
    return;
  }
  await invoke("save_personal_assistant_connection", { connection: normalized });
}

export async function clearAssistantConnection(): Promise<void> {
  if (assistantStorageMode() === "session") {
    sessionConnection = null;
    return;
  }
  await invoke("clear_personal_assistant_connection");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function requestAssistant(
  connection: AssistantConnection,
  endpoint: "dashboard" | "command" | "sessions",
  command?: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<Record<string, unknown>> {
  const normalized = normalizeAssistantConnection(connection);
  // An aborted or timed-out mutation has an UNKNOWN outcome. Never replay it.
  const timeoutSignal = AbortSignal.timeout(30_000);
  const response = await fetch(
    `${normalized.origin}/api/personal-assistant/${encodeURIComponent(normalized.profile)}/${endpoint}`,
    {
      method: command ? "POST" : "GET",
      headers: {
        Authorization: `Bearer ${normalized.token}`,
        Accept: "application/json",
        ...(command ? { "Content-Type": "application/json" } : {}),
      },
      ...(command ? { body: JSON.stringify(command) } : {}),
      signal: signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal,
      credentials: "omit",
      redirect: "error",
      cache: "no-store",
      referrerPolicy: "no-referrer",
    },
  );
  const text = await response.text();
  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new AssistantAPIError(`Assistant API returned HTTP ${response.status} with an invalid JSON response.`, response.status);
  }
  if (!response.ok || !isObject(payload) || payload.ok !== true) {
    const detail = isObject(payload) && typeof payload.error === "string"
      ? payload.error
      : "Invalid assistant API response";
    throw new AssistantAPIError(`${detail} (HTTP ${response.status})`, response.status);
  }
  return payload;
}

export async function assistantCommand<T = Record<string, unknown>>(
  connection: AssistantConnection,
  command: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<T> {
  return await requestAssistant(connection, "command", command, signal) as T;
}

export async function getAssistantDashboard(
  connection: AssistantConnection,
  signal?: AbortSignal,
): Promise<AssistantDashboard> {
  const payload = await requestAssistant(connection, "dashboard", undefined, signal);
  if (
    payload.profile !== connection.profile.trim() ||
    !isObject(payload.runtime) ||
    !Array.isArray(payload.watches) || !Array.isArray(payload.concerns) ||
    !Array.isArray(payload.decisions) || !Array.isArray(payload.questions) ||
    !payload.watches.every((watch) => isObject(watch) && typeof watch.id === "string" &&
      Number.isInteger(watch.revision) && isObject(watch.definition) &&
      Array.isArray(watch.next_runs)) ||
    !payload.concerns.every((concern) => isObject(concern) && typeof concern.id === "string" &&
      typeof concern.status === "string" && typeof concern.title === "string") ||
    !payload.decisions.every((decision) => isObject(decision) && Number.isInteger(decision.id) &&
      typeof decision.concern_id === "string") ||
    !payload.questions.every((question) => isObject(question) && typeof question.id === "string" &&
      typeof question.concern_id === "string" && typeof question.prompt === "string")
  ) {
    throw new AssistantAPIError("Assistant dashboard has an unsupported or incomplete response; saved results have not been replaced.", 200);
  }
  return payload as unknown as AssistantDashboard;
}

export async function getAssistantSessions(
  connection: AssistantConnection,
  signal?: AbortSignal,
): Promise<AssistantSessions> {
  const payload = await requestAssistant(connection, "sessions", undefined, signal);
  if (
    payload.profile !== connection.profile.trim() ||
    !Array.isArray(payload.sessions) ||
    !payload.sessions.every(
      (session) =>
        isObject(session) &&
        typeof session.session_id === "string" &&
        typeof session.source === "string" &&
        (session.title === null || typeof session.title === "string") &&
        (session.chat_id === null || typeof session.chat_id === "string") &&
        (session.thread_id === null || typeof session.thread_id === "string") &&
        typeof session.started_at === "number" &&
        (session.ended_at === null || typeof session.ended_at === "number") &&
        (session.last_active === null ||
          typeof session.last_active === "number") &&
        typeof session.message_count === "number" &&
        (session.parent_session_id === null ||
          typeof session.parent_session_id === "string") &&
        typeof session.archived === "boolean" &&
        typeof session.pinned === "boolean" &&
        typeof session.hidden === "boolean",
    )
  ) {
    throw new AssistantAPIError(
      "Assistant sessions have an unsupported or incomplete response.",
      200,
    );
  }
  return payload as unknown as AssistantSessions;
}
