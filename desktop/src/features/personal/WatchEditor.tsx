import * as React from "react";
import type { WatchCondition, WatchDefinition, WatchState } from "./assistantClient";
import { AdvancedDetail, AssistantEvidence, AssistantField, assistantButtonClass as button, assistantInputClass as input, assistantError, objectValue } from "./AssistantEvidence";

export type AssistantRun = <T = Record<string, unknown>>(command: Record<string, unknown>) => Promise<T>;
type Tool = { name: string; description?: string; inputSchema?: unknown; annotations?: unknown };
const mappingKeys = ["result", "pagination", "changes", "baseline"] as const;
function initialMapping(watch?: WatchDefinition) {
  if (!watch) return { result: { encoding: "auto", pointer: "", mode: "snapshot" }, changes: ["added", "updated", "removed"], baseline: "silent" };
  return Object.fromEntries(mappingKeys.filter((key) => watch[key] !== undefined).map((key) => [key, watch[key]]));
}
function parseObject(text: string, name: string) {
  const value: unknown = JSON.parse(text);
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} must be a JSON object.`);
  return value as Record<string, unknown>;
}

export function WatchEditor({ state, busy, run, onSaved, onClose }: {
  state?: WatchState; busy: boolean; run: AssistantRun; onSaved: () => void; onClose: () => void;
}) {
  const original = state?.definition;
  const [id, setId] = React.useState(original?.id ?? "");
  const [title, setTitle] = React.useState(original?.title ?? "");
  const [tool, setTool] = React.useState(original?.tool ?? "");
  const [tools, setTools] = React.useState<Tool[] | null>(null);
  const [argumentsText, setArgumentsText] = React.useState(JSON.stringify(original?.arguments ?? {}, null, 2));
  const [mapping, setMapping] = React.useState(JSON.stringify(initialMapping(original), null, 2));
  const [enabled, setEnabled] = React.useState(original?.enabled ?? true);
  const [schedule, setSchedule] = React.useState(original?.cron ? "cron" : "interval");
  const [interval, setInterval] = React.useState(String(original?.interval_seconds ?? 900));
  const [cron, setCron] = React.useState(original?.cron ?? "");
  const [timezone, setTimezone] = React.useState(original?.timezone ?? "UTC");
  const [interest, setInterest] = React.useState(original?.interest ?? "");
  const [ignore, setIgnore] = React.useState(original?.ignore?.join("\n") ?? "");
  const [conditions, setConditions] = React.useState<WatchCondition[]>(original?.conditions ?? []);
  const [mode, setMode] = React.useState<"digest" | "notify">(original?.attention?.mode ?? "digest");
  const [digest, setDigest] = React.useState(String(original?.attention?.digest_seconds ?? 3600));
  const [quietStart, setQuietStart] = React.useState(original?.attention?.quiet_start ?? "");
  const [quietEnd, setQuietEnd] = React.useState(original?.attention?.quiet_end ?? "");
  const [attentionTimezone, setAttentionTimezone] = React.useState(original?.attention?.timezone ?? "UTC");
  const [preview, setPreview] = React.useState<unknown>();
  const [error, setError] = React.useState("");
  const [confirmDelete, setConfirmDelete] = React.useState(false);
  const selectedTool = tools?.find((entry) => entry.name === tool);
  const edited = () => { setPreview(undefined); setConfirmDelete(false); };
  const positive = (text: string, label: string) => {
    const value = Number(text);
    if (!Number.isInteger(value) || value < 1) throw new Error(`${label} must be a positive whole number.`);
    return value;
  };
  const definition = (): WatchDefinition => {
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$/.test(id)) throw new Error("Use a monitor ID of 1–96 letters, numbers, dots, underscores or hyphens, starting with a letter or number.");
    if (!title.trim() || !tool.trim()) throw new Error("A title and approved source tool are required.");
    const dataMapping = parseObject(mapping, "Data mapping");
    if (Object.keys(dataMapping).some((key) => !(mappingKeys as readonly string[]).includes(key))) throw new Error("Data mapping may contain only result, pagination, changes and baseline.");
    if (schedule === "cron" && !cron.trim()) throw new Error("Enter a cron schedule.");
    if (Boolean(quietStart) !== Boolean(quietEnd)) throw new Error("Set both quiet-hours start and end, or neither.");
    const watch = { ...original, ...dataMapping, id, title: title.trim(), tool: tool.trim(), arguments: parseObject(argumentsText, "Source arguments"), read_only: true, enabled,
      timezone, interest, ignore: ignore.split("\n").map((line) => line.trim()).filter(Boolean), conditions,
      attention: { mode, digest_seconds: positive(digest, "Digest interval"), timezone: attentionTimezone, ...(quietStart ? { quiet_start: quietStart, quiet_end: quietEnd } : {}) },
    } as WatchDefinition;
    for (const key of mappingKeys) if (!(key in dataMapping)) delete watch[key];
    delete watch.cron;
    delete watch.interval_seconds;
    if (schedule === "cron") watch.cron = cron.trim();
    else watch.interval_seconds = positive(interval, "Polling interval");
    return watch;
  };
  async function perform(action: () => Promise<void>) {
    setError("");
    try { await action(); } catch (failure) { setError(assistantError(failure)); }
  }
  function patchCondition(index: number, patch: Partial<WatchCondition>) {
    setConditions((rows) => rows.map((row, i) => i === index ? { ...row, ...patch } : row));
  }
  const previewNextRuns = objectValue(preview).next_runs;
  return <section aria-label={state ? "Edit monitor" : "New monitor"} className="space-y-4 rounded-xl border p-4 sm:p-5">
    <h3 className="text-lg font-semibold">{state ? "Edit monitor" : "New monitor"}</h3>
    <p className="text-sm text-muted-foreground">Choose a read-only source and what matters to you. Nothing is polled until you save an enabled monitor. Preview performs one real source read, without saving.</p>
    <form className="space-y-4" onChange={edited} onSubmit={(event) => { event.preventDefault(); void perform(async () => { await run({ resource: "observer", action: "save", watch: definition(), expected_revision: state?.revision ?? 0 }); onSaved(); }); }}>
      <fieldset disabled={busy} className="min-w-0 space-y-4">
        <AssistantField label="Monitor title"><input className={input} required value={title} onChange={(event) => setTitle(event.target.value)} /></AssistantField>
        <AssistantField label="Monitor ID" hint="Permanent identifier; not a conversation ID."><input className={input} required disabled={Boolean(state)} value={id} onChange={(event) => setId(event.target.value)} /></AssistantField>
        <section className="space-y-3 rounded-lg border p-3" aria-label="Monitor source">
          <h4 className="font-medium">Source</h4>
          <button type="button" className={button} onClick={() => void perform(async () => {
            const response = await run<{ tools: Tool[] }>({ resource: "observer", action: "tools" });
            if (!Array.isArray(response.tools)) throw new Error("The server did not return an approved tools list.");
            setTools(response.tools);
          })}>Retrieve approved source tools</button>
          {tools?.length === 0 ? <p role="status" className="text-sm">No source tools are approved. Ask your server operator to approve a read-only source. Nothing is monitored.</p> : null}
          <AssistantField label="Source tool" hint="Only operator-approved tools can be saved. Tool discovery runs only when you request it.">
            {tools ? <select className={input} value={tool} onChange={(event) => setTool(event.target.value)} required><option value="">Choose a source</option>{tool && !tools.some((item) => item.name === tool) ? <option value={tool}>{tool} (not in retrieved list)</option> : null}{tools.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}</select> : <input className={input} value={tool} onChange={(event) => setTool(event.target.value)} required />}
          </AssistantField>
          {selectedTool ? <div className="space-y-2"><p className="text-sm">{selectedTool.description || "No source description supplied."}</p><h5 className="text-sm font-medium">Source input schema</h5><AssistantEvidence value={selectedTool.inputSchema ?? objectValue(selectedTool).input_schema} /><AdvancedDetail value={selectedTool} /></div> : null}
          <AssistantField label="Source arguments (JSON)" hint="Use the source schema above for account, scope and filter fields."><textarea className={`${input} min-h-28 font-mono`} value={argumentsText} onChange={(event) => setArgumentsText(event.target.value)} /></AssistantField>
        </section>
        <section className="space-y-3" aria-label="Schedule"><h4 className="font-medium">Schedule</h4>
          <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />Monitor enabled</label>
          <AssistantField label="Schedule type"><select className={input} value={schedule} onChange={(event) => setSchedule(event.target.value)}><option value="interval">Regular interval</option><option value="cron">Cron schedule</option></select></AssistantField>
          {schedule === "interval" ? <AssistantField label="Polling interval (seconds)"><input className={input} type="number" min="1" step="1" required value={interval} onChange={(event) => setInterval(event.target.value)} /></AssistantField> : <AssistantField label="Cron expression" hint="Evaluated by the server's Temporal scheduler; preview shows actual next runs."><input className={input} required value={cron} onChange={(event) => setCron(event.target.value)} /></AssistantField>}
          <AssistantField label="Schedule timezone" hint="IANA timezone, for example Europe/London or UTC."><input className={input} required value={timezone} onChange={(event) => setTimezone(event.target.value)} /></AssistantField>
        </section>
        <AssistantField label="What matters to you?" hint="Describe what should get your assistant's attention."><textarea className={input} maxLength={2400} value={interest} onChange={(event) => setInterest(event.target.value)} /></AssistantField>
        <AssistantField label="Ignore" hint="One topic or pattern per line."><textarea className={input} value={ignore} onChange={(event) => setIgnore(event.target.value)} /></AssistantField>
        <section aria-label="Conditions" className="space-y-3"><h4 className="font-medium">Conditions</h4><p className="text-xs text-muted-foreground">Optional factual rules. Pointers use JSON Pointer paths (such as /amount). Count and rate use material changes in a window; absence uses time since the last material change.</p>
          {conditions.map((condition, index) => <fieldset key={index} className="space-y-3 rounded-lg border p-3"><legend className="text-sm">Condition {index + 1}</legend>
            <AssistantField label="Condition ID"><input className={input} required value={condition.id} onChange={(event) => patchCondition(index, { id: event.target.value })} /></AssistantField>
            <AssistantField label="Condition kind"><select className={input} value={condition.kind} onChange={(event) => { const kind = event.target.value as WatchCondition["kind"]; setConditions((rows) => rows.map((row, i) => i !== index ? row : { id: row.id, kind, ...(kind === "absence" ? { duration_seconds: 3600 } : { op: "gt" as const, value: 0, ...(kind === "threshold" || kind === "sustained" ? { pointer: "" } : { window_seconds: 3600 }), ...(kind === "sustained" ? { duration_seconds: 3600 } : {}) }) })); }}><option value="threshold">Numeric threshold</option><option value="count">Change count</option><option value="rate">Change rate</option><option value="sustained">Sustained threshold</option><option value="absence">No material changes</option></select></AssistantField>
            {condition.kind === "threshold" || condition.kind === "sustained" ? <AssistantField label="Value pointer"><input className={input} value={condition.pointer ?? ""} onChange={(event) => patchCondition(index, { pointer: event.target.value })} /></AssistantField> : null}
            {condition.kind !== "absence" ? <div className="grid gap-3 sm:grid-cols-2"><AssistantField label="Comparison"><select className={input} value={condition.op ?? "gt"} onChange={(event) => patchCondition(index, { op: event.target.value as WatchCondition["op"] })}>{["gt", "gte", "lt", "lte", "eq"].map((op, i) => <option key={op} value={op}>{["Greater than", "At least", "Less than", "At most", "Equal to"][i]}</option>)}</select></AssistantField><AssistantField label="Comparison value"><input className={input} type="number" step="any" required value={condition.value ?? 0} onChange={(event) => patchCondition(index, { value: Number(event.target.value) })} /></AssistantField></div> : null}
            {condition.kind === "count" || condition.kind === "rate" ? <AssistantField label="Window (seconds)"><input className={input} type="number" min="1" step="1" required value={condition.window_seconds ?? 3600} onChange={(event) => patchCondition(index, { window_seconds: Number(event.target.value) })} /></AssistantField> : null}
            {condition.kind === "sustained" || condition.kind === "absence" ? <AssistantField label="Duration (seconds)"><input className={input} type="number" min="1" step="1" required value={condition.duration_seconds ?? 3600} onChange={(event) => patchCondition(index, { duration_seconds: Number(event.target.value) })} /></AssistantField> : null}
            <button className={button} type="button" onClick={() => setConditions((rows) => rows.filter((_, i) => i !== index))}>Remove condition {index + 1}</button>
          </fieldset>)}
          <button type="button" className={button} onClick={() => setConditions((rows) => [...rows, { id: `condition-${crypto.randomUUID()}`, kind: "threshold", pointer: "", op: "gt", value: 0 }])}>Add condition</button>
        </section>
        <section aria-label="Attention" className="space-y-3"><h4 className="font-medium">Attention & quiet hours</h4>
          <AssistantField label="Delivery preference"><select className={input} value={mode} onChange={(event) => setMode(event.target.value as "digest" | "notify")}><option value="digest">Include in digest</option><option value="notify">Notify when relevant</option></select></AssistantField>
          <AssistantField label="Digest interval (seconds)"><input className={input} type="number" min="1" step="1" required value={digest} onChange={(event) => setDigest(event.target.value)} /></AssistantField>
          <div className="grid gap-3 sm:grid-cols-2"><AssistantField label="Quiet hours start"><input className={input} type="time" value={quietStart} onChange={(event) => setQuietStart(event.target.value)} /></AssistantField><AssistantField label="Quiet hours end"><input className={input} type="time" value={quietEnd} onChange={(event) => setQuietEnd(event.target.value)} /></AssistantField></div>
          <AssistantField label="Quiet hours timezone"><input className={input} required value={attentionTimezone} onChange={(event) => setAttentionTimezone(event.target.value)} /></AssistantField>
        </section>
        <details><summary className="min-h-11 cursor-pointer py-3 text-sm">Advanced data mapping</summary><AssistantField label="Data mapping (JSON)" hint="result: encoding, pointer, snapshot/records mode and identity/comparison pointers. Optional pagination, changes array, baseline silent/emit. Existing mapping is preserved."><textarea className={`${input} min-h-56 font-mono`} value={mapping} onChange={(event) => setMapping(event.target.value)} /></AssistantField></details>
        <div className="flex flex-wrap gap-2"><button type="button" className={button} onClick={() => void perform(async () => { const response = await run({ resource: "observer", action: "preview", watch: definition() }); setPreview(response.preview ?? response); })}>Preview source & next runs</button><button type="submit" className={button}>Save monitor</button></div>
        {state ? <div className="space-y-2 border-t pt-3"><p className="text-xs text-muted-foreground">Editing revision {state.revision}. Deleting stops monitoring but retains factual history.</p>{confirmDelete ? <div className="flex flex-wrap items-center gap-2"><span className="text-sm">Delete {state.definition.title}?</span><button type="button" className={button} onClick={() => void perform(async () => { await run({ resource: "observer", action: "delete", id: state.id, expected_revision: state.revision }); onSaved(); })}>Confirm delete monitor</button></div> : <button className={button} type="button" onClick={() => setConfirmDelete(true)}>Delete monitor</button>}</div> : null}
      </fieldset>
    </form>
    {error ? <p role="alert" className="break-words text-sm text-destructive">{error}</p> : null}
    {preview !== undefined ? <section aria-label="Source preview" className="space-y-3 rounded-lg border p-3"><h4 className="font-medium">Preview — not saved</h4>{Array.isArray(previewNextRuns) ? <div><h5 className="text-sm font-medium">Scheduled next runs</h5>{previewNextRuns.length ? <ul className="text-sm">{previewNextRuns.map((time, index) => <li key={index}>{typeof time === "number" ? new Date(time * 1000).toLocaleString() : String(time)}</li>)}</ul> : <p className="text-sm text-muted-foreground">No scheduled run returned.</p>}</div> : null}<AssistantEvidence value={preview} /><AdvancedDetail value={preview} /></section> : null}
    <button className={button} type="button" disabled={busy} onClick={onClose}>Close editor</button>
  </section>;
}
