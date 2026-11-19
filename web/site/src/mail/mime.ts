// A small, forgiving MIME reader for mail written by strangers. It never throws and never trusts a header:
// depth and part counts are capped, anything unreadable becomes empty text, and nothing it returns is markup
// the page will parse (HTML goes to a sandboxed frame, text is drawn with textContent).
export interface Mail {
  subject: string; from: string; to: string; date: number | null; text: string; html: string | null;
  attachments: { name: string; type: string; size: number }[];
}
const MAX_DEPTH = 24, MAX_PARTS = 1000, MAX_INLINE = 2 * 1024 * 1024;

interface Part { headers: Map<string, string>; body: Uint8Array }
const dec = (bytes: Uint8Array, charset = "utf-8"): string => {
  try { return new TextDecoder(charset.replace(/^"|"$/g, "").toLowerCase(), { fatal: false }).decode(bytes); } catch { return new TextDecoder().decode(bytes); }
};
const latin = (s: string): Uint8Array => Uint8Array.from(s, (c) => c.charCodeAt(0) & 255);

function split(raw: Uint8Array): Part {
  let at = -1, skip = 0;
  for (let i = 0; i < raw.length - 1; i++) {
    if (raw[i] === 10 && raw[i + 1] === 10) { at = i; skip = 2; break; }
    if (raw[i] === 13 && raw[i + 1] === 10 && raw[i + 2] === 13 && raw[i + 3] === 10) { at = i; skip = 4; break; }
  }
  const head = new TextDecoder("latin1").decode(at < 0 ? raw : raw.slice(0, at));
  const headers = new Map<string, string>();
  let key = "";
  for (const line of head.split(/\r?\n/)) {
    if (/^[ \t]/.test(line) && key) headers.set(key, `${headers.get(key)} ${line.trim()}`);
    else { const m = /^([!-9;-~]+):\s*(.*)$/.exec(line); if (m) { key = m[1]!.toLowerCase(); if (!headers.has(key)) headers.set(key, m[2]!); } else key = ""; }
  }
  return { headers, body: at < 0 ? new Uint8Array(0) : raw.slice(at + skip) };
}

/** RFC 2047 words in a header, like =?UTF-8?B?...?=. */
export function decodeWords(s: string): string {
  return s.replace(/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/g, (_m, cs: string, enc: string, text: string) => {
    try {
      const bytes = enc.toLowerCase() === "b" ? Uint8Array.from(atob(text), (c) => c.charCodeAt(0)) : qp(text.replace(/_/g, " "), true);
      return dec(bytes, cs);
    } catch { return text; }
  }).replace(/\?=\s+=\?/g, "");
}

function qp(s: string, word = false): Uint8Array {
  const out: number[] = [];
  const text = word ? s : s.replace(/=\r?\n/g, "");
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c === 61 && /^[0-9A-Fa-f]{2}$/.test(text.slice(i + 1, i + 3))) { out.push(parseInt(text.slice(i + 1, i + 3), 16)); i += 2; } else out.push(c & 255);
  }
  return Uint8Array.from(out);
}

function decodeBody(p: Part): Uint8Array {
  const enc = (p.headers.get("content-transfer-encoding") ?? "").trim().toLowerCase();
  const text = new TextDecoder("latin1").decode(p.body);
  try {
    if (enc === "base64") return Uint8Array.from(atob(text.replace(/[^A-Za-z0-9+/=]/g, "")), (c) => c.charCodeAt(0));
    if (enc === "quoted-printable") return qp(text);
  } catch { /* fall through to the raw bytes */ }
  return p.body;
}

function params(h: string): { value: string; p: Map<string, string> } {
  const [value = "", ...rest] = h.split(";");
  const p = new Map<string, string>();
  for (const r of rest) { const m = /^\s*([^=\s]+)\s*=\s*("([^"]*)"|[^;]*)/.exec(r); if (m) p.set(m[1]!.toLowerCase(), (m[3] ?? m[2]!).trim()); }
  return { value: value.trim().toLowerCase(), p };
}

export function parseMail(raw: Uint8Array): Mail {
  const top = split(raw);
  const mail: Mail = { subject: "", from: "", to: "", date: null, text: "", html: null, attachments: [] };
  mail.subject = decodeWords(top.headers.get("subject") ?? "");
  mail.from = decodeWords(top.headers.get("from") ?? "");
  mail.to = decodeWords(top.headers.get("to") ?? "");
  const d = Date.parse(top.headers.get("date") ?? "");
  mail.date = Number.isNaN(d) ? null : d;
  let parts = 0;
  const cids = new Map<string, string>();
  const walk = (p: Part, depth: number): void => {
    if (depth > MAX_DEPTH || ++parts > MAX_PARTS) return;
    const type = params(p.headers.get("content-type") ?? "text/plain");
    const disp = params(p.headers.get("content-disposition") ?? "");
    if (type.value.startsWith("multipart/") && type.p.get("boundary")) {
      const b = "--" + type.p.get("boundary")!;
      const text = new TextDecoder("latin1").decode(p.body);
      const chunks = text.split(new RegExp(`(?:^|\\r?\\n)${b.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:--)?[ \\t]*(?=\\r?\\n|$)`));
      for (const chunk of chunks.slice(1)) walk(split(latin(chunk.replace(/^\r?\n/, ""))), depth + 1);
      return;
    }
    const body = decodeBody(p);
    const name = decodeWords(disp.p.get("filename") ?? type.p.get("name") ?? "");
    const cid = (p.headers.get("content-id") ?? "").replace(/^<|>$/g, "").trim();
    if (type.value.startsWith("image/") && cid && body.length <= MAX_INLINE && /^image\/(png|jpeg|gif|webp)$/.test(type.value)) {
      cids.set(cid, `data:${type.value};base64,${btoa(String.fromCharCode(...body))}`);
    }
    if (disp.value === "attachment" || (name && !type.value.startsWith("text/"))) { mail.attachments.push({ name: name || "attachment", type: type.value, size: body.length }); return; }
    if (type.value === "text/html" && mail.html === null) mail.html = dec(body, type.p.get("charset"));
    else if (type.value === "text/plain" && !mail.text) mail.text = dec(body, type.p.get("charset"));
  };
  walk(top, 0);
  if (mail.html !== null) mail.html = mail.html.replace(/\bcid:([^"'\s)>]+)/gi, (m, id: string) => cids.get(id) ?? m);
  return mail;
}

/** http(s) links in a message's HTML, from an inert document. The page lists these itself, because a frame
 *  that can run nothing can't be clicked. */
export function linksIn(html: string, parse: (h: string) => Document = (h) => new DOMParser().parseFromString(h, "text/html")): { href: string; label: string }[] {
  const seen = new Set<string>(), out: { href: string; label: string }[] = [];
  for (const a of Array.from(parse(html).querySelectorAll("a[href]"))) {
    const href = (a.getAttribute("href") ?? "").trim();
    if (!/^https?:\/\/[^\s"'<>]+$/i.test(href) || seen.has(href)) continue;
    seen.add(href);
    out.push({ href, label: (a.textContent ?? "").trim().slice(0, 80) || href });
    if (out.length >= 20) break;
  }
  return out;
}
