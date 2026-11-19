import { h } from "../dom";
import * as net from "../net";
import * as vault from "../keystore";
import { fromHex } from "../pairing/protocol";
import type { Ctx } from "../reader/view";
import { MailOpenFailure, openMail, splitEnvelope } from "./hpke";
import { linksIn, parseMail, type Mail } from "./mime";

interface Entry { id: string; received: number; mail: Mail; flagged: boolean; direct: boolean }
let run = 0;
export const stopMail = (): void => { run++; };

const PAGE = 40, MAX_FETCH = 5 * 1024 * 1024;
const when = (ms: number) => new Date(ms).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

/** The CSP a message's HTML is shown under: nothing loads from anywhere, only the message's own data: images
 *  and its inline styles. (The page's own CSP is inherited too, and is stricter: see the PR notes.) */
const FRAME_CSP = "default-src 'none'; img-src data:; style-src 'unsafe-inline'";

// A Trusted Types policy used for this one sink, srcdoc. It adds nothing to the HTML: the safety is the
// sandbox (no scripts, no same-origin, no forms, no navigation) and the CSP above. The page's CSP allows no
// other policy name.
type TTPolicy = { createHTML(s: string): string };
function frameHtml(html: string): string {
  const tt = (window as unknown as { trustedTypes?: { createPolicy(n: string, o: TTPolicy): TTPolicy } }).trustedTypes;
  const doc = `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${FRAME_CSP}">${html}`;
  return tt ? (policy ??= tt.createPolicy("mail-frame", { createHTML: (s) => s })).createHTML(doc) : doc;
}
let policy: TTPolicy | undefined;

export function messageFrame(html: string): HTMLIFrameElement {
  const frame = h("iframe", { class: "mail-frame", sandbox: "", title: "Message", referrerpolicy: "no-referrer" });
  frame.srcdoc = frameHtml(html);
  return frame;
}

function body(m: Mail): HTMLElement {
  const links = m.html ? linksIn(m.html) : [];
  return h("div", { class: "mail-body" },
    m.html !== null ? messageFrame(m.html) : h("pre", { class: "mail-text" }, m.text || "(no text)"),
    ...(links.length ? [h("div", { class: "panel-title spaced" }, "Links in this message"),
      ...links.map((l) => h("a", { class: "mail-link", href: l.href, target: "_blank", rel: "noopener noreferrer nofollow" }, l.label === l.href ? l.href : `${l.label} (${new URL(l.href).host})`))] : []),
    ...(m.attachments.length ? [h("div", { class: "panel-title spaced" }, "Attachments"), ...m.attachments.map((a) => h("p", { class: "sub" }, `${a.name} · ${Math.max(1, Math.round(a.size / 1024))} KB · opens on your iPhone for now`))] : []));
}

export async function showMail(into: HTMLElement, ctx: Ctx, selected: string | null): Promise<void> {
  const mine = ++run;
  const list = h("section", { class: "panel library" }, h("div", { class: "panel-title" }, "Inbox"), h("p", { class: "status" }, "Opening your mail…"));
  const pane = h("section", { class: "panel reading" }, h("p", { class: "status" }, "Pick a message."));
  into.replaceChildren(h("div", { class: "page-head" }, h("h1", {}, "Mail")), h("p", { class: "sub" }, "Read-only for now. Write and reply on your iPhone. Images and scripts in messages are blocked."), h("div", { class: "reader" }, list, pane));
  const entries: Entry[] = [];
  let unreadable = 0, large = 0, skipped = 0, total = 0;
  try {
    const token = await ctx.token();
    const seed = await vault.deriveSeed("totality/mail-key/v1");
    const all = (await net.mailList(token)).sort((a, b) => b.received - a.received);
    total = all.length;
    for (const m of all.slice(0, PAGE)) {
      if (mine !== run) return;
      if (m.size > MAX_FETCH) { large++; continue; }
      try {
        const sealed = await net.mailMessage(await ctx.token(), m.id);
        if (!sealed) continue;
        let opened;
        try { opened = openMail(sealed, seed, ctx.userId, m.id); } catch (e) {
          // A Sent copy has its own seal, which only the iPhone opens yet. Anything else that fails is counted.
          if (e instanceof MailOpenFailure && sealed[0] === 2) skipped++; else unreadable++;
          continue;
        }
        const env = splitEnvelope(opened);
        if (!env) { unreadable++; continue; }
        entries.push({ id: m.id, received: env.received ?? m.received, flagged: env.flagged, direct: env.from !== null, mail: env.from ? parseMail(new Uint8Array(0)) : parseMail(env.rest) });
      } catch (e) { if (e instanceof net.NetError && e.kind !== "failed") throw e; unreadable++; }
    }
  } catch (e) {
    if (mine === run) list.replaceChildren(h("div", { class: "panel-title" }, "Inbox"), h("p", { class: "status" }, e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your mail. Check your connection."));
    return;
  }
  if (mine !== run) return;
  void fromHex;
  const inbox = entries.filter((e) => !e.flagged);
  const spam = entries.length - inbox.length;
  const rows = inbox.map((e) => h("button", { type: "button", class: "item" + (e.id === selected ? " on" : ""), onclick: () => { location.hash = `#/mail/${e.id}`; } },
    h("div", { class: "item-title" }, e.direct ? "Message from a Totality account" : e.mail.subject.trim() || "(no subject)"),
    h("div", { class: "sub" }, `${e.direct ? "" : (e.mail.from || "Unknown sender") + " · "}${when(e.received)}`)));
  list.replaceChildren(h("div", { class: "panel-title" }, "Inbox"), ...(rows.length ? rows : [h("p", { class: "status" }, "Your inbox is empty.")]),
    ...[spam ? `${spam} in Spam, not shown.` : "", total > PAGE ? `Showing the newest ${PAGE} of ${total}.` : "", large ? `${large} large message${large === 1 ? "" : "s"} open on your iPhone.` : "",
      skipped ? `${skipped} sent cop${skipped === 1 ? "y" : "ies"} open on your iPhone.` : "", unreadable ? `${unreadable} message${unreadable === 1 ? "" : "s"} didn't open with your key.` : ""]
      .filter(Boolean).map((t) => h("p", { class: "sub" }, t)));
  const chosen = entries.find((e) => e.id === selected);
  if (!chosen) return;
  if (chosen.direct) { pane.replaceChildren(h("p", { class: "status" }, "Mail from another Totality account is sealed a second time. It opens on your iPhone for now.")); return; }
  pane.replaceChildren(h("div", { class: "sub" }, when(chosen.received)), h("h2", { class: "doc-title small" }, chosen.mail.subject.trim() || "(no subject)"),
    h("p", { class: "sub" }, `From ${chosen.mail.from || "unknown"}`), chosen.mail.to ? h("p", { class: "sub" }, `To ${chosen.mail.to}`) : "", body(chosen.mail));
}
