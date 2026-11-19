// A photo's sealed details, as PhotoDetails.swift writes them (dates are ISO 8601, unlike the Reader's).
export interface Photo {
  id: string; owner: string; original: string; thumbnail: string; taken: number; width: number; height: number; type: string;
  byteCount: number; kind: "photo" | "video" | "live"; caption: string; favourite: boolean; trashed: boolean;
}
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const date = (v: unknown): number => { const t = typeof v === "string" ? Date.parse(v) : NaN; return Number.isNaN(t) ? 0 : t; };
const uuid = (v: unknown): string | null => (typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v) ? v.toLowerCase() : null);

export function parsePhoto(rowId: string, raw: unknown, account: string): Photo | null {
  const o = raw as Record<string, unknown> | null;
  const original = uuid(o?.original), thumbnail = uuid(o?.thumbnail);
  // Details that name another account, or another photo, are never shown (PhotoSealer's own rule).
  if (!o || uuid(o.id) !== rowId || str(o.owner).toLowerCase() !== account.toLowerCase() || !original || !thumbnail) return null;
  return {
    id: rowId, owner: account, original, thumbnail, taken: date(o.taken) || date(o.added),
    width: typeof o.width === "number" ? o.width : 0, height: typeof o.height === "number" ? o.height : 0, type: str(o.type),
    byteCount: typeof o.byteCount === "number" ? o.byteCount : 0, kind: o.media === "video" ? "video" : o.media === "live" ? "live" : "photo",
    caption: str(o.caption), favourite: o.isFavourite === true, trashed: o.trashed != null,
  };
}

/** What a browser can show from the original. Anything else (like HEIC) shows its thumbnail instead. */
const SHOWABLE: Record<string, string> = { "public.jpeg": "image/jpeg", "public.png": "image/png", "com.compuserve.gif": "image/gif", "org.webmproject.webp": "image/webp" };
export const showableType = (p: Photo): string | null => (p.kind === "photo" ? SHOWABLE[p.type] ?? null : null);
export const MAX_ORIGINAL_BYTES = 40 * 1024 * 1024;

/** Newest first, with Recently Deleted left out. */
export const library = (all: Photo[]): Photo[] => all.filter((p) => !p.trashed).sort((a, b) => b.taken - a.taken);
