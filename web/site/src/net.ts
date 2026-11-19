// Every request this site makes goes through here, to the account server only. The password appears in
// exactly one place: the body of the sign-in request, over HTTPS. It is never stored or logged.
import { config } from "./config";
import { b64, toHex } from "./pairing/protocol";

export interface Session { accessToken: string; refreshToken: string; expiresAt: number }
export class NetError extends Error {
  constructor(readonly kind: "wrongPassword" | "offline" | "rateLimited" | "failed") { super(kind); }
}

const headers = (token?: string): Record<string, string> => ({
  apikey: config.key,
  authorization: `Bearer ${token ?? config.key}`,
  "content-type": "application/json",
});

async function call(path: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(config.url + path, { ...init, credentials: "omit", referrerPolicy: "no-referrer", cache: "no-store" });
  } catch {
    throw new NetError("offline");
  }
}

function toSession(body: { access_token: string; refresh_token: string; expires_in: number }): Session {
  return { accessToken: body.access_token, refreshToken: body.refresh_token, expiresAt: Date.now() + body.expires_in * 1000 };
}

export async function signIn(username: string, password: string): Promise<Session> {
  const res = await call("/auth/v1/token?grant_type=password", {
    method: "POST", headers: headers(), body: JSON.stringify({ email: username.trim().toLowerCase() + config.domain, password }),
  });
  if (res.status === 429) throw new NetError("rateLimited");
  if (res.status === 400 || res.status === 401) throw new NetError("wrongPassword");
  if (!res.ok) throw new NetError("failed");
  return toSession(await res.json());
}

export async function refresh(refreshToken: string): Promise<Session> {
  const res = await call("/auth/v1/token?grant_type=refresh_token", {
    method: "POST", headers: headers(), body: JSON.stringify({ refresh_token: refreshToken }),
  });
  if (!res.ok) throw new NetError(res.status >= 500 ? "failed" : "wrongPassword");
  return toSession(await res.json());
}

export async function signOut(token: string): Promise<void> {
  try { await call("/auth/v1/logout?scope=local", { method: "POST", headers: headers(token) }); } catch { /* best effort */ }
}

export interface Slot { id: string; expiresAt: number }
export async function createSlot(token: string, browserPub: Uint8Array, label: string): Promise<Slot> {
  const res = await call("/rest/v1/pairing_slots", {
    method: "POST", headers: { ...headers(token), prefer: "return=representation" },
    body: JSON.stringify({ browser_pub: toHex(browserPub), device_label: label }),
  });
  if (res.status === 401) throw new NetError("wrongPassword");
  if (!res.ok) throw new NetError("failed");
  const [row] = (await res.json()) as { id: string; expires_at: string }[];
  if (!row) throw new NetError("failed");
  return { id: row.id, expiresAt: Date.parse(row.expires_at) };
}

/** Null until the iPhone has answered. */
export async function pollSlot(token: string, id: string): Promise<{ phonePub: string; sealed: string } | null> {
  const res = await call(`/rest/v1/pairing_slots?id=eq.${encodeURIComponent(id)}&select=phone_pub,sealed`, { headers: headers(token) });
  if (!res.ok) throw new NetError("failed");
  const [row] = (await res.json()) as { phone_pub: string | null; sealed: string | null }[];
  return row?.phone_pub && row.sealed ? { phonePub: row.phone_pub, sealed: row.sealed } : null;
}

export async function deleteSlot(token: string, id: string): Promise<void> {
  try { await call(`/rest/v1/pairing_slots?id=eq.${encodeURIComponent(id)}`, { method: "DELETE", headers: headers(token) }); } catch { /* it expires anyway */ }
}

export { b64 };
