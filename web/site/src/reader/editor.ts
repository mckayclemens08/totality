// The Reader's writing editor on the website: the doc's Markdown with formatting buttons, a live preview drawn
// the safe way (a sandboxed frame filled with textContent), a word count, and saving as you pause. It writes
// the same Markdown the iPhone's editor writes, so a doc moves between them unchanged.
import "./reader-edit.css";
import { h } from "../dom";
import * as net from "../net";
import { field, input, sheet } from "../ui";
import { parse } from "./markdown";
import { linePrefix, link, words, wrap, type Edit } from "./format";
import { create, save, type Ctx, type Open } from "./save";
import { noteFrame } from "./view";

const SETTLE_MS = 900;

const failText = (e: unknown): string =>
  e instanceof net.NetError && e.kind === "offline" ? "Couldn't save: you're offline. Your words are still here." :
  e instanceof Error && e.message === "locked" ? "Locked. Unlock to save; your words are still here." :
  "Couldn't save. Your words are still here; it tries again as you type.";

/** New doc: an empty doc saved first, so it exists everywhere, then opened in the editor. */
export async function newDoc(ctx: Ctx, status: HTMLElement): Promise<string | null> {
  status.textContent = "Starting a new doc…";
  try { const d = await create(ctx); status.textContent = ""; return String(d.raw.id).toLowerCase(); }
  catch (e) { status.textContent = failText(e); return null; }
}

