// The formatted editor's buttons: each changes the Markdown text around the selection, the way the iPhone's
// writing editor marks it, and says where the selection goes after. Pure, so it's tested without a page.
export interface Edit { text: string; start: number; end: number }

/** Bold, italic and code: marks around the selection, or taken off when they're already there. */
export function wrap(text: string, start: number, end: number, mark: string): Edit {
  const before = text.slice(0, start), inside = text.slice(start, end), after = text.slice(end);
  if (before.endsWith(mark) && after.startsWith(mark)) {
    return { text: before.slice(0, -mark.length) + inside + after.slice(mark.length), start: start - mark.length, end: end - mark.length };
  }
  if (inside.startsWith(mark) && inside.endsWith(mark) && inside.length >= mark.length * 2) {
    const bare = inside.slice(mark.length, -mark.length);
    return { text: before + bare + after, start, end: start + bare.length };
  }
  return { text: before + mark + inside + mark + after, start: start + mark.length, end: end + mark.length };
}

const lineStart = (text: string, at: number) => text.lastIndexOf("\n", at - 1) + 1;
const lineEnd = (text: string, at: number) => { const i = text.indexOf("\n", at); return i < 0 ? text.length : i; };
const PREFIX = /^(#{1,6} |> |- |\d+\. )/;

/** Headings, quotes and lists: every line the selection touches gets the prefix, or loses it if all have it. */
export function linePrefix(text: string, start: number, end: number, kind: "h1" | "h2" | "quote" | "bullet" | "number"): Edit {
  const from = lineStart(text, start), to = lineEnd(text, Math.max(end - (end > start && text[end - 1] === "\n" ? 1 : 0), start));
  const lines = text.slice(from, to).split("\n");
  const want = (i: number) => ({ h1: "# ", h2: "## ", quote: "> ", bullet: "- ", number: `${i + 1}. ` })[kind];
  const has = (l: string, i: number) => kind === "number" ? /^\d+\. /.test(l) : l.startsWith(want(i));
  const all = lines.every(has);
  const out = lines.map((l, i) => (all ? l.replace(PREFIX, "") : want(i) + l.replace(PREFIX, ""))).join("\n");
  const text2 = text.slice(0, from) + out + text.slice(to);
  return { text: text2, start: from, end: from + out.length };
}

/** A link: the selection becomes its words. Only web and mail addresses are made links. */
export function link(text: string, start: number, end: number, url: string): Edit | null {
  const u = url.trim().replace(/\s/g, "%20").replace(/\(/g, "%28").replace(/\)/g, "%29");
  if (!/^(https?:\/\/|mailto:)\S+$/i.test(u)) return null;
  const words = text.slice(start, end) || u;
  const md = `[${words.replace(/[[\]]/g, "")}](${u})`;
  return { text: text.slice(0, start) + md + text.slice(end), start: start + 1, end: start + 1 + words.replace(/[[\]]/g, "").length };
}

/** Words, for the count beside the editor (and a word target, if the doc has one). */
export const words = (text: string): number => (text.replace(/[*_`#>]/g, "").match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) ?? []).length;
