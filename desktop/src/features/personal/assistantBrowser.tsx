import * as React from "react";
import { createRoot } from "react-dom/client";
import { AssistantControls } from "./AssistantControls";
import "@fontsource-variable/inter/opsz.css";
import "@/shared/styles/globals.css";

// Standalone Vite entry: no relay bootstrap, mocked IPC, seeded state or observer discovery.
createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <main className="min-h-screen bg-background px-4 py-8 text-foreground">
      <div className="mx-auto max-w-3xl space-y-5">
        <header><h1 className="text-3xl font-semibold">Today</h1><p className="mt-2 text-sm text-muted-foreground">Buzz personal assistant controls · real server API</p></header>
        <AssistantControls />
      </div>
    </main>
  </React.StrictMode>,
);
