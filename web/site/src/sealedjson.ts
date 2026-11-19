// Modules whose whole content sits in an object's sealed details (events, tasks, lists): list the rows, open
// each with its own derived key, and hand back the JSON. Anything that doesn't open is counted, not shown.
import * as net from "./net";
import * as vault from "./keystore";
import { fromByteaLiteral, openBlob } from "./sealed";
import { uuidBytes } from "./pairing/protocol";

export type MetaPurpose = "event" | "task" | "task-list";
const dec = new TextDecoder();

export async function openMeta(purpose: MetaPurpose, metaCipher: string, id: string): Promise<string> {
  const key = await vault.objectKeyBytes(purpose, uuidBytes(id));
  return dec.decode(openBlob(fromByteaLiteral(metaCipher), key, id));
}

export async function loadAll(token: string, kind: string, purpose: MetaPurpose): Promise<{ items: { id: string; json: unknown }[]; unreadable: number }> {
  const rows = await net.listObjects(token, [kind]);
  const items: { id: string; json: unknown }[] = [];
  let unreadable = 0;
  for (const row of rows) {
    try {
      if (!row.meta_cipher) throw new Error("meta");
      items.push({ id: row.id, json: JSON.parse(await openMeta(purpose, row.meta_cipher, row.id)) });
    } catch { unreadable++; }
  }
  return { items, unreadable };
}
