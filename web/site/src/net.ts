// Every request this site makes goes through here, to the account server only. The password appears in
// exactly one place: the body of the sign-in request, over HTTPS. It is never stored or logged.
import { config } from "./config";
import { b64, toHex } from "./pairing/protocol";

export interface Session { accessToken: string; refreshToken: string; expiresAt: number; userId: string; username: string }
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

function toSession(body: { access_token: string; refresh_token: string; expires_in: number; user: { id: string; email?: string } }): Session {
  return { accessToken: body.access_token, refreshToken: body.refresh_token, expiresAt: Date.now() + body.expires_in * 1000, userId: body.user.id.toLowerCase(), username: (body.user.email ?? "").replace(config.domain, "") };
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

export interface ObjectRow { id: string; kind: string; meta_cipher: string | null; storage_key: string | null; byte_size: number | null }

/** The signed-in account's live docs and files, a page at a time (the server stops at its own page size). */
export async function listObjects(token: string, kinds: string[] = ["note", "file"]): Promise<ObjectRow[]> {
  const rows: ObjectRow[] = [];
  const page = 500;
  for (let from = 0; ; from += page) {
    const res = await call(`/rest/v1/content_objects?select=id,kind,meta_cipher,storage_key,byte_size&kind=in.(${kinds.join(",")})&deleted_at=is.null&order=id`, {
      headers: { ...headers(token), "range-unit": "items", range: `${from}-${from + page - 1}` },
    });
    if (res.status === 401) throw new NetError("wrongPassword");
    if (!res.ok && res.status !== 206) throw new NetError("failed");
    const got = (await res.json()) as ObjectRow[];
    rows.push(...got);
    if (got.length < page || rows.length > 50_000) return rows;
  }
}

/** One sealed blob's bytes, or null when the store doesn't have it. It is ciphertext; the caller opens it. */
export async function getBlob(token: string, id: string): Promise<Uint8Array | null> {
  let res: Response;
  try {
    res = await fetch(config.blobUrl + id, { headers: { authorization: `Bearer ${token}` }, credentials: "omit", referrerPolicy: "no-referrer", cache: "no-store" });
  } catch { throw new NetError("offline"); }
  if (res.status === 404) return null;
  if (!res.ok) throw new NetError(res.status === 401 ? "wrongPassword" : "failed");
  return new Uint8Array(await res.arrayBuffer());
}

export interface MailEntry { id: string; size: number; received: number }
async function mailGet(token: string, path: string): Promise<Response> {
  try { return await fetch(config.mailUrl + path, { headers: { authorization: `Bearer ${token}` }, credentials: "omit", referrerPolicy: "no-referrer", cache: "no-store" }); }
  catch { throw new NetError("offline"); }
}
export async function mailList(token: string): Promise<MailEntry[]> {
  const res = await mailGet(token, "list");
  if (!res.ok) throw new NetError(res.status === 401 ? "wrongPassword" : "failed");
  const body = (await res.json()) as { messages?: { id: string; size: number; received: string | number }[] };
  return (body.messages ?? []).map((m) => ({ id: m.id.toLowerCase(), size: m.size, received: typeof m.received === "number" ? (m.received > 1e11 ? m.received : m.received * 1000) : Date.parse(m.received) || 0 }));
}
export async function mailMessage(token: string, id: string): Promise<Uint8Array | null> {
  const res = await mailGet(token, `message/${id}`);
  if (res.status === 404) return null;
  if (!res.ok) throw new NetError(res.status === 401 ? "wrongPassword" : "failed");
  return new Uint8Array(await res.arrayBuffer());
}

export { b64 };
