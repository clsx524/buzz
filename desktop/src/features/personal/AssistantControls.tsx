import * as React from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  assistantCommand, assistantStorageMode, clearAssistantConnection, getAssistantDashboard,
  loadAssistantConnection, saveAssistantConnection,
  type AssistantConnection, type AssistantDashboard, type WatchState,
} from "./assistantClient";
import { AssistantActivity } from "./AssistantActivity";
import { AdvancedDetail, AssistantEvidence, AssistantField, assistantButtonClass as button, assistantInputClass as input, assistantError } from "./AssistantEvidence";
import { WatchEditor, type AssistantRun } from "./WatchEditor";

export function AssistantControls({ openConversation }: { openConversation?: (channelId: string) => void }) {
  const queryClient = useQueryClient();
  const [connection, setConnection] = React.useState<AssistantConnection | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState("");
  const [origin, setOrigin] = React.useState("");
  const [profile, setProfile] = React.useState("");
  const [token, setToken] = React.useState("");
  const [saving, setSaving] = React.useState(false);
  const [version, setVersion] = React.useState(0);
  const generation = React.useRef(0);
  React.useEffect(() => {
    const epoch = ++generation.current;
    void loadAssistantConnection().then((saved) => {
      if (epoch !== generation.current) return;
      setConnection(saved); setOrigin(saved?.origin ?? ""); setProfile(saved?.profile ?? "");
    }).catch((failure) => { if (epoch === generation.current) setError(assistantError(failure)); }).finally(() => { if (epoch === generation.current) setLoading(false); });
    return () => { generation.current++; };
  }, []);
  async function connect(event: React.FormEvent) {
    event.preventDefault();
    const epoch = ++generation.current;
    setSaving(true); setError("");
    // Remove the old workspace immediately, fencing in-flight reads and commands.
    setConnection(null);
    try {
      if (!token && connection && (
        new URL(origin.trim()).origin !== new URL(connection.origin).origin ||
        profile.trim() !== connection.profile
      )) {
        throw new Error("Enter a client API token explicitly when changing server or profile. The previous token is never sent to a new destination.");
      }
      const next = { origin: origin.trim(), profile: profile.trim(), token: token || connection?.token || "" };
      await saveAssistantConnection(next);
      await queryClient.invalidateQueries({ queryKey: ["personal-assistant-connection"] });
      await queryClient.invalidateQueries({ queryKey: ["personal-assistant-sessions"] });
      if (epoch !== generation.current) return;
      setToken(""); setConnection(next); setVersion((current) => current + 1);
    } catch (failure) { if (epoch === generation.current) setError(assistantError(failure)); }
    finally { if (epoch === generation.current) setSaving(false); }
  }
  async function disconnect() {
    const epoch = ++generation.current;
    setConnection(null); setToken(""); setSaving(true); setError("");
    try {
      await clearAssistantConnection();
      await queryClient.invalidateQueries({ queryKey: ["personal-assistant-connection"] });
      await queryClient.invalidateQueries({ queryKey: ["personal-assistant-sessions"] });
    }
    catch (failure) { if (epoch === generation.current) setError(assistantError(failure)); }
    finally { if (epoch === generation.current) setSaving(false); }
  }
  return <section aria-label="Personal assistant controls" className="min-w-0 space-y-5 break-words rounded-2xl border p-4 sm:p-5">
    <header><h2 className="text-xl font-semibold">Your assistant</h2><p className="mt-1 text-sm text-muted-foreground">Manage what your assistant monitors and how it gets your attention. Conversations and signed reports remain separate below.</p></header>
    <details open={!connection} className="rounded-lg border p-3"><summary className="min-h-11 cursor-pointer py-3 font-medium">Assistant connection settings</summary>
      <form className="space-y-3" onSubmit={(event) => void connect(event)}><fieldset disabled={loading || saving} className="space-y-3">
        <AssistantField label="Assistant server origin" hint="Your personal-assistant HTTP API origin, without a path or credentials."><input className={input} type="url" required autoComplete="url" placeholder="https://assistant.example.com" value={origin} onChange={(event) => setOrigin(event.target.value)} /></AssistantField>
        <AssistantField label="Assistant profile"><input className={input} required autoComplete="off" value={profile} onChange={(event) => setProfile(event.target.value)} /></AssistantField>
        <AssistantField label="Client API token" hint={connection ? "Leave blank to keep the current client token." : "Use the client API token, not an observer or relay token."}><input className={input} type="password" required={!connection} autoComplete="off" spellCheck={false} value={token} onChange={(event) => setToken(event.target.value)} /></AssistantField>
        <p className="text-xs text-muted-foreground">{assistantStorageMode() === "secure" ? "The token is stored in native secure storage." : "Browser mode: the token stays in module memory for this session only. Reloading requires it again. Origin and profile may be saved, never the token."}</p>
        <div className="flex flex-wrap gap-2"><button className={button} type="submit">{saving ? "Saving connection…" : "Save connection"}</button>{connection ? <button className={button} type="button" onClick={() => void disconnect()}>Disconnect & clear token</button> : null}</div>
      </fieldset></form>
    </details>
    {loading ? <p role="status" className="text-sm">Loading assistant connection…</p> : null}
    {error ? <p role="alert" className="break-words text-sm text-destructive">{error}</p> : null}
    {!loading && !connection ? <p className="text-sm text-muted-foreground">Connect your assistant to see its current state. Nothing is monitored until you explicitly configure a monitor on the server.</p> : null}
    {connection ? <AssistantWorkspace key={version} connection={connection} openConversation={openConversation} /> : null}
  </section>;
}

