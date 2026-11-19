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

// ---- This browser on the account's Devices list (supabase/migrations/20261119000003_web_browsers.sql) ----
async function rpc(token: string, name: string, args: Record<string, unknown>): Promise<unknown> {
  const res = await call(`/rest/v1/rpc/${name}`, { method: "POST", headers: headers(token), body: JSON.stringify(args) });
  if (res.status === 401) throw new NetError("wrongPassword");
  if (!res.ok) throw new NetError("failed");
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}
/** "ok", or "removed" when this browser was removed from the iPhone. Adds it to the list the first time. */
export async function browserCheckIn(token: string, label: string): Promise<"ok" | "removed"> {
  return (await rpc(token, "browser_check_in", { p_label: label })) === "removed" ? "removed" : "ok";
}
export async function browserMatrixDevice(token: string, device: string | null): Promise<void> {
  await rpc(token, "browser_set_matrix_device", { p_device: device });
}
export async function browserForget(token: string): Promise<void> {
  try { await rpc(token, "browser_forget", {}); } catch { /* the session ends anyway */ }
}

export interface ObjectRow { id: string; kind: string; meta_cipher: string | null; storage_key: string | null; byte_size: number | null; content_hash?: string | null }

/** The signed-in account's live docs and files, a page at a time (the server stops at its own page size). */
export async function listObjects(token: string, kinds: string[] = ["note", "file"]): Promise<ObjectRow[]> {
  const rows: ObjectRow[] = [];
  const page = 500;
  for (let from = 0; ; from += page) {
    const res = await call(`/rest/v1/content_objects?select=id,kind,meta_cipher,storage_key,byte_size,content_hash&kind=in.(${kinds.join(",")})&deleted_at=is.null&order=id`, {
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

// ---- Messages: the Matrix server (matrix.usetotality.com). Bearer tokens only, never cookies. ----
const MATRIX = "https://matrix.usetotality.com";
async function matrix(path: string, init: RequestInit & { token?: string }): Promise<Response> {
  const { token, ...rest } = init;
  try {
    return await fetch(MATRIX + path, {
      ...rest, credentials: "omit", referrerPolicy: "no-referrer", cache: "no-store",
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(rest.body ? { "content-type": "application/json" } : {}) },
    });
  } catch { throw new NetError("offline"); }
}

/** A one-minute pass for the Matrix server, from the account server's matrix-login function. */
export async function matrixPass(token: string): Promise<string> {
  const res = await call("/functions/v1/matrix-login", { method: "POST", headers: headers(token), body: "{}" });
  if (res.status === 401) throw new NetError("wrongPassword");
  if (!res.ok) throw new NetError("failed");
  const body = (await res.json()) as { token?: unknown };
  if (typeof body.token !== "string") throw new NetError("failed");
  return body.token;
}

/** Signs a new Matrix device in with that pass. */
export async function matrixLogin(pass: string, deviceName: string): Promise<{ userId: string; deviceId: string; accessToken: string }> {
  const res = await matrix("/_matrix/client/v3/login", { method: "POST", body: JSON.stringify({ type: "org.matrix.login.jwt", token: pass, initial_device_display_name: deviceName }) });
  if (res.status === 429) throw new NetError("rateLimited");
  if (!res.ok) throw new NetError(res.status === 401 || res.status === 403 ? "wrongPassword" : "failed");
  const b = (await res.json()) as { user_id?: unknown; device_id?: unknown; access_token?: unknown };
  if (typeof b.user_id !== "string" || typeof b.device_id !== "string" || typeof b.access_token !== "string") throw new NetError("failed");
  return { userId: b.user_id, deviceId: b.device_id, accessToken: b.access_token };
}

/** Logs a Matrix device out; the server deletes it and its keys. Best effort, a few seconds at most. */
export async function matrixLogout(token: string): Promise<void> {
  const quit = new AbortController();
  const timer = setTimeout(() => quit.abort(), 4000);
  try { await matrix("/_matrix/client/v3/logout", { method: "POST", token, body: "{}", signal: quit.signal }); } catch { /* best effort */ }
  clearTimeout(timer);
}

/** One file from this server's media store (signed in). Callers pass only mxc://usetotality.com/ addresses. */
export async function matrixMedia(token: string, mxc: string, max: number): Promise<Uint8Array> {
  const m = /^mxc:\/\/usetotality\.com\/([A-Za-z0-9_-]+)$/.exec(mxc);
  if (!m) throw new NetError("failed");
  const res = await matrix(`/_matrix/client/v1/media/download/usetotality.com/${m[1]}`, { token });
  if (!res.ok) throw new NetError(res.status === 401 ? "wrongPassword" : "failed");
  const size = Number(res.headers.get("content-length") ?? "0");
  if (size > max) throw new NetError("failed");
  // Read in pieces and stop past the limit, so a server that sends no length can't fill memory.
  const reader = res.body?.getReader();
  if (!reader) throw new NetError("failed");
  const parts: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > max) { await reader.cancel().catch(() => {}); throw new NetError("failed"); }
    parts.push(value);
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const p of parts) { bytes.set(p, at); at += p.length; }
  return bytes;
}

export { b64 };

// ---- Writes (website editing). The row holds only ciphertext and its hash, as SupabaseSyncRemote writes it.
// Every change names the hash it expects, so two devices can't overwrite each other unseen. Row-level
// security limits every query to the signed-in account; inserts name the owner, which the policy checks.

export interface SealedRow { id: string; kind: string; meta: string | null; hash: string | null; deleted: boolean; storageKey?: string | null }
const hashHex = (literal: string | null): string | null => (literal && literal.startsWith("\\x") ? literal.slice(2) : null);
const rowOf = (r: { id: string; kind: string; meta_cipher: string | null; content_hash: string | null; deleted_at: string | null; storage_key?: string | null }): SealedRow =>
  ({ id: r.id.toLowerCase(), kind: r.kind, meta: r.meta_cipher, hash: hashHex(r.content_hash), deleted: r.deleted_at !== null, storageKey: r.storage_key ?? null });

/** Live rows of some kinds with their hashes, a page at a time. */
export async function listSealed(token: string, kinds: string[]): Promise<SealedRow[]> {
  const rows: SealedRow[] = [];
  const page = 500;
  for (let from = 0; ; from += page) {
    const res = await call(`/rest/v1/content_objects?select=id,kind,meta_cipher,content_hash,deleted_at&kind=in.(${kinds.join(",")})&deleted_at=is.null&order=id`, {
      headers: { ...headers(token), "range-unit": "items", range: `${from}-${from + page - 1}` },
    });
    if (res.status === 401) throw new NetError("wrongPassword");
    if (!res.ok && res.status !== 206) throw new NetError("failed");
    const got = (await res.json()) as Parameters<typeof rowOf>[0][];
    rows.push(...got.map(rowOf));
    if (got.length < page || rows.length > 50_000) return rows;
  }
}

/** One row as the server has it now, tombstones included, or null when there is none. */
export async function fetchSealed(token: string, id: string): Promise<SealedRow | null> {
  const res = await call(`/rest/v1/content_objects?select=id,kind,meta_cipher,content_hash,deleted_at,storage_key&id=eq.${encodeURIComponent(id)}`, { headers: headers(token) });
  if (res.status === 401) throw new NetError("wrongPassword");
  if (!res.ok) throw new NetError("failed");
  const [row] = (await res.json()) as Parameters<typeof rowOf>[0][];
  return row ? rowOf(row) : null;
}

/** The server's copy isn't the one the change was made from. Fetch it and try again. */
export class ChangedOnServer extends Error { constructor() { super("changedOnServer"); } }

async function changed(res: Response): Promise<void> {
  if (res.status === 401) throw new NetError("wrongPassword");
  if (res.status === 409) throw new ChangedOnServer();
  if (!res.ok) throw new NetError("failed");
  const rows = (await res.json()) as unknown[];
  if (!rows.length) throw new ChangedOnServer();
}

const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/**
 * Saves sealed details with no body. `expected` is the hash the change was made from: null for a new row,
 * "deleted" to bring back a row another device deleted (an edit beats a delete, as SyncEngine has it).
 */
export async function putSealed(token: string, owner: string, row: { id: string; kind: string; meta: string; hash: string; size: number; storageKey?: string }, expected: string | null | "deleted"): Promise<void> {
  if (!uuidRe.test(row.id) || !/^[0-9a-f]{64}$/.test(row.hash) || !/^[a-z_]+$/.test(row.kind)) throw new NetError("failed");
  // A body lives only under this account's own sealed-store key (SealedBlobKey.key).
  if (row.storageKey !== undefined && !new RegExp(`^${owner.toLowerCase()}/sealed/[0-9a-f-]{36}$`).test(row.storageKey)) throw new NetError("failed");
  const body: Record<string, unknown> = { storage_key: row.storageKey ?? null, byte_size: row.size, content_hash: "\\x" + row.hash, meta_cipher: row.meta, deleted_at: null };
  let res: Response;
  if (expected === null) {
    res = await call("/rest/v1/content_objects?select=id", {
      method: "POST", headers: { ...headers(token), prefer: "return=representation" },
      body: JSON.stringify({ ...body, id: row.id, kind: row.kind, owner_id: owner, key_ref: `crk:${row.id}` }),
    });
  } else {
    const match = expected === "deleted" ? "deleted_at=not.is.null" : `content_hash=eq.${encodeURIComponent("\\x" + expected)}`;
    res = await call(`/rest/v1/content_objects?id=eq.${row.id}&kind=eq.${row.kind}&${match}&select=id`, {
      method: "PATCH", headers: { ...headers(token), prefer: "return=representation" }, body: JSON.stringify(body),
    });
  }
  await changed(res);
}

/** Marks a row deleted, only if it's still the version the person saw. */
export async function tombstoneSealed(token: string, id: string, expected: string): Promise<void> {
  if (!uuidRe.test(id) || !/^[0-9a-f]{64}$/.test(expected)) throw new NetError("failed");
  const res = await call(`/rest/v1/content_objects?id=eq.${id}&content_hash=eq.${encodeURIComponent("\\x" + expected)}&select=id`, {
    method: "PATCH", headers: { ...headers(token), prefer: "return=representation" },
    body: JSON.stringify({ deleted_at: new Date().toISOString(), meta_cipher: null, storage_key: null, content_hash: null, byte_size: 0 }),
  });
  await changed(res);
}

// ---- the sealed store (server/blobs): resumable uploads, as SealedStoreClient sends them ----

async function blobCall(token: string, id: string, init: RequestInit): Promise<Response> {
  if (!uuidRe.test(id)) throw new NetError("failed");
  try {
    return await fetch(config.blobUrl + id, { ...init, headers: { authorization: `Bearer ${token}`, ...(init.headers as Record<string, string> | undefined) }, credentials: "omit", referrerPolicy: "no-referrer", cache: "no-store" });
  } catch { throw new NetError("offline"); }
}
const blobFailed = (status: number): NetError => new NetError(status === 401 ? "wrongPassword" : status === 429 ? "rateLimited" : "failed");

/**
 * Stores one sealed blob under `id` (SealedStoreClient.put): asks how far an earlier try got, sends the
 * rest, then finishes it with its size and SHA-256 so the server checks every byte arrived. A blob already
 * finished with the same size is an earlier try that landed.
 */
export async function putBlob(token: string, id: string, sealed: Uint8Array, sha256Hex: string): Promise<void> {
  if (!sealed.length || !/^[0-9a-f]{64}$/.test(sha256Hex)) throw new NetError("failed");
  const head = await blobCall(token, id, { method: "HEAD" });
  let offset = 0;
  if (head.status === 200) {
    if (head.headers.get("blob-state") === "done") { if (Number(head.headers.get("blob-size")) === sealed.length) return; throw new NetError("failed"); }
    offset = Number(head.headers.get("upload-offset") ?? 0);
    if (!(offset >= 0 && offset <= sealed.length)) { await deleteBlob(token, id); offset = 0; }
  } else if (head.status !== 404) throw blobFailed(head.status);
  const piece = 8 * 1024 * 1024;
  for (let corrections = 0; offset < sealed.length;) {
    const end = Math.min(offset + piece, sealed.length);
    const res = await blobCall(token, id, { method: "PATCH", body: sealed.slice(offset, end), headers: { "upload-offset": String(offset), "content-type": "application/octet-stream" } });
    if (res.status === 204) { offset = Number(res.headers.get("upload-offset")); if (offset !== end) throw new NetError("failed"); continue; }
    if (res.status === 409 && ++corrections <= 3) {
      if (res.headers.get("blob-state") === "done") return;
      offset = Number(res.headers.get("upload-offset"));
      if (!(offset >= 0 && offset <= sealed.length)) throw new NetError("failed");
      continue;
    }
    throw blobFailed(res.status);
  }
  const done = await blobCall(token, id, { method: "POST", body: JSON.stringify({ size: sealed.length, sha256: sha256Hex }), headers: { "content-type": "application/json" } });
  if (done.status === 201) return;
  if (done.status === 409) {
    const now = await blobCall(token, id, { method: "HEAD" });
    if (now.headers.get("blob-state") === "done" && Number(now.headers.get("blob-size")) === sealed.length) return;
  }
  if (done.status === 400) await deleteBlob(token, id).catch(() => {});
  throw blobFailed(done.status);
}

export async function deleteBlob(token: string, id: string): Promise<void> {
  const res = await blobCall(token, id, { method: "DELETE" });
  if (res.status !== 204 && res.status !== 404) throw blobFailed(res.status);
}
