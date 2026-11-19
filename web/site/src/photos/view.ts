import { h } from "../dom";
import * as net from "../net";
import * as vault from "../keystore";
import { fromByteaLiteral, openBlob } from "../sealed";
import { uuidBytes } from "../pairing/protocol";
import type { Ctx } from "../reader/view";
import { library, MAX_ORIGINAL_BYTES, parsePhoto, showableType, type Photo } from "./model";

let run = 0;
// Every picture on screen is a blob: URL made from bytes this page decrypted. They are all revoked when the
// view closes or reloads, so no decrypted image outlives the screen that showed it.
const urls = new Set<string>();
const show = (bytes: Uint8Array, type: string): string => {
  const url = URL.createObjectURL(new Blob([bytes as Uint8Array<ArrayBuffer>], { type }));
  urls.add(url);
  return url;
};
const revokeAll = (): void => { for (const u of urls) URL.revokeObjectURL(u); urls.clear(); };
export const stopPhotos = (): void => { run++; revokeAll(); };

const dec = new TextDecoder();
const open = async (purpose: "photo-details" | "photo-thumbnail" | "photo", sealed: Uint8Array, photo: string) =>
  openBlob(sealed, await vault.objectKeyBytes(purpose, uuidBytes(photo)), photo);
const when = (ms: number) => new Date(ms).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });

export async function showPhotos(into: HTMLElement, ctx: Ctx): Promise<void> {
  const mine = ++run;
  revokeAll();
  const grid = h("div", { class: "photogrid" });
  const note = h("p", { class: "status", role: "status" }, "Opening your photos…");
  const viewer = h("section", { class: "panel detail" }, h("p", { class: "status" }, "Pick a photo to see it larger."));
  into.replaceChildren(h("div", { class: "page-head" }, h("h1", {}, "Photos")), h("p", { class: "sub" }, "Read-only for now. Add and organise photos on your iPhone."), note,
    h("div", { class: "reader" }, h("section", { class: "panel photopanel" }, grid), viewer));

  let photos: Photo[] = [];
  let unreadable = 0;
  try {
    const rows = await net.listObjects(await ctx.token(), ["photo"]);
    for (const row of rows) {
      try {
        if (!row.meta_cipher) throw new Error("meta");
        const details = JSON.parse(dec.decode(await open("photo-details", fromByteaLiteral(row.meta_cipher), row.id)));
        const p = parsePhoto(row.id, details, ctx.userId);
        if (!p) throw new Error("details");
        photos.push(p);
      } catch { unreadable++; }
    }
  } catch (e) {
    if (mine === run) note.textContent = e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your photos. Check your connection.";
    return;
  }
  if (mine !== run) return;
  photos = library(photos);
  note.textContent = photos.length ? (unreadable ? `${unreadable} photo${unreadable === 1 ? "" : "s"} didn't open with your key and ${unreadable === 1 ? "is" : "are"} hidden.` : "") : "No photos yet. Add some on your iPhone and they appear here.";

  const fetchSealed = async (blob: string, max: number): Promise<Uint8Array | null> => {
    const bytes = await net.getBlob(await ctx.token(), blob);
    return bytes && bytes.length <= max ? bytes : null;
  };

  async function pick(p: Photo): Promise<void> {
    const head = h("div", {}, h("div", { class: "sub" }, `${p.kind === "video" ? "Video" : p.kind === "live" ? "Live Photo" : "Photo"} · ${when(p.taken)}`), p.caption ? h("p", { class: "plain-notes" }, p.caption) : null);
    viewer.replaceChildren(head, h("p", { class: "status" }, "Opening…"));
    try {
      let bytes: Uint8Array | null = null, type = "image/jpeg", shownOriginal = false;
      const original = showableType(p);
      if (original && p.byteCount <= MAX_ORIGINAL_BYTES) {
        const sealed = await fetchSealed(p.original, MAX_ORIGINAL_BYTES + 1024);
        if (sealed) { bytes = await open("photo", sealed, p.id); type = original; shownOriginal = true; }
      }
      if (!bytes) {
        const sealed = await fetchSealed(p.thumbnail, 2 * 1024 * 1024);
        if (!sealed) throw new Error("missing");
        bytes = await open("photo-thumbnail", sealed, p.id);
      }
      if (mine !== run) return;
      const img = h("img", { class: "photo-large", src: show(bytes, type), alt: p.caption || `Photo from ${when(p.taken)}` });
      viewer.replaceChildren(head, img, ...(shownOriginal ? [] : [h("p", { class: "sub" }, p.kind === "photo" ? "Shown at preview size. The full file opens on your iPhone." : "Plays on your iPhone for now.")]));
    } catch { if (mine === run) viewer.replaceChildren(head, h("p", { class: "status" }, "Couldn't open this photo. Check your connection, or open it once on your iPhone.")); }
  }

  // Thumbnails are fetched a few at a time, as they're needed, and only the first screenful up front.
  const cells = photos.map((p) => {
    const cell = h("button", { type: "button", class: "photocell", "aria-label": p.caption || `Photo from ${when(p.taken)}`, onclick: () => void pick(p) });
    grid.append(cell);
    return { p, cell };
  });
  const loadThumb = async ({ p, cell }: (typeof cells)[number]) => {
    try {
      const sealed = await fetchSealed(p.thumbnail, 2 * 1024 * 1024);
      if (!sealed || mine !== run) return;
      cell.replaceChildren(h("img", { src: show(await open("photo-thumbnail", sealed, p.id), "image/jpeg"), alt: "" }));
    } catch { /* the cell stays empty */ }
  };
  const watcher = new IntersectionObserver((seen) => {
    for (const s of seen) if (s.isIntersecting) { watcher.unobserve(s.target); const c = cells.find((x) => x.cell === s.target); if (c) void loadThumb(c); }
  }, { rootMargin: "300px" });
  for (const c of cells) watcher.observe(c.cell);
}