function AssistantWorkspace({ connection, openConversation }: { connection: AssistantConnection; openConversation?: (channelId: string) => void }) {
  const [dashboard, setDashboard] = React.useState<AssistantDashboard>();
  const [reading, setReading] = React.useState(false);
  const [readError, setReadError] = React.useState("");
  const [commandError, setCommandError] = React.useState("");
  const [pending, setPending] = React.useState(false);
  const [updatedAt, setUpdatedAt] = React.useState<Date>();
  const [editor, setEditor] = React.useState<WatchState | "new" | null>(null);
  const [online, setOnline] = React.useState(() => navigator.onLine);
  const live = React.useRef(false);
  const readEpoch = React.useRef(0);
  const readController = React.useRef<AbortController | null>(null);
  const commandControllers = React.useRef(new Set<AbortController>());
  const commandPending = React.useRef(false);
  const refresh = React.useCallback(async () => {
    const epoch = ++readEpoch.current;
    readController.current?.abort();
    const controller = new AbortController(); readController.current = controller;
    setReading(true); setReadError("");
    try {
      const next = await getAssistantDashboard(connection, controller.signal);
      if (!live.current || epoch !== readEpoch.current) return;
      setDashboard(next); setUpdatedAt(new Date());
    } catch (failure) { if (live.current && epoch === readEpoch.current && !controller.signal.aborted) setReadError(assistantError(failure)); }
    finally { if (live.current && epoch === readEpoch.current) setReading(false); }
  }, [connection]);
  React.useEffect(() => {
    live.current = true;
    void refresh();
    const updateOnline = () => setOnline(navigator.onLine);
    window.addEventListener("online", updateOnline); window.addEventListener("offline", updateOnline);
    return () => {
      live.current = false; readEpoch.current++; readController.current?.abort();
      for (const controller of commandControllers.current) controller.abort();
      window.removeEventListener("online", updateOnline); window.removeEventListener("offline", updateOnline);
    };
  }, [refresh]);
  const run: AssistantRun = async <T,>(command: Record<string, unknown>): Promise<T> => {
    if (commandPending.current) throw new Error("Another assistant request is still pending.");
    const controller = new AbortController(); commandControllers.current.add(controller);
    commandPending.current = true; setPending(true); setCommandError("");
    // An older dashboard read must not overwrite a command's later refresh.
    readEpoch.current++; readController.current?.abort(); setReading(false);
    try {
      const response = await assistantCommand<T>(connection, command, controller.signal);
      if (!live.current || controller.signal.aborted) throw new Error("Connection changed; the request outcome is unknown. Refresh before making another change.");
      return response;
    } catch (failure) {
      if (live.current) setCommandError(assistantError(failure));
      throw failure;
    } finally {
      commandControllers.current.delete(controller); commandPending.current = false;
      if (live.current) setPending(false);
    }
  };
  return <div className="space-y-5">
    <div className="flex flex-wrap items-center justify-between gap-2"><p className="break-words text-sm">Profile <strong>{connection.profile}</strong><span className="block text-xs text-muted-foreground">{connection.origin}</span></p><button className={button} disabled={reading || pending} onClick={() => void refresh()}>Refresh dashboard</button></div>
    {!online ? <p role="alert" className="text-sm text-destructive">You are offline. Last loaded data may be stale; changes are not queued or automatically retried.</p> : null}
    {reading ? <p role="status" className="text-sm">Reading assistant status…</p> : null}
    {readError ? <p role="alert" className="break-words text-sm text-destructive">Unable to refresh: {readError}. {dashboard ? "Showing last loaded data, not current server state." : "Current server state is unavailable."}</p> : null}
    {commandError ? <p role="alert" className="break-words text-sm text-destructive">Request failed: {commandError}. No automatic retry was made. The outcome may be unknown if the response was lost; refresh before repeating a change.</p> : null}
    {pending ? <p role="status" className="text-sm">Waiting for the assistant server…</p> : null}
    {updatedAt ? <p className="text-xs text-muted-foreground">Last loaded {updatedAt.toLocaleString()}{readError || !online ? " · Stale" : ""}</p> : null}
    {dashboard ? <>
      <section aria-label="Assistant runtime" className="space-y-2 rounded-lg border p-3"><p className="font-medium">{dashboard.runtime.ready === true ? "Your assistant is ready" : "Your assistant is waiting for its server"}</p>{typeof dashboard.runtime.last_error === "string" && dashboard.runtime.last_error ? <p role="alert" className="text-sm text-destructive">{dashboard.runtime.last_error}</p> : null}<details><summary className="min-h-11 cursor-pointer py-3 text-sm">Server details</summary><AssistantEvidence value={dashboard.runtime} /></details></section>
      <section aria-label="Monitors" className="space-y-3"><div className="flex flex-wrap items-center justify-between gap-2"><h3 className="text-lg font-semibold">Monitors</h3><button className={button} disabled={pending || editor !== null} onClick={() => setEditor("new")}>Create monitor</button></div>
        {!dashboard.watches.length ? <p className="rounded-lg border border-dashed p-4 text-sm">Nothing is monitored until you explicitly configure a monitor. No account, calendar or source has been selected for you.</p> : null}
        {dashboard.watches.map((watch) => <article key={watch.id} className="space-y-2 rounded-lg border p-4"><h4 className="font-medium">{watch.definition.title}</h4><p className="break-words text-sm text-muted-foreground">{watch.definition.enabled ? "Enabled" : "Paused"} · {watch.definition.tool} · Revision {watch.revision}</p><p className="text-sm">{watch.definition.cron ? `Cron: ${watch.definition.cron} (${watch.definition.timezone ?? "UTC"})` : `Every ${watch.definition.interval_seconds} seconds`}</p>{watch.definition.interest ? <p className="text-sm">{watch.definition.interest}</p> : null}<p className="text-xs text-muted-foreground">{watch.next_runs.length ? `Next runs: ${watch.next_runs.map((time) => new Date(time * 1000).toLocaleString()).join("; ")}` : "No next run supplied by the server."}</p><details><summary className="min-h-11 cursor-pointer py-3 text-sm">Last check and source status</summary><AssistantEvidence value={Object.fromEntries(Object.entries(watch).filter(([key]) => !["definition", "revision", "next_runs", "id"].includes(key)))} /></details><button className={button} disabled={pending || editor !== null} onClick={() => setEditor(watch)}>Edit {watch.definition.title}</button><AdvancedDetail value={watch} /></article>)}
        {editor ? <WatchEditor key={editor === "new" ? "new" : `${editor.id}:${editor.revision}`} state={editor === "new" ? undefined : editor} busy={pending} run={run} onClose={() => setEditor(null)} onSaved={() => { setEditor(null); void refresh(); }} /> : null}
      </section>
      <AssistantActivity dashboard={dashboard} run={run} busy={pending} refresh={() => void refresh()} openConversation={openConversation} />
    </> : null}
  </div>;
}
