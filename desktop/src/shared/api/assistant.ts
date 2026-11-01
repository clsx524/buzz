import { invokeTauri } from "@/shared/api/tauri";
import type { RelayEvent } from "@/shared/api/types";

/** Read relay-authoritative artifact heads and metadata without losing extensions. */
export async function queryRelayEvents(
  filters: Record<string, unknown>[],
  scope: { relayUrl: string; signerPubkey: string },
): Promise<RelayEvent[]> {
  return invokeTauri<RelayEvent[]>("query_relay_events", {
    filters,
    expectedRelayUrl: scope.relayUrl,
    expectedSignerPubkey: scope.signerPubkey,
  });
}
