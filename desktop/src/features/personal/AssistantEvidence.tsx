import * as React from "react";

export const assistantInputClass = "min-h-11 w-full min-w-0 rounded-md border bg-background px-3 py-2 text-sm";
export const assistantButtonClass = "min-h-11 rounded-md border px-3 py-2 text-sm hover:bg-accent disabled:opacity-50";

export function objectValue(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : {};
}

function readable(value: string): unknown {
  if (/^[\[{]/.test(value.trim())) {
    try { return JSON.parse(value); } catch { /* Preserve source text when it is not JSON. */ }
  }
  return value;
}

/** Evidence is readable first; raw source remains available without inventing fields. */
export function AssistantEvidence({ value, depth = 0 }: { value: unknown; depth?: number }) {
  if (value === null || value === undefined) return <span className="text-muted-foreground">Not supplied</span>;
  if (typeof value === "string") {
    const parsed = readable(value);
    if (parsed !== value) return <AssistantEvidence value={parsed} depth={depth} />;
    return <span className="whitespace-pre-wrap break-words">{value || "Empty"}</span>;
  }
  if (typeof value !== "object") return <span>{String(value)}</span>;
  if (depth >= 7) return <pre className="overflow-x-auto whitespace-pre-wrap break-words text-xs">{JSON.stringify(value, null, 2)}</pre>;
  if (Array.isArray(value)) return value.length ? (
    <ul className="space-y-3 border-l pl-3">{value.map((entry, index) => <li key={index}><AssistantEvidence value={entry} depth={depth + 1} /></li>)}</ul>
  ) : <span className="text-muted-foreground">None</span>;
  return <dl className="space-y-2">{Object.entries(value).map(([key, entry]) => (
    <div key={key} className="min-w-0">
      <dt className="text-xs font-medium capitalize text-muted-foreground">{key.replaceAll("_", " ")}</dt>
      <dd className="mt-1 min-w-0 break-words text-sm"><AssistantEvidence value={entry} depth={depth + 1} /></dd>
    </div>
  ))}</dl>;
}

export function AdvancedDetail({ value }: { value: unknown }) {
  return <details className="text-sm"><summary className="min-h-11 cursor-pointer py-3">Advanced source detail</summary><pre className="max-h-96 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 text-xs">{JSON.stringify(value, null, 2)}</pre></details>;
}

export function AssistantField({ label, children, hint }: { label: string; children: React.ReactNode; hint?: string }) {
  return <div className="min-w-0 space-y-1 text-sm"><label className="block space-y-1"><span className="font-medium">{label}</span>{children}</label>{hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}</div>;
}

export function assistantError(error: unknown): string {
  const status = objectValue(error).status;
  const message = error instanceof Error ? error.message : String(error);
  return status === 409 ? `Conflict (409): ${message}. Refresh the dashboard and reopen this monitor before saving or deleting. Your draft has not been replayed.` : `${status ? `HTTP ${status}: ` : ""}${message}`;
}
