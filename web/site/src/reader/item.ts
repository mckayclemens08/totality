// A Reader item's sealed details, as ReaderItem.swift encodes them. JSONEncoder writes dates as seconds since
// 2001-01-01, so that is what `updatedAt` is until it is converted here.
const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);

export type ItemKind = "note" | "file" | "folder" | "journal";
export interface ReaderItem {
  id: string; kind: ItemKind; title: string; mime: string | null; byteCount: number;
  updatedAt: number; folderID: string | null;
}

export function parseItem(json: string): ReaderItem | null {
  let raw: Record<string, unknown>;
  try { raw = JSON.parse(json) as Record<string, unknown>; } catch { return null; }
  const kind = raw.kind;
  if (typeof raw.id !== "string" || (kind !== "note" && kind !== "file" && kind !== "folder" && kind !== "journal")) return null;
  const updated = typeof raw.updatedAt === "number" ? raw.updatedAt : 0;
  return {
    id: raw.id.toLowerCase(), kind, title: typeof raw.title === "string" ? raw.title : "",
    mime: typeof raw.mime === "string" ? raw.mime : null, byteCount: typeof raw.byteCount === "number" ? raw.byteCount : 0,
    updatedAt: APPLE_EPOCH_MS + updated * 1000, folderID: typeof raw.folderID === "string" ? raw.folderID.toLowerCase() : null,
  };
}

export const displayTitle = (i: ReaderItem): string => (i.title.trim() ? i.title : "Untitled");

export function typeName(i: ReaderItem): string {
  if (i.kind === "folder") return "Folder";
  if (i.kind === "note") return "Doc";
  if (i.mime === "application/pdf") return "PDF";
  if (i.mime === "application/epub+zip") return "EPUB";
  return "File";
}

/** The library lists docs and files. A journal is private and has its own place, and folders come later. */
export const inLibrary = (i: ReaderItem): boolean => i.kind === "note" || i.kind === "file";

/** The sealed-store blob a row's storage key names, or null for anything else (like an old bucket path). */
export function blobIdFromKey(key: string | null, owner: string): string | null {
  const m = key && new RegExp(`^${owner.toLowerCase()}/sealed/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$`).exec(key);
  return m ? m[1]! : null;
}
