import { h } from "../dom";
import * as net from "../net";
import * as vault from "../keystore";
import { fromByteaLiteral, openBlob, OpenFailure } from "../sealed";
import { uuidBytes } from "../pairing/protocol";
import { blobIdFromKey, displayTitle, inLibrary, parseItem, typeName, type ReaderItem } from "./item";
import { isMarkdown, parse, plain, type Block, type Run } from "./markdown";

export interface Ctx { token: () => Promise<string>; userId: string }
interface Entry { item: ReaderItem; row: net.ObjectRow }

const dec = new TextDecoder();
const when = (ms: number) => new Date(ms).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
let run = 0;
export const stopReader = (): void => { run++; };

async function open(purpose: "metadata" | "content", sealed: Uint8Array, id: string): Promise<Uint8Array> {
  return openBlob(sealed, await vault.objectKeyBytes(purpose, uuidBytes(id)), id);
}

async function loadLibrary(ctx: Ctx): Promise<{ entries: Entry[]; unreadable: number }> {
  const rows = await net.listObjects(await ctx.token());
  const entries: Entry[] = [];
  let unreadable = 0;
  for (const row of rows) {
    try {
      if (!row.meta_cipher) throw new OpenFailure("meta");
      const item = parseItem(dec.decode(await open("metadata", fromByteaLiteral(row.meta_cipher), row.id)));
      if (!item || item.id !== row.id) throw new OpenFailure("meta");
      if (inLibrary(item)) entries.push({ item, row });
    } catch { unreadable++; }
  }
  entries.sort((a, b) => b.item.updatedAt - a.item.updatedAt);
  return { entries, unreadable };
}

// ---- drawing a note: elements built from the tree with textContent only ----

function runNode(doc: Document, r: Run): Node {
  let node: Node = doc.createTextNode(r.text);
  const wrap = (tag: string, to?: (e: HTMLElement) => void) => { const e = doc.createElement(tag); to?.(e); e.append(node); node = e; };
  if (r.code) wrap("code");
  if (r.bold) wrap("strong");
  if (r.italic) wrap("em");
  if (r.href) wrap("a", (a) => { a.setAttribute("href", r.href!); a.setAttribute("rel", "noopener noreferrer nofollow"); a.setAttribute("target", "_blank"); });
  return node;
}
const runs = (doc: Document, parent: Element, rs: Run[]) => { for (const r of rs) parent.append(runNode(doc, r)); };

export function drawBlocks(doc: Document, into: Element, blocks: Block[]): void {
  for (const b of blocks) {
    if (b.t === "h") { const e = doc.createElement(`h${b.level}`); runs(doc, e, b.runs); into.append(e); }
    else if (b.t === "p") { const e = doc.createElement("p"); runs(doc, e, b.runs); into.append(e); }
    else if (b.t === "code") { const pre = doc.createElement("pre"); const c = doc.createElement("code"); c.textContent = b.text; pre.append(c); into.append(pre); }
    else { const list = doc.createElement(b.t); for (const it of b.items) { const li = doc.createElement("li"); runs(doc, li, it); list.append(li); } into.append(list); }
  }
}

/** A frame that can run no script and sends no request of its own. The page fills it in; nothing in the
 *  note is ever parsed as HTML, and the frame has no way to reach the page's key or session. */
function noteFrame(blocks: Block[]): HTMLIFrameElement {
  const frame = h("iframe", { class: "note-frame", sandbox: "allow-same-origin", title: "Note", referrerpolicy: "no-referrer" });
  frame.addEventListener("load", () => {
    const doc = frame.contentDocument;
    if (!doc) return;
    const sheet = document.querySelector('link[rel="stylesheet"]');
    if (sheet) doc.head.append(sheet.cloneNode(true));
    doc.body.className = "doc";
    drawBlocks(doc, doc.body, blocks);
  });
  return frame;
}

function message(text: string): HTMLElement { return h("p", { class: "status" }, text); }

async function showItem(ctx: Ctx, entry: Entry, pane: HTMLElement, mine: number): Promise<void> {
  const { item, row } = entry;
  const head = h("div", {}, h("div", { class: "sub" }, `${typeName(item)} · ${when(item.updatedAt)}`), h("h2", { class: "doc-title" }, displayTitle(item)));
  pane.replaceChildren(head, message("Opening…"));
  if (item.kind !== "note") { pane.replaceChildren(head, message("Files open on your iPhone for now. PDFs and books come to the website next.")); return; }
  const blob = blobIdFromKey(row.storage_key, ctx.userId);
  if (!blob) { pane.replaceChildren(head, message("This one hasn't finished moving to your sealed storage. Open it once on your iPhone.")); return; }
  try {
    const sealed = await net.getBlob(await ctx.token(), blob);
    if (mine !== run) return;
    if (!sealed) { pane.replaceChildren(head, message("This note's text isn't on the server yet. Let your iPhone finish syncing.")); return; }
    const text = dec.decode(await open("content", sealed, row.id));
    if (mine !== run) return;
    const frame = noteFrame(isMarkdown(item.mime) ? parse(text) : plain(text));
    pane.replaceChildren(head, frame);
  } catch (e) {
    if (mine !== run) return;
    pane.replaceChildren(head, message(e instanceof OpenFailure ? "This note didn't open with your key, so it was left alone." : "Couldn't load this note. Check your connection."));
  }
}

export async function showReader(into: HTMLElement, ctx: Ctx, selected: string | null): Promise<void> {
  const mine = ++run;
  const list = h("section", { class: "panel library" }, h("div", { class: "panel-title" }, "Library"), message("Opening your library…"));
  const pane = h("section", { class: "panel reading" }, message("Pick something from your library."));
  into.replaceChildren(h("div", { class: "page-head" }, h("h1", {}, "Reader")), h("div", { class: "reader" }, list, pane));
  let lib: Awaited<ReturnType<typeof loadLibrary>>;
  try { lib = await loadLibrary(ctx); } catch (e) {
    if (mine !== run) return;
    list.replaceChildren(h("div", { class: "panel-title" }, "Library"), message(e instanceof vault.LockedError || (e instanceof Error && e.message === "locked") ? "Locked." : "Couldn't load your library. Check your connection."));
    return;
  }
  if (mine !== run) return;
  const pick = (id: string) => { location.hash = `#/reader/${id}`; };
  const rows = lib.entries.map((e) => {
    const b = h("button", { type: "button", class: "item" + (e.item.id === selected ? " on" : ""), onclick: () => pick(e.item.id) },
      h("div", { class: "item-title" }, displayTitle(e.item)), h("div", { class: "sub" }, `${typeName(e.item)} · ${when(e.item.updatedAt)}`));
    return b;
  });
  list.replaceChildren(h("div", { class: "panel-title" }, "Library"),
    ...(rows.length ? rows : [message("Nothing here yet. Add notes and files on your iPhone and they appear here.")]),
    ...(lib.unreadable ? [h("p", { class: "sub" }, `${lib.unreadable} item${lib.unreadable === 1 ? "" : "s"} didn't open with your key and ${lib.unreadable === 1 ? "is" : "are"} hidden.`)] : []));
  const entry = lib.entries.find((e) => e.item.id === selected);
  if (entry) await showItem(ctx, entry, pane, mine);
}
