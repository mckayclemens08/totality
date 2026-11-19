// Saving a doc from the website, as ReaderVault.saveNote and SupabaseSyncRemote.upload do it together: both
// parts sealed in this browser, the words stored first as a blob named for their hash, then the row that
// points at them, changed only if it's still the version the editor opened. If another device saved in
// between, the words go to a new doc beside it, "(conflict copy)", as the iPhone's editor does, so nothing
// anyone wrote is lost.
import * as net from "../net";
import * as vault from "../keystore";
import { uuidBytes } from "../pairing/protocol";
import { toByteaLiteral } from "../sealed";
import { copyTitle, newNote, saved, sealNote, type Raw } from "./edit";

export interface Ctx { token: () => Promise<string>; userId: string }
/** A doc as the editor holds it: its details, and the row's hash and storage key it was opened at. */
export interface Open { raw: Raw; hash: string | null; storageKey: string | null }
export type SaveResult = { saved: Open } | { copy: Open };

async function sealWithKeys(raw: Raw, text: string, owner: string) {
  const id = uuidBytes(String(raw.id).toLowerCase());
  const metaKey = await vault.objectKeyBytes("metadata", id), bodyKey = await vault.objectKeyBytes("content", id);
  try { return sealNote(raw, text, owner, metaKey, bodyKey); } finally { metaKey.fill(0); bodyKey.fill(0); }
}

async function put(ctx: Ctx, raw: Raw, text: string, expected: string | null, previousKey: string | null): Promise<Open> {
  const token = await ctx.token();
  const s = await sealWithKeys(raw, text, ctx.userId);
  await net.putBlob(token, s.blob, s.body, s.bodyHash);
  try {
    await net.putSealed(token, ctx.userId, { id: s.id, kind: "note", meta: toByteaLiteral(s.meta), hash: s.hash, size: s.meta.length + s.body.length, storageKey: s.storageKey }, expected);
  } catch (e) {
    // Another device may have landed these same words, so the blob goes only if nothing points at it.
    if (e instanceof net.ChangedOnServer) {
      const now = await net.fetchSealed(token, s.id).catch(() => null);
      if (now?.storageKey !== s.storageKey) await net.deleteBlob(token, s.blob).catch(() => {});
    }
    throw e;
  }
  if (previousKey && previousKey !== s.storageKey) {
    const old = /\/sealed\/([0-9a-f-]{36})$/.exec(previousKey)?.[1];
    if (old) await net.deleteBlob(token, old).catch(() => {});
  }
  return { raw, hash: s.hash, storageKey: s.storageKey };
}

/** ReaderVault.createNote: an empty doc, ready for the editor. */
export const create = (ctx: Ctx, title = ""): Promise<Open> => put(ctx, newNote(title, Date.now()), "", null, null);

/** ReaderVault.saveNote(basedOn:): saves over the version the editor opened, or beside it as a conflict copy. */
export async function save(ctx: Ctx, doc: Open, title: string, text: string): Promise<SaveResult> {
  try {
    return { saved: await put(ctx, saved(doc.raw, title, text, Date.now()), text, doc.hash, doc.storageKey) };
  } catch (e) {
    if (!(e instanceof net.ChangedOnServer)) throw e;
    const folder = typeof doc.raw.folderID === "string" ? doc.raw.folderID : null;
    const copy = newNote(copyTitle(title), Date.now(), folder);
    return { copy: await put(ctx, saved(copy, String(copy.title), text, Date.now()), text, null, null) };
  }
}
