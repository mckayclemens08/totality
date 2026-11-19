// Where the content key and the sign-in live in this browser (security review #4, #10).
//  - The content key is imported as a NON-EXTRACTABLE HKDF key. Script on the page can use it to derive keys
//    but cannot read it back out. XChaCha20 isn't in WebCrypto, so each object key is derived with
//    deriveBits and lives in memory only briefly.
//  - "My computer": the key and a sealed copy of the sign-in are kept in IndexedDB across restarts.
//  - "Shared computer": nothing is written. Closing the tab, or 30 idle minutes, drops everything.
import type { Session } from "./net";

const DB = "totality-keys", STORE = "keys";
const te = new TextEncoder();

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}
async function idb<T>(mode: IDBTransactionMode, run: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  try {
    return await new Promise<T>((resolve, reject) => {
      const req = run(db.transaction(STORE, mode).objectStore(STORE));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  } finally { db.close(); }
}

let memoryKey: CryptoKey | null = null;

/** Takes the raw key, makes it non-extractable, and wipes the raw bytes. */
export async function adoptContentKey(raw: Uint8Array, keep: boolean): Promise<void> {
  const key = await crypto.subtle.importKey("raw", raw as Uint8Array<ArrayBuffer>, "HKDF", false, ["deriveBits"]);
  raw.fill(0);
  memoryKey = key;
  if (keep) await idb("readwrite", (s) => s.put(key, "content"));
}

export async function loadContentKey(): Promise<CryptoKey | null> {
  if (memoryKey) return memoryKey;
  try { memoryKey = ((await idb("readonly", (s) => s.get("content"))) as CryptoKey | undefined) ?? null; } catch { memoryKey = null; }
  return memoryKey;
}

/** Derives one object's key the way ContentRootKey.objectKey does: HKDF-SHA256, empty salt, info = "totality/<purpose>/v1" + id. */
export async function objectKeyBytes(purpose: string, objectId: Uint8Array): Promise<Uint8Array> {
  const key = await loadContentKey();
  if (!key) throw new Error("locked");
  const info = new Uint8Array([...te.encode(`totality/${purpose}/v1`), ...objectId]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info }, key, 256));
}

/** Drops the key from memory only. The person is still signed in, so the page can ask to unlock again. */
export function lockMemory(): void { memoryKey = null; }

// The sign-in is kept only on "my computer", sealed with a second non-extractable key.
export async function saveSession(s: Session): Promise<void> {
  const wrap = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12)) as Uint8Array<ArrayBuffer>;
  const data = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, wrap, te.encode(JSON.stringify({ r: s.refreshToken })) as Uint8Array<ArrayBuffer>);
  await idb("readwrite", (st) => st.put({ wrap, iv, data }, "session"));
}
export async function loadSessionToken(): Promise<string | null> {
  try {
    const rec = (await idb("readonly", (s) => s.get("session"))) as { wrap: CryptoKey; iv: Uint8Array<ArrayBuffer>; data: ArrayBuffer } | undefined;
    if (!rec) return null;
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: rec.iv }, rec.wrap, rec.data);
    return (JSON.parse(new TextDecoder().decode(plain)) as { r: string }).r;
  } catch { return null; }
}

/** Sign out: nothing stays behind. */
export async function wipe(): Promise<void> {
  memoryKey = null;
  try { await idb("readwrite", (s) => s.clear()); } catch { /* nothing to clear */ }
}