export function editNote(ctx: Ctx, pane: HTMLElement, start: Open, startText: string): void {
  let doc = start;
  let savedTitle = String(doc.raw.title ?? ""), savedText = startText;
  const target = typeof doc.raw.wordTarget === "number" ? doc.raw.wordTarget : null;
  const status = h("span", { class: "save-status", role: "status", "aria-live": "polite" }, "Sealed in this browser before it saves.");
  const count = h("span", { class: "sub" });
  const title = input({ class: "title-field doc-title-field", "aria-label": "Title", placeholder: "Untitled", value: savedTitle });
  const text = h("textarea", { class: "md-field", "aria-label": "Doc", spellcheck: "true", placeholder: "Start writing…" });
  text.value = startText;
  const previewHost = h("div", { class: "md-preview", "aria-label": "Preview" });

  const drawPreview = () => previewHost.replaceChildren(noteFrame(parse(text.value)));
  const drawCount = () => { const n = words(text.value); count.textContent = target ? `${n.toLocaleString()} of ${target.toLocaleString()} words` : `${n.toLocaleString()} word${n === 1 ? "" : "s"}`; };

  // ---- saving: one at a time, the latest words always win ----
  let timer: ReturnType<typeof setTimeout> | null = null;
  let saving: Promise<void> | null = null;
  let again = false;
  const dirty = () => title.value !== savedTitle || text.value !== savedText;
  async function flush(): Promise<void> {
    if (timer) { clearTimeout(timer); timer = null; }
    if (saving) { again = true; return saving; }
    if (!dirty()) return;
    const t = title.value, w = text.value;
    status.textContent = "Saving…"; status.classList.remove("bad");
    saving = (async () => {
      try {
        const r = await save(ctx, doc, t, w);
        if ("copy" in r) {
          doc = r.copy;
          title.value = String(doc.raw.title);
          status.textContent = "This doc changed on another device, so your words were saved as a new doc beside it, marked (conflict copy). You're editing that one now.";
          // The address follows the copy without reopening the page, so the editor and its words stay.
          history.replaceState(null, "", `#/reader/${String(doc.raw.id).toLowerCase()}`);
        } else { doc = r.saved; status.textContent = "Saved"; }
        savedTitle = String(doc.raw.title); savedText = w;
      } catch (e) { status.textContent = failText(e); status.classList.add("bad"); }
    })();
    await saving;
    saving = null;
    if (again) { again = false; await flush(); }
  }
  const soon = () => { if (timer) clearTimeout(timer); timer = setTimeout(() => void flush(), SETTLE_MS); };
  const changed = () => { drawCount(); soon(); };
  let previewTimer: ReturnType<typeof setTimeout> | null = null;
  text.addEventListener("input", () => { changed(); if (previewTimer) clearTimeout(previewTimer); previewTimer = setTimeout(drawPreview, 300); });
  title.addEventListener("input", changed);
  title.addEventListener("blur", () => void flush());
  text.addEventListener("blur", () => void flush());
  const warn = (e: BeforeUnloadEvent) => { if (dirty() || saving) { e.preventDefault(); } };
  addEventListener("beforeunload", warn);

  // ---- formatting ----
  const apply = (f: (t: string, s: number, e: number) => Edit | null) => {
    const r = f(text.value, text.selectionStart, text.selectionEnd);
    if (!r) return;
    text.value = r.text;
    text.focus();
    text.setSelectionRange(r.start, r.end);
    text.dispatchEvent(new Event("input"));
  };
  const askLink = () => {
    const s = text.selectionStart, e = text.selectionEnd;
    const url = input({ type: "url", "aria-label": "Address", placeholder: "https://" });
    const bad = h("p", { class: "status bad", hidden: true }, "Use a web address that starts with https:// or http://, or a mailto: address.");
    sheet("Add a link", [field("Address", url), bad], [{ label: "Add link", primary: true, run: () => {
      const r = link(text.value, s, e, url.value);
      if (!r) { bad.hidden = false; return false; }
      text.value = r.text; text.focus(); text.setSelectionRange(r.start, r.end); text.dispatchEvent(new Event("input"));
      return true;
    } }]);
    url.focus();
  };
  const tool = (label: string, name: string, run: () => void) => h("button", { type: "button", class: "quiet tool", "aria-label": name, title: name, onclick: run }, label);
  const tools = h("div", { class: "md-tools", role: "toolbar", "aria-label": "Formatting" },
    tool("B", "Bold (⌘B)", () => apply((t, s, e) => wrap(t, s, e, "**"))),
    tool("I", "Italic (⌘I)", () => apply((t, s, e) => wrap(t, s, e, "*"))),
    tool("H1", "Heading", () => apply((t, s, e) => linePrefix(t, s, e, "h1"))),
    tool("H2", "Subheading", () => apply((t, s, e) => linePrefix(t, s, e, "h2"))),
    tool("•", "Bulleted list", () => apply((t, s, e) => linePrefix(t, s, e, "bullet"))),
    tool("1.", "Numbered list", () => apply((t, s, e) => linePrefix(t, s, e, "number"))),
    tool("❝", "Quote", () => apply((t, s, e) => linePrefix(t, s, e, "quote"))),
    tool("</>", "Code", () => apply((t, s, e) => wrap(t, s, e, "`"))),
    tool("🔗", "Link (⌘K)", askLink));
  text.addEventListener("keydown", (ev) => {
    const k = ev as KeyboardEvent;
    if (!(k.metaKey || k.ctrlKey)) return;
    const key = k.key.toLowerCase();
    if (key === "b") { k.preventDefault(); apply((t, s, e) => wrap(t, s, e, "**")); }
    else if (key === "i") { k.preventDefault(); apply((t, s, e) => wrap(t, s, e, "*")); }
    else if (key === "k") { k.preventDefault(); askLink(); }
    else if (key === "s") { k.preventDefault(); void flush(); }
  });

  const done = h("button", { type: "button", class: "small-btn", onclick: async () => {
    done.disabled = true;
    await flush();
    done.disabled = false;
    if (dirty()) return; // still unsaved: stay, with the reason on the status line
    removeEventListener("beforeunload", warn);
    // Opens the doc again for reading, from the server, so what shows is what was saved.
    dispatchEvent(new HashChangeEvent("hashchange"));
  } }, "Done");

  pane.replaceChildren(
    h("div", { class: "editor-foot" }, done, status, h("span", { class: "grow" }), count),
    title, tools,
    h("div", { class: "md-split" }, text, previewHost));
  drawCount();
  drawPreview();
  text.focus();
}
