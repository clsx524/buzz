import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import React, { act } from "react";
import { cleanup, fireEvent, render, waitFor, within } from "@testing-library/react";
import { AssistantControls } from "./AssistantControls.tsx";
import { WatchEditor } from "./WatchEditor.tsx";
import { AssistantActivity } from "./AssistantActivity.tsx";
import { AssistantAPIError, clearAssistantConnection, saveAssistantConnection } from "./assistantClient.ts";

const originalFetch = globalThis.fetch;
const connection = { origin: "https://assistant.example", profile: "personal", token: "client-token" };
const empty = () => ({ ok: true, profile: "personal", runtime: { pending_assessments: 0 }, watches: [], concerns: [], decisions: [], questions: [] });
const watch = () => ({ id: "records", revision: 7, next_runs: [1800000000], definition: {
  id: "records", title: "Selected records", tool: "approved_read", arguments: { scope: "mine" }, read_only: true, enabled: true, interval_seconds: 900,
  result: { encoding: "auto", mode: "records", pointer: "/items", id_pointers: ["/id"] },
  pagination: { mode: "cursor", argument: "cursor", next_pointer: "/next", max_pages: 5 }, changes: ["added", "removed"], baseline: "silent",
} });
function json(value, status = 200) { return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } }); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function change(view, label, value) { fireEvent.change(view.getByLabelText(label), { target: { value } }); }
afterEach(async () => { cleanup(); globalThis.fetch = originalFetch; await clearAssistantConnection(); });

test("connection opens a real dashboard without automatic discovery, and read failure retains honest stale data", async () => {
  await saveAssistantConnection(connection);
  const requests = [];
  let offline = false;
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options });
    if (offline) throw new TypeError("Network unavailable");
    return json({ ...empty(), watches: [watch()] });
  };
  const view = render(React.createElement(AssistantControls));
  await view.findByRole("button", { name: "Edit Selected records" });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].options.method, "GET");
  assert.match(requests[0].url, /\/personal\/dashboard$/);
  assert.equal(requests[0].options.headers.Authorization, "Bearer client-token");
  offline = true;
  fireEvent.click(view.getByRole("button", { name: "Refresh dashboard" }));
  await view.findByText(/Showing last loaded data, not current server state/);
  assert.ok(view.getByRole("button", { name: "Edit Selected records" }));
  assert.equal(requests.length, 2);
});

test("late reads from a previous connection cannot replace the new profile dashboard", async () => {
  await saveAssistantConnection(connection);
  let finishOld;
  globalThis.fetch = async (url) => {
    if (url.includes("/personal/")) return await new Promise((resolve) => { finishOld = resolve; });
    return json({ ...empty(), profile: "second", watches: [{ ...watch(), definition: { ...watch().definition, title: "Second profile monitor" } }] });
  };
  const view = render(React.createElement(AssistantControls));
  await waitFor(() => assert.equal(typeof finishOld, "function"));
  // Settings are hidden by a native details element, but remain editable through the actual form.
  fireEvent.click(view.getByText("Assistant connection settings"));
  change(view, "Assistant profile", "second");
  change(view, "Client API token", "second-token");
  fireEvent.submit(view.getByRole("button", { name: "Save connection" }).closest("form"));
  await view.findByRole("button", { name: "Edit Second profile monitor" });
  await act(async () => finishOld(json({ ...empty(), watches: [watch()] })));
  assert.equal(view.queryByRole("button", { name: "Edit Selected records" }), null);
  assert.ok(view.getByRole("button", { name: "Edit Second profile monitor" }));
});

test("changing server without explicitly entering a token never sends the previous secret there", async () => {
  await saveAssistantConnection(connection);
  const requests = [];
  globalThis.fetch = async (url) => { requests.push(url); return json(empty()); };
  const view = render(React.createElement(AssistantControls));
  await view.findByRole("button", { name: "Create monitor" });
  fireEvent.click(view.getByText("Assistant connection settings"));
  change(view, "Assistant server origin", "https://other.example");
  fireEvent.submit(view.getByRole("button", { name: "Save connection" }).closest("form"));
  await view.findByText(/previous token is never sent to a new destination/);
  assert.equal(requests.length, 1);
});

