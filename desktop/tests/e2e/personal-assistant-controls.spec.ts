import { expect, test } from "@playwright/test";

// Only tests intercept HTTP. The standalone entry itself uses the production transport.
test("assistant controls stay reachable on desktop and narrow viewports", async ({ page }) => {
  const commands: Record<string, unknown>[] = [];
  let watches: Record<string, unknown>[] = [];
  const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization,content-type", "access-control-allow-methods": "GET,POST,OPTIONS" };
  await page.route("https://assistant.example/api/personal-assistant/personal/**", async (route) => {
    if (route.request().method() === "OPTIONS") {
      await route.fulfill({ status: 204, headers: cors });
      return;
    }
    const command = route.request().method() === "POST" ? route.request().postDataJSON() as Record<string, unknown> : null;
    if (command) commands.push(command);
    let result: Record<string, unknown> = { ok: true };
    if (!command) result = { ok: true, profile: "personal", runtime: { pending_assessments: 0 }, watches, concerns: [], decisions: [], questions: [] };
    else if (command.action === "tools") result.tools = [{ name: "approved_read", description: "Read only the records you choose", inputSchema: { type: "object", properties: { scope: { type: "string" } } } }];
    else if (command.action === "preview") result.preview = { sample: { state: "current", amount: 25 }, next_runs: [1800000000] };
    else if (command.action === "save") {
      const definition = command.watch as Record<string, unknown>;
      watches = [{ id: definition.id, definition, revision: Number(command.expected_revision) + 1, next_runs: [1800000000] }];
      result.watch = watches[0];
    } else if (command.action === "delete") watches = [];
    await route.fulfill({ status: 200, contentType: "application/json", headers: cors, body: JSON.stringify(result) });
  });
  await page.goto("/src/features/personal/assistant.html");
  await page.getByLabel("Assistant server origin", { exact: true }).fill("https://assistant.example");
  await page.getByLabel("Assistant profile", { exact: true }).fill("personal");
  await page.getByLabel("Client API token", { exact: true }).fill("test-client-token");
  await page.getByRole("button", { name: "Save connection", exact: true }).click();
  await expect(page.getByText(/Nothing is monitored until you explicitly configure a monitor/)).toBeVisible();
  expect(commands).toEqual([]);
  await page.getByRole("button", { name: "Create monitor", exact: true }).click();
  await page.getByLabel("Monitor title", { exact: true }).fill("My selected records");
  await page.getByLabel("Monitor ID", { exact: true }).fill("selected-records");
  await page.getByRole("button", { name: "Retrieve approved source tools", exact: true }).click();
  await page.getByLabel("Source tool", { exact: true }).selectOption("approved_read");
  await expect(page.getByText("Source input schema", { exact: true })).toBeVisible();
  await page.getByLabel("Source arguments (JSON)", { exact: true }).fill('{"scope":"mine"}');
  await page.getByLabel("What matters to you?", { exact: true }).fill("Important amount changes");
  await page.getByRole("button", { name: "Add condition", exact: true }).click();
  await page.getByLabel("Condition ID", { exact: true }).fill("amount-high");
  await page.getByLabel("Value pointer", { exact: true }).fill("/amount");
  await page.getByLabel("Comparison value", { exact: true }).fill("20");
  await page.getByLabel("Quiet hours start", { exact: true }).fill("22:00");
  await page.getByLabel("Quiet hours end", { exact: true }).fill("07:00");
  await page.getByRole("button", { name: "Preview source & next runs", exact: true }).click();
  const preview = page.getByRole("region", { name: "Source preview", exact: true });
  await expect(preview.getByText("current", { exact: true })).toBeVisible();
  await expect(preview.getByText("Scheduled next runs", { exact: true })).toBeVisible();
  expect(commands.map((command) => command.action)).toEqual(["tools", "preview"]);
  await page.getByRole("button", { name: "Save monitor", exact: true }).click();
  await page.getByRole("button", { name: "Edit My selected records", exact: true }).click();
  await page.getByLabel("Schedule type", { exact: true }).selectOption("cron");
  await page.getByLabel("Cron expression", { exact: true }).fill("0 9 * * 1-5");
  await page.getByLabel("Schedule timezone", { exact: true }).fill("Europe/London");
  await page.getByRole("button", { name: "Save monitor", exact: true }).click();
  await page.getByRole("button", { name: "Edit My selected records", exact: true }).click();
  await page.getByRole("button", { name: "Delete monitor", exact: true }).click();
  await page.getByRole("button", { name: "Confirm delete monitor", exact: true }).click();
  await expect(page.getByText(/Nothing is monitored until you explicitly configure a monitor/)).toBeVisible();
  const mutations = commands.filter((command) => command.action === "save" || command.action === "delete");
  expect(mutations.map((command) => command.expected_revision)).toEqual([0, 1, 2]);
  expect(mutations[2].id).toBe("selected-records");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  const savedStorage = await page.evaluate(() => JSON.stringify({ local: { ...localStorage }, session: { ...sessionStorage } }));
  expect(savedStorage).not.toContain("test-client-token");
  await page.reload();
  await expect(page.getByLabel("Client API token", { exact: true })).toHaveValue("");
  await expect(page.getByRole("button", { name: "Create monitor", exact: true })).toHaveCount(0);
});
