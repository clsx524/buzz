import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  testMatch: "personal-assistant-controls.spec.ts",
  timeout: 30_000,
  retries: 0,
  workers: 1,
  use: { baseURL: "http://127.0.0.1:1420", trace: "retain-on-failure" },
  projects: [
    { name: "desktop", use: { viewport: { width: 1280, height: 900 } } },
    { name: "mobile-viewport", use: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
  ],
  webServer: {
    command: "pnpm dev --host 127.0.0.1",
    url: "http://127.0.0.1:1420/src/features/personal/assistant.html",
    reuseExistingServer: !process.env.CI,
  },
});