test("new monitor has no source calls until explicitly requested; friendly fields produce a complete CAS create", async () => {
  const commands = [];
  let saved = 0;
  const run = async (command) => {
    commands.push(command);
    if (command.action === "tools") return { ok: true, tools: [{ name: "approved_read", description: "Read records in your chosen scope", inputSchema: { type: "object", properties: { scope: { type: "string", description: "Account scope" } } } }] };
    if (command.action === "preview") return { ok: true, preview: { sample: { status: "healthy" }, next_runs: [1800000000] } };
    return { ok: true };
  };
  const view = render(React.createElement(WatchEditor, { run, busy: false, onSaved: () => saved++, onClose() {} }));
  assert.equal(commands.length, 0);
  change(view, "Monitor title", "Important records"); change(view, "Monitor ID", "important-records");
  fireEvent.click(view.getByRole("button", { name: "Retrieve approved source tools" }));
  await view.findByRole("option", { name: "approved_read" });
  change(view, "Source tool", "approved_read");
  assert.ok(view.getByText("Source input schema"));
  assert.ok(view.getByText("Account scope"));
  change(view, "Source arguments (JSON)", '{"scope":"mine"}');
  change(view, "Schedule type", "cron"); change(view, "Cron expression", "0 9 * * 1-5"); change(view, "Schedule timezone", "Europe/London");
  change(view, "What matters to you?", "Only urgent changes"); change(view, "Ignore", "Routine updates\nArchived records");
  change(view, "Delivery preference", "notify"); change(view, "Digest interval (seconds)", "7200");
  change(view, "Quiet hours start", "22:00"); change(view, "Quiet hours end", "07:00"); change(view, "Quiet hours timezone", "Europe/London");
  fireEvent.click(view.getByRole("button", { name: "Add condition" }));
  change(view, "Condition ID", "high-amount"); change(view, "Condition kind", "sustained"); change(view, "Value pointer", "/amount"); change(view, "Comparison value", "20"); change(view, "Duration (seconds)", "600");
  fireEvent.click(view.getByRole("button", { name: "Preview source & next runs" }));
  await view.findByRole("region", { name: "Source preview" });
  assert.equal(saved, 0);
  assert.deepEqual(commands.map((command) => command.action), ["tools", "preview"]);
  fireEvent.submit(view.getByRole("button", { name: "Save monitor" }).closest("form"));
  await waitFor(() => assert.equal(saved, 1));
  const command = commands.at(-1);
  assert.equal(command.expected_revision, 0);
  assert.equal(command.watch.read_only, true);
  assert.equal(command.watch.cron, "0 9 * * 1-5");
  assert.equal(command.watch.interval_seconds, undefined);
  assert.deepEqual(command.watch.arguments, { scope: "mine" });
  assert.deepEqual(command.watch.ignore, ["Routine updates", "Archived records"]);
  assert.equal(command.watch.conditions[0].kind, "sustained");
  assert.equal(command.watch.conditions[0].duration_seconds, 600);
  assert.equal(command.watch.attention.quiet_end, "07:00");
});

test("edit conflicts retain the draft and never retry; deletion sends exact ID and observed revision", async () => {
  const commands = [];
  let deleted = 0;
  const state = watch();
  const run = async (command) => {
    commands.push(command);
    if (command.action === "save") throw new AssistantAPIError("Stale revision", 409);
    return { ok: true };
  };
  const view = render(React.createElement(WatchEditor, { state, run, busy: false, onSaved: () => deleted++, onClose() {} }));
  change(view, "Monitor title", "My unsaved title");
  fireEvent.submit(view.getByRole("button", { name: "Save monitor" }).closest("form"));
  await view.findByRole("alert");
  assert.match(view.getByRole("alert").textContent, /Conflict \(409\)/);
  assert.equal(view.getByLabelText("Monitor title").value, "My unsaved title");
  assert.equal(commands.length, 1);
  assert.equal(commands[0].expected_revision, 7);
  assert.deepEqual(commands[0].watch.result, state.definition.result);
  assert.deepEqual(commands[0].watch.pagination, state.definition.pagination);
  assert.deepEqual(commands[0].watch.changes, state.definition.changes);
  fireEvent.click(view.getByRole("button", { name: "Delete monitor" }));
  assert.equal(commands.length, 1);
  fireEvent.click(view.getByRole("button", { name: "Confirm delete monitor" }));
  await waitFor(() => assert.equal(deleted, 1));
  assert.deepEqual(commands[1], { resource: "observer", action: "delete", id: "records", expected_revision: 7 });
});

