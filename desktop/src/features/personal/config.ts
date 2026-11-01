export const PERSONAL_ASSISTANT_MODE =
  import.meta.env?.VITE_BUZZ_PERSONAL_ASSISTANT !== "0";

export function personalStorageKey(
  relayUrl: string,
  pubkey: string,
  name: string,
) {
  return `buzz:personal:${encodeURIComponent(relayUrl)}:${pubkey.toLowerCase()}:${name}`;
}

export function readPersonalPreference(
  relayUrl: string,
  pubkey: string,
  name: string,
): string | null {
  return localStorage.getItem(personalStorageKey(relayUrl, pubkey, name));
}

export function writePersonalPreference(
  relayUrl: string,
  pubkey: string,
  name: string,
  value: string,
) {
  localStorage.setItem(personalStorageKey(relayUrl, pubkey, name), value);
}
