// The Matrix sign-in for this browser, kept apart from the SDK so signing out never has to load it.
// The access token is sealed under a non-extractable key on "my computer" and never written anywhere else.
import * as vault from "../keystore";
import * as net from "../net";

export interface MatrixSession { userId: string; deviceId: string; accessToken: string }
const NAME = "matrix";
let current: MatrixSession | null = null;

export const cryptoPrefix = (userId: string): string => `totality-matrix-${userId}`;

export async function loadMatrixSession(): Promise<MatrixSession | null> {
  current ??= await vault.loadSealed<MatrixSession>(NAME);
  return current;
}
export async function keepMatrixSession(s: MatrixSession): Promise<void> {
  current = s;
  await vault.saveSealed(NAME, s);
}

/** Deletes this browser's crypto store, so nothing of a device outlives its session. */
export async function deleteCryptoStore(userId: string): Promise<void> {
  const prefix = cryptoPrefix(userId);
  const names = (await indexedDB.databases?.().catch(() => [])) ?? [];
  const known = names.map((d) => d.name).filter((n): n is string => !!n && n.startsWith(prefix));
  for (const n of new Set([...known, `${prefix}::matrix-sdk-crypto`, `${prefix}::matrix-sdk-crypto-meta`])) {
    await new Promise<void>((resolve) => { const r = indexedDB.deleteDatabase(n); r.onsuccess = r.onerror = r.onblocked = () => resolve(); });
  }
}

let stopEngine: (() => Promise<void>) | null = null;
export const onEngineStop = (stop: (() => Promise<void>) | null): void => { stopEngine = stop; };

/** Sign out: logs this browser's Matrix device out (the server deletes it and its keys), then wipes it here. */
export async function signOutMessages(): Promise<void> {
  const s = current ?? (await vault.loadSealed<MatrixSession>(NAME));
  current = null;
  await stopEngine?.().catch(() => {});
  stopEngine = null;
  if (!s) return;
  await net.matrixLogout(s.accessToken);
  await vault.dropSealed(NAME);
  await deleteCryptoStore(s.userId);
}

/** The device was logged out elsewhere (for example removed on the iPhone): forget it here. */
export async function forgetMatrixSession(): Promise<void> {
  const s = current ?? (await vault.loadSealed<MatrixSession>(NAME));
  current = null;
  await vault.dropSealed(NAME);
  if (s) await deleteCryptoStore(s.userId);
}
