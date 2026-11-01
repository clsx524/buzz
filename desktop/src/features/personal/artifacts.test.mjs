import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  assistantStateId,
  isAttentionVisible,
  parseAssistantItem,
  parseAssistantState,
  resolveAssistantStateChange,
} from "./artifacts.ts";

const fixture = JSON.parse(
  await readFile(
    new URL(
      "../../../../test-fixtures/assistant-contract.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const event = {
  id: "a".repeat(64),
  pubkey: "b".repeat(64),
  sig: "c".repeat(128),
  kind: 45010,
  created_at: 1793404800,
  tags: [
    ["ar", "1"],
    ["d", fixture.itemId],
    ["h", fixture.channelId],
    ["type", "assistant.finding"],
    ["title", "Review matching charges"],
    ["op", "create"],
  ],
  content: JSON.stringify(fixture.item),
};

test("assistant artifact boundary preserves evidence but never activates unsafe source URLs", () => {
  const item = parseAssistantItem(event);
  assert.equal(item.requiresInput, true);
  assert.equal(item.sources[0].checkedAt, fixture.item.sources[0].checkedAt);
  const unsafe = parseAssistantItem({
    ...event,
    content: JSON.stringify({
      ...fixture.item,
      sources: [
        { label: "Do not activate", url: "javascript:alert(1)" },
        { label: "File", url: "file:///etc/passwd" },
      ],
    }),
  });
  assert.deepEqual(unsafe.sources, [
    { label: "Do not activate", url: undefined, checkedAt: undefined },
    { label: "File", url: undefined, checkedAt: undefined },
  ]);
  for (const patch of [
    { version: 2 },
    { requiresInput: "yes" },
    { sources: [null] },
    { priority: "urgent" },
  ]) {
    assert.equal(
      parseAssistantItem({
        ...event,
        content: JSON.stringify({ ...fixture.item, ...patch }),
      }),
      null,
    );
  }
});

test("state identity is cross-client deterministic and owner tags cannot forge human state", async () => {
  assert.equal(
    await assistantStateId(fixture.viewer, fixture.itemId),
    fixture.stateId,
  );
  const stateEvent = {
    ...event,
    pubkey: fixture.viewer,
    content: JSON.stringify(fixture.state),
    tags: [
      ["ar", "1"],
      ["d", fixture.stateId],
      ["h", fixture.channelId],
      ["type", "assistant.state"],
      ["owner", fixture.viewer],
      ["item", fixture.itemId],
    ],
  };
  const item = parseAssistantItem(event);
  assert.deepEqual(
    await parseAssistantState(stateEvent, fixture.viewer, item),
    fixture.state,
  );
  assert.equal(
    await parseAssistantState(
      { ...stateEvent, pubkey: "f".repeat(64) },
      fixture.viewer,
      item,
    ),
    null,
  );
  for (const [name, value] of [
    ["d", fixture.itemId],
    ["owner", "f".repeat(64)],
    ["item", fixture.stateId],
    ["h", fixture.stateId],
  ]) {
    const forged = {
      ...stateEvent,
      tags: stateEvent.tags.map((tag) =>
        tag[0] === name ? [name, value] : tag,
      ),
    };
    assert.equal(await parseAssistantState(forged, fixture.viewer, item), null);
  }
  assert.equal(
    isAttentionVisible(fixture.state, fixture.state.snoozedUntil - 1),
    false,
  );
  assert.equal(
    isAttentionVisible(fixture.state, fixture.state.snoozedUntil),
    true,
  );
  assert.equal(
    isAttentionVisible(
      { ...fixture.state, status: "archived" },
      fixture.state.snoozedUntil + 1,
    ),
    false,
  );
});

test("stale cross-device attention state is rejected, not silently rebased", () => {
  assert.throws(
    () =>
      resolveAssistantStateChange(
        fixture.state,
        { saved: false },
        "observed-head",
        "new-device-head",
      ),
    /changed on another device/,
  );
  assert.throws(
    () =>
      resolveAssistantStateChange(
        fixture.state,
        { status: "archived" },
        null,
        "new-device-head",
      ),
    /Nothing was sent/,
  );
  assert.deepEqual(
    resolveAssistantStateChange(
      fixture.state,
      { status: "archived" },
      "same-head",
      "same-head",
    ),
    { version: 1, status: "archived", saved: true },
  );
});
