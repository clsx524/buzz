import assert from "node:assert/strict";
import { mock, test } from "node:test";
import {
  AssistantAPIError,
  assistantCommand,
  assistantStorageMode,
  clearAssistantConnection,
  getAssistantDashboard,
  loadAssistantConnection,
  normalizeAssistantConnection,
  saveAssistantConnection,
} from "./assistantClient.ts";

const connection = { origin: "https://assistant.example.com", profile: "personal", token: "client-token" };
const dashboard = { ok: true, profile: "personal", runtime: {}, watches: [], concerns: [], decisions: [], questions: [] };

test("an unconfigured browser observes nothing and tokens live only for this session", async () => {
  const fetch = mock.method(globalThis, "fetch", async () => { throw new Error("unexpected network access"); });
  try {
    await clearAssistantConnection();
    assert.equal(assistantStorageMode(), "session");
    assert.equal(await loadAssistantConnection(), null);
    await saveAssistantConnection(connection);
    const restored = await loadAssistantConnection();
    assert.deepEqual(restored, connection);
    restored.token = "mutated-returned-copy";
    assert.deepEqual(await loadAssistantConnection(), connection);
    await clearAssistantConnection();
    assert.equal(await loadAssistantConnection(), null);
    assert.equal(fetch.mock.callCount(), 0);
  } finally {
    fetch.mock.restore();
  }
});

test("assistant calls pin profile and credential destination and reject redirects", async () => {
  const fetch = mock.method(globalThis, "fetch", async () => Response.json(dashboard));
  try {
    assert.deepEqual(await getAssistantDashboard(connection), dashboard);
    const [url, options] = fetch.mock.calls[0].arguments;
    assert.equal(url, "https://assistant.example.com/api/personal-assistant/personal/dashboard");
    assert.equal(options.headers.Authorization, "Bearer client-token");
    assert.equal(options.redirect, "error");
    assert.equal(options.credentials, "omit");
    assert.equal(options.cache, "no-store");
    assert.equal(options.referrerPolicy, "no-referrer");
    assert.equal(url.includes(connection.token), false);
  } finally {
    fetch.mock.restore();
  }
});

test("CAS mutation carries the exact revision once and propagates the conflict", async () => {
  const fetch = mock.method(globalThis, "fetch", async () => Response.json({ ok: false, error: "watch revision conflict" }, { status: 409 }));
  const command = { resource: "observer", action: "delete", id: "watch-exact", expected_revision: 7 };
  try {
    await assert.rejects(assistantCommand(connection, command), (error) => error instanceof AssistantAPIError && error.status === 409 && error.message.includes("watch revision conflict"));
    assert.equal(fetch.mock.callCount(), 1);
    assert.deepEqual(JSON.parse(fetch.mock.calls[0].arguments[1].body), command);
  } finally {
    fetch.mock.restore();
  }
});

test("feedback and answers retain exact decision, concern, and question identities", async () => {
  const fetch = mock.method(globalThis, "fetch", async () => Response.json({ ok: true }));
  try {
    for (const command of [
      { resource: "feedback", action: "submit", decision_id: 42, signal: "useful", preference: "Only notify for material changes" },
      { resource: "concerns", action: "answer", question_id: "q-exact", answer: "yes" },
      { resource: "concerns", action: "handled", concern_id: "c-exact" },
      { resource: "concerns", action: "snooze", concern_id: "c-exact", seconds: 3600 },
    ]) {
      await assistantCommand(connection, command);
      assert.deepEqual(JSON.parse(fetch.mock.calls.at(-1).arguments[1].body), command);
    }
  } finally {
    fetch.mock.restore();
  }
});

test("offline, non-JSON, auth, and incomplete reads never become empty success", async () => {
  for (const [response, expected] of [
    [async () => { throw new TypeError("Failed to fetch"); }, /Failed to fetch/],
    [async () => new Response("unavailable", { status: 503 }), /HTTP 503.*invalid JSON/],
    [async () => Response.json({ ok: false, error: "Invalid client token" }, { status: 401 }), /Invalid client token/],
    [async () => Response.json({ ...dashboard, watches: undefined }), /unsupported or incomplete/],
    [async () => Response.json({ ...dashboard, profile: "someone-else" }), /unsupported or incomplete/],
  ]) {
    const fetch = mock.method(globalThis, "fetch", response);
    try {
      await assert.rejects(getAssistantDashboard(connection), expected);
      assert.equal(fetch.mock.callCount(), 1);
    } finally {
      fetch.mock.restore();
    }
  }
});

test("connection validation rejects token-bearing or insecure destinations before a request", () => {
  for (const origin of ["https://user:secret@example.com", "https://example.com/other", "https://example.com?token=x", "https://example.com#token", "http://example.com", "file:///tmp"] ) {
    assert.throws(() => normalizeAssistantConnection({ ...connection, origin }));
  }
  for (const origin of ["https://example.com", "http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"]) {
    assert.equal(normalizeAssistantConnection({ ...connection, origin }).origin, origin);
  }
  assert.throws(() => normalizeAssistantConnection({ ...connection, profile: "../other" }));
  assert.throws(() => normalizeAssistantConnection({ ...connection, token: "bad\nheader" }));
});