test("findings use exact concern/question/decision IDs, readable evidence and explicit feedback preferences", async () => {
  const commands = [];
  const channels = [];
  const dashboard = { ...empty(),
    concerns: [{ id: "concern-exact", watch_id: "records", record_id: "source-exact", title: "Record changed", status: "waiting", summary: "Amount increased", session_id: "not-a-channel" }],
    questions: [{ id: "question-exact", concern_id: "concern-exact", prompt: "Does this matter?", answer: null, created: 1800000000 }],
    decisions: [{ id: 42, concern_id: "concern-exact", kind: "notify", title: "Relevant change", rationale: "Exceeds your interest threshold", created: 1800000000 }],
  };
  const run = async (command) => {
    commands.push(command);
    return command.action === "inspect" ? {
      ok: true,
      id: "concern-exact",
      events: [{ record_id: "source-exact", payload: '{"after":{"amount":25},"source":"approved_read"}' }],
      conversation_links: [{ session_id: "not-a-channel" }],
      delivery_links: [{ channel_id: "actual-channel-id" }],
    } : { ok: true };
  };
  const view = render(React.createElement(AssistantActivity, { dashboard, run, busy: false, refresh() {}, openConversation: (channel) => channels.push(channel) }));
  assert.equal(view.queryByRole("button", { name: "Open conversation" }), null);
  fireEvent.click(view.getByRole("button", { name: "Inspect evidence" }));
  const evidence = await view.findByRole("region", { name: "Finding evidence" });
  assert.ok(within(evidence).getByText("25"));
  fireEvent.click(view.getByRole("button", { name: "Open conversation" }));
  assert.deepEqual(channels, ["actual-channel-id"]);
  fireEvent.click(view.getByRole("button", { name: "Mark handled" })); await settle();
  change(view, "Snooze duration", "86400"); fireEvent.click(view.getByRole("button", { name: "Snooze finding" })); await settle();
  fireEvent.click(view.getByRole("button", { name: "Resume finding" })); await settle();
  change(view, "Your answer", "Yes, please follow this"); fireEvent.submit(view.getByRole("button", { name: "Send answer" }).closest("form")); await settle();
  fireEvent.click(view.getByText("Give feedback or set a preference"));
  change(view, "Feedback", "digest"); change(view, "Feedback comment", "Useful but not urgent"); change(view, "Preference to remember", "Put routine amount changes in my digest");
  fireEvent.submit(view.getByRole("button", { name: "Submit feedback" }).closest("form"));
  await view.findByText("Feedback saved.");
  assert.deepEqual(commands, [
    { resource: "concerns", action: "inspect", concern_id: "concern-exact" },
    { resource: "concerns", action: "handled", concern_id: "concern-exact" },
    { resource: "concerns", action: "snooze", concern_id: "concern-exact", seconds: 86400 },
    { resource: "concerns", action: "resume", concern_id: "concern-exact" },
    { resource: "concerns", action: "answer", question_id: "question-exact", answer: "Yes, please follow this" },
    { resource: "feedback", action: "submit", decision_id: 42, signal: "digest", comment: "Useful but not urgent", preference: "Put routine amount changes in my digest" },
  ]);
});

test("an ambiguous mutation failure is visible and is never replayed by the workspace", async () => {
  await saveAssistantConnection(connection);
  let mutations = 0;
  globalThis.fetch = async (_url, options) => {
    if (options.method === "GET") return json({ ...empty(), concerns: [{ id: "exact", title: "Check this", status: "active" }] });
    mutations++; throw new TypeError("Connection lost after sending");
  };
  const view = render(React.createElement(AssistantControls));
  fireEvent.click(await view.findByRole("button", { name: "Mark handled" }));
  await view.findByText(/outcome may be unknown/);
  assert.equal(mutations, 1);
  assert.ok(view.getByRole("article", { name: "Finding: Check this" }));
});
