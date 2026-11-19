// Modules whose whole content sits in an object's sealed details (events, tasks, lists): list the rows, open
// each with its own derived key, and hand back the JSON. Anything that doesn't open is counted, not shown.
// Writing goes the other way: JSON → sealed in this browser → a row that names the hash it replaces.
import * as net from "./net";
import * as vault from "./keystore";
import { fromByteaLiteral, metaOnlyHash, openBlob, sealBlob, toByteaLiteral } from "./sealed";
import { uuidBytes } from "./pairing/protocol";

export type MetaPurpose = "event" | "task" | "task-list";
const dec = new TextDecoder();
const enc = new TextEncoder();

export async function openMeta(purpose: MetaPurpose, metaCipher: string, id: string): Promise<string> {
  const key = await vault.objectKeyBytes(purpose, uuidBytes(id));
  try { return dec.decode(openBlob(fromByteaLiteral(metaCipher), key, id)); } finally { key.fill(0); }
}

export async function loadAll(token: string, kind: string, purpose: MetaPurpose): Promise<{ items: { id: string; json: unknown }[]; unreadable: number }> {
  const { items, unreadable } = await loadSealed(token, kind, purpose);
  return { items: items.map(({ id, json }) => ({ id, json })), unreadable };
}

/** One sealed item as this browser last saw it on the server. `hash` is what a change must name. */
export interface Held { id: string; json: Record<string, unknown>; hash: string }

/** Opens a row, and proves it is what it says: it opens under this ID's key, and the JSON inside names the same ID. */
async function openRow(row: net.SealedRow, kind: string, purpose: MetaPurpose): Promise<Held> {
  if (row.kind !== kind || !row.meta || !row.hash) throw new Error("row");
  const json = JSON.parse(await openMeta(purpose, row.meta, row.id)) as unknown;
  if (!json || typeof json !== "object" || Array.isArray(json)) throw new Error("shape");
  const inner = (json as { id?: unknown }).id;
  if (typeof inner !== "string" || inner.toLowerCase() !== row.id) throw new Error("id");
  return { id: row.id, json: json as Record<string, unknown>, hash: row.hash };
}

export async function loadSealed(token: string, kind: string, purpose: MetaPurpose): Promise<{ items: Held[]; unreadable: number }> {
  const rows = await net.listSealed(token, [kind]);
  const items: Held[] = [];
  let unreadable = 0;
  for (const row of rows) {
    try { items.push(await openRow(row, kind, purpose)); } catch { unreadable++; }
  }
  return { items, unreadable };
}

/** The server's copy now: the item, "deleted" for a tombstone, or null when there's no row. */
export async function fetchHeld(token: string, id: string, kind: string, purpose: MetaPurpose): Promise<Held | "deleted" | null> {
  const row = await net.fetchSealed(token, id);
  if (!row) return null;
  if (row.deleted) return "deleted";
  return openRow(row, kind, purpose);
}

/** Seals `json` for `id` the way the iPhone's vaults do. Pure apart from the key, so tests can call the parts. */
export async function sealJson(purpose: MetaPurpose, id: string, json: Record<string, unknown>): Promise<{ meta: Uint8Array; hash: string }> {
  if (typeof json.id !== "string" || json.id.toLowerCase() !== id) throw new Error("id");
  const key = await vault.objectKeyBytes(purpose, uuidBytes(id));
  try {
    const meta = sealBlob(enc.encode(JSON.stringify(json)), key, id);
    return { meta, hash: metaOnlyHash(meta) };
  } finally { key.fill(0); }
}

/** Seals and saves. Throws net.ChangedOnServer when the server's copy isn't `expected`; the caller re-reads and retries. */
export async function writeSealed(token: string, owner: string, kind: string, purpose: MetaPurpose, json: Record<string, unknown>, expected: string | null | "deleted"): Promise<Held> {
  const id = String(json.id).toLowerCase();
  const { meta, hash } = await sealJson(purpose, id, json);
  await net.putSealed(token, owner, { id, kind, meta: toByteaLiteral(meta), hash, size: meta.length }, expected);
  return { id, json, hash };
}
