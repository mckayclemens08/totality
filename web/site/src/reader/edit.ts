// Writing notes the way ReaderVault.swift does. A note is two sealed parts: its details (a ReaderItem, under
// the "metadata" key) and its words (Markdown, under the "content" key). The details are kept as the JSON
// the iPhone sealed, so parts this version doesn't know (a word target, a kept original) ride along.
import { derivedID } from "../ids";
import { bodyHash, itemHash, sealBlob } from "../sealed";

export type Raw = Record<string, unknown>;
/** MarkdownText.mime: what the iPhone's writing editor saves, and so what the website edits. */
export const EDITOR_MIME = "text/markdown; variant=pandoc";
const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);
export const appleNow = (ms = Date.now()): number => (ms - APPLE_EPOCH_MS) / 1000;
let makeID = (): string => crypto.randomUUID().toUpperCase();
export const setIDMaker = (f: () => string): void => { makeID = f; };
const enc = new TextEncoder();

/** Only a doc already in the editor's Markdown is changed here. An older doc is converted once on the iPhone, which keeps its original. */
export const editable = (raw: Raw): boolean => raw.kind === "note" && (raw.mime === EDITOR_MIME || (raw.mime === undefined && raw.byteCount === 0));

/** ReaderVault.createNote: an empty doc in the editor's Markdown. */
export function newNote(title: string, now: number, folderID?: string | null): Raw {
  const at = appleNow(now);
  const out: Raw = { id: makeID(), kind: "note", title, mime: EDITOR_MIME, byteCount: 0, createdAt: at, updatedAt: at, listenPosition: 0 };
  if (folderID) out.folderID = folderID.toUpperCase();
  return out;
}

/** ReaderVault.saveNote: the title, the size of the words, and the time; everything else stays. */
export function saved(raw: Raw, title: string, text: string, now: number): Raw {
  return { ...structuredClone(raw), title, mime: EDITOR_MIME, byteCount: enc.encode(text).length, updatedAt: appleNow(now) };
}

/** saveNote(basedOn:): the words go to a new doc beside it when the note changed underneath the editor. */
export const copyTitle = (title: string): string => `${title === "" ? "Untitled" : title} (conflict copy)`;

/** SealedBlobKey.blob(owner:item:bodyHash:): one version of a body always lands on the same blob. */
export const blobID = (owner: string, item: string, bodyHashHex: string): string =>
  derivedID(`totality/sealed-body/v1/${owner.toLowerCase()}/${item.toLowerCase()}/${bodyHashHex}`).toLowerCase();
export const storageKey = (owner: string, blob: string): string => `${owner.toLowerCase()}/sealed/${blob}`;

export interface SealedNote { id: string; meta: Uint8Array; body: Uint8Array; hash: string; bodyHash: string; blob: string; storageKey: string }

/** Seals both parts with keys already derived. Pure, so the vector tests can call it with test keys and nonces. */
export function sealNote(raw: Raw, text: string, owner: string, metaKey: Uint8Array, bodyKey: Uint8Array, nonces?: [Uint8Array, Uint8Array]): SealedNote {
  const id = String(raw.id).toLowerCase();
  const meta = sealBlob(enc.encode(JSON.stringify(raw)), metaKey, id, nonces?.[0]);
  const body = sealBlob(enc.encode(text), bodyKey, id, nonces?.[1]);
  const b = bodyHash(body), blob = blobID(owner, id, b);
  return { id, meta, body, hash: itemHash(meta, body), bodyHash: b, blob, storageKey: storageKey(owner, blob) };
}
