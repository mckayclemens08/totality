// Notes are Markdown text. This turns it into a small tree, never into HTML, so nothing in a note can
// become markup or a script: the page builds elements from the tree with textContent only (see view.ts).
export interface Run { text: string; bold?: boolean; italic?: boolean; code?: boolean; href?: string }
export type Block =
  | { t: "h"; level: 1 | 2 | 3; runs: Run[] }
  | { t: "p"; runs: Run[] }
  | { t: "ul" | "ol"; items: Run[][] }
  | { t: "code"; text: string };

const safeHref = (u: string): string | undefined => (/^https?:\/\/[^\s"'<>]+$/i.test(u) ? u : undefined);

export function inline(text: string): Run[] {
  const runs: Run[] = [];
  const re = /(\*\*([^*]+)\*\*|\*([^*]+)\*|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\))/g;
  let at = 0, m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (m.index > at) runs.push({ text: text.slice(at, m.index) });
    if (m[2] !== undefined) runs.push({ text: m[2], bold: true });
    else if (m[3] !== undefined) runs.push({ text: m[3], italic: true });
    else if (m[4] !== undefined) runs.push({ text: m[4], code: true });
    else { const href = safeHref(m[6]!); runs.push(href ? { text: m[5]!, href } : { text: m[5]! }); }
    at = m.index + m[0].length;
  }
  if (at < text.length) runs.push({ text: text.slice(at) });
  return runs;
}

export function parse(source: string): Block[] {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  const blocks: Block[] = [];
  let para: string[] = [];
  const flush = () => { if (para.length) blocks.push({ t: "p", runs: inline(para.join(" ")) }); para = []; };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (/^```/.test(line)) {
      flush();
      const code: string[] = [];
      for (i++; i < lines.length && !/^```/.test(lines[i]!); i++) code.push(lines[i]!);
      blocks.push({ t: "code", text: code.join("\n") });
      continue;
    }
    const heading = /^(#{1,3})\s+(.*)$/.exec(line);
    const item = /^\s*([-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (!line.trim()) flush();
    else if (heading) { flush(); blocks.push({ t: "h", level: heading[1]!.length as 1 | 2 | 3, runs: inline(heading[2]!) }); }
    else if (item) {
      flush();
      const kind = /\d/.test(item[1]!) ? "ol" : "ul";
      const last = blocks[blocks.length - 1];
      if (last && last.t === kind) last.items.push(inline(item[2]!)); else blocks.push({ t: kind, items: [inline(item[2]!)] });
    } else para.push(line.trim());
  }
  flush();
  return blocks;
}

/** A note that isn't Markdown is shown as the paragraphs it is. */
export function plain(source: string): Block[] {
  return source.replace(/\r\n?/g, "\n").split(/\n{2,}/).filter((p) => p.trim()).map((p) => ({ t: "p", runs: [{ text: p.trim() }] }));
}

export const isMarkdown = (mime: string | null): boolean => !!mime && /^text\/markdown/.test(mime);
