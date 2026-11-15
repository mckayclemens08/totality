// What export works from: the doc read once by the same parser the page uses, with citations, cross-
// references, footnotes and wiki links already turned into words. Swift lays this out as a PDF or a
// Word file. It's plain data: strings, numbers and flags, never markup, so nothing in a doc can become
// code in either file.
import { EditorState } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { ensureSyntaxTree } from "@codemirror/language";
import { Strikethrough, Subscript, Superscript, Table, TaskList } from "@lezer/markdown";
import { scholarlySyntax, citationKeys, isCrossRef, crossRefText, locator, labels } from "./scholarly.js";
import { wikiSyntax, parseWiki, wikiText } from "./wiki.js";

/// A doc can be long, but export has limits so a damaged one can't make a file without end.
export const maxBlocks = 50000;

const extensions = [Strikethrough, Subscript, Superscript, Table, TaskList, scholarlySyntax, wikiSyntax];

/// The title, author and date in Pandoc front matter, for a title page. Anything else is left out.
export function frontMatter(text) {
  const found = /^---\n([\s\S]*?)\n(?:---|\.\.\.)(?:\n|$)/.exec(text);
  const meta = {};
  if (!found) return meta;
  let listKey = null;
  for (const line of found[1].split("\n")) {
    const item = /^\s+-\s+(.*)$/.exec(line);
    if (item && listKey) {
      meta[listKey] = meta[listKey] ? `${meta[listKey]}, ${unquote(item[1])}` : unquote(item[1]);
      continue;
    }
    const pair = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line);
    listKey = null;
    if (!pair) continue;
    const key = pair[1].toLowerCase();
    if (!["title", "subtitle", "author", "date", "institute", "course", "instructor"].includes(key)) continue;
    if (pair[2] === "") listKey = key;
    else meta[key] = unquote(pair[2]);
  }
  for (const key of Object.keys(meta)) meta[key] = meta[key].slice(0, 300);
  return meta;
}

function unquote(value) {
  const trimmed = value.trim();
  const quoted = /^(["'])(.*)\1$/.exec(trimmed);
  return quoted ? quoted[2] : trimmed;
}

const entities = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " " };

/// Reads a doc into blocks. `cite` turns citation keys into words, and `bibliography` lists what's cited.
export function exportModel(text, { citation, bibliography }) {
  const state = EditorState.create({ doc: text, extensions: [markdown({ base: markdownLanguage, extensions })] });
  const tree = ensureSyntaxTree(state, state.doc.length, 10000);
  const slice = (from, to) => state.sliceDoc(from, to);
  const targets = labels(text);
  // Notes are numbered in the order they're referred to. A definition nothing refers to isn't printed.
  const noteNumbers = new Map();
  const definitions = new Map();
  let count = 0;

  function noteNumber(label) {
    if (!noteNumbers.has(label)) noteNumbers.set(label, noteNumbers.size + 1);
    return noteNumbers.get(label);
  }

  // MARK: Inline

  function push(runs, text, style) {
    if (!text) return;
    const last = runs[runs.length - 1];
    if (last && last.note == null && !last.br && sameStyle(last, style)) last.text += text;
    else runs.push({ text, ...style });
  }

  function sameStyle(a, b) {
    return ["b", "i", "s", "code", "sup", "sub", "href"].every((key) => (a[key] || false) === (b[key] || false));
  }

  function plain(text) {
    return text.replace(/\s*\n\s*/g, " ").replace(/&(?:amp|lt|gt|quot|#39|nbsp);/g, (e) => entities[e]);
  }

  /// The runs between `from` and `to` inside `node`, skipping the node's own marks.
  function inline(node, from, to, style, runs) {
    let at = from;
    for (let child = node.firstChild; child; child = child.nextSibling) {
      if (child.to <= from || child.from >= to) continue;
      if (child.from > at) push(runs, plain(slice(at, child.from)), style);
      inlineNode(child, style, runs);
      at = Math.max(at, child.to);
    }
    if (at < to) push(runs, plain(slice(at, to)), style);
    return runs;
  }

  function inner(node, style, runs, marks) {
    const opening = node.firstChild && marks.includes(node.firstChild.name) ? node.firstChild.to : node.from;
    const closing = node.lastChild && marks.includes(node.lastChild.name) && node.lastChild.from >= opening ? node.lastChild.from : node.to;
    inline(node, opening, closing, style, runs);
  }

  function inlineNode(node, style, runs) {
    const name = node.name;
    switch (name) {
      case "Emphasis": return inner(node, { ...style, i: true }, runs, ["EmphasisMark"]);
      case "StrongEmphasis": return inner(node, { ...style, b: true }, runs, ["EmphasisMark"]);
      case "Strikethrough": return inner(node, { ...style, s: true }, runs, ["StrikethroughMark"]);
      case "Superscript": return inner(node, { ...style, sup: true }, runs, ["SuperscriptMark"]);
      case "Subscript": return inner(node, { ...style, sub: true }, runs, ["SubscriptMark"]);
      case "InlineCode": {
        const raw = slice(node.from, node.to).replace(/^`+\s?|\s?`+$/g, "");
        return push(runs, raw, { ...style, code: true });
      }
      case "Link": {
        const marks = [];
        for (let child = node.firstChild; child; child = child.nextSibling) if (child.name === "LinkMark") marks.push(child);
        const url = node.getChild("URL");
        const href = url ? slice(url.from, url.to) : "";
        const linkStyle = /^(?:https?:\/\/|mailto:)/i.test(href) && href.length <= 2000 ? { ...style, href } : style;
        if (marks.length >= 2) return inline(node, marks[0].to, marks[1].from, linkStyle, runs);
        return push(runs, plain(slice(node.from, node.to)), style);
      }
      case "Autolink": {
        const url = node.getChild("URL");
        const href = url ? slice(url.from, url.to) : "";
        return push(runs, href, /^(?:https?:\/\/|mailto:)/i.test(href) ? { ...style, href } : style);
      }
      case "Image": {
        const text = slice(node.from, node.to);
        return push(runs, plain(text.slice(2, Math.max(2, text.indexOf("](")))), style);
      }
      case "Escape": return push(runs, slice(node.from + 1, node.to), style);
      case "Entity": return push(runs, entities[slice(node.from, node.to)] || slice(node.from, node.to), style);
      case "HardBreak": return runs.push({ text: "", br: true });
      case "FootnoteRef": {
        const label = slice(node.from + 2, node.to - 1);
        return runs.push({ text: "", note: noteNumber(label) });
      }
      case "InlineNote": {
        const label = `\u0000inline${node.from}`;
        definitions.set(label, [{ t: "p", runs: [{ text: plain(slice(node.from + 2, node.to - 1)) }] }]);
        return runs.push({ text: "", note: noteNumber(label) });
      }
      case "Citation":
      case "NarrativeCitation": {
        const text = slice(node.from, node.to);
        const keys = name === "Citation" ? citationKeys(text) : [{ key: text.slice(1), suppressAuthor: false }];
        if (keys.length && keys.every(({ key }) => isCrossRef(key))) {
          return push(runs, keys.map(({ key }) => crossRefText(key, targets)).join(", "), style);
        }
        return push(runs, citation(keys, name === "Citation" ? locator(text) : "", name === "NarrativeCitation"), style);
      }
      case "WikiLink": {
        const link = parseWiki(slice(node.from, node.to));
        return push(runs, link ? wikiText(link) : slice(node.from, node.to), style);
      }
      case "Attribute":
      case "HTMLTag":
      case "Comment":
      case "ProcessingInstruction":
        return undefined;
      default:
        if (node.firstChild) return inline(node, node.from, node.to, style, runs);
        return push(runs, plain(slice(node.from, node.to)), style);
    }
  }

  /// Runs with the spaces at either end trimmed, as a printed line would have them.
  function trimmed(runs) {
    while (runs.length && runs[0].text !== undefined && !runs[0].note && !runs[0].br && !runs[0].text.trim()) runs.shift();
    while (runs.length && !runs[runs.length - 1].note && !runs[runs.length - 1].br && !runs[runs.length - 1].text.trim()) runs.pop();
    if (runs.length && !runs[0].note && !runs[0].br) runs[0].text = runs[0].text.replace(/^\s+/, "");
    const last = runs[runs.length - 1];
    if (last && !last.note && !last.br) last.text = last.text.replace(/\s+$/, "");
    return runs;
  }

  // MARK: Blocks

  function heading(node, level) {
    const marks = [];
    for (let child = node.firstChild; child; child = child.nextSibling) if (child.name === "HeaderMark") marks.push(child);
    const isSetext = node.name.startsWith("Setext");
    const from = !isSetext && marks[0] ? marks[0].to : node.from;
    let to = node.to;
    if (isSetext && marks.length) to = marks[marks.length - 1].from;
    else if (marks.length > 1) to = marks[marks.length - 1].from;
    return { t: "h", level, runs: trimmed(inline(node, from, to, {}, [])) };
  }

  /// A paragraph that's only an image is a figure: the image, then its number and caption.
  function figure(node) {
    const kinds = [];
    for (let child = node.firstChild; child; child = child.nextSibling) kinds.push(child.name);
    const rest = slice(node.from, node.to).replace(/!\[[^\]]*\]\([^)]*\)/, "").replace(/\{#[^}]*\}/, "").trim();
    if (kinds[0] !== "Image" || rest || kinds.some((kind) => kind !== "Image" && kind !== "Attribute")) return null;
    const image = node.firstChild;
    const text = slice(image.from, image.to);
    const alt = plain(text.slice(2, Math.max(2, text.indexOf("]("))));
    const url = image.getChild("URL");
    // Swift decides what an address may name. Export never fetches from the internet.
    const src = url ? slice(url.from, url.to).slice(0, 2_000_000) : "";
    const id = /\{#(fig:[^\s}]+)/.exec(slice(node.from, node.to));
    const target = id ? targets.get(id[1]) : null;
    return { t: "figure", alt, number: target ? target.number : 0, src };
  }

  function paragraph(node) {
    const first = node.firstChild;
    // `[^1]: The note.` defines a note. It goes with the notes, not where it's written.
    if (first && first.name === "FootnoteRef" && first.from === node.from && slice(first.to, first.to + 1) === ":") {
      // Notes written one under another, with no blank line, arrive as one paragraph. Each starts a line.
      const starts = [];
      for (let child = first; child; child = child.nextSibling) {
        const lineStart = state.doc.lineAt(child.from).from;
        if (child.name === "FootnoteRef" && child.from === lineStart && slice(child.to, child.to + 1) === ":") starts.push(child);
      }
      starts.forEach((start, index) => {
        const label = slice(start.from + 2, start.to - 1);
        const end = index + 1 < starts.length ? starts[index + 1].from : node.to;
        const runs = trimmed(inline(node, start.to + 1, end, {}, []));
        if (!definitions.has(label)) definitions.set(label, [{ t: "p", runs }]);
      });
      return null;
    }
    if (slice(node.from, node.to).trim() === "\\newpage") return { t: "pagebreak" };
    return figure(node) || { t: "p", runs: trimmed(inline(node, node.from, node.to, {}, [])) };
  }

  function list(node) {
    const ordered = node.name === "OrderedList";
    const items = [];
    let start = 1;
    for (let item = node.firstChild; item; item = item.nextSibling) {
      if (item.name !== "ListItem") continue;
      const mark = item.getChild("ListMark");
      if (ordered && items.length === 0 && mark) start = Math.min(1e6, parseInt(slice(mark.from, mark.to), 10) || 1);
      let task = null;
      const content = [];
      for (let child = item.firstChild; child; child = child.nextSibling) {
        if (child.name === "Task") {
          const marker = child.getChild("TaskMarker");
          task = marker ? /x/i.test(slice(marker.from, marker.to)) : false;
          content.push({ t: "p", runs: trimmed(inline(child, marker ? marker.to : child.from, child.to, {}, [])) });
        } else if (child.name !== "ListMark") {
          content.push(...block(child));
        }
      }
      items.push({ task, blocks: content });
    }
    return { t: "list", ordered, start, items };
  }

  function table(node) {
    const rows = [];
    for (let row = node.firstChild; row; row = row.nextSibling) {
      if (row.name !== "TableHeader" && row.name !== "TableRow") continue;
      const cells = [];
      for (let cell = row.firstChild; cell; cell = cell.nextSibling) {
        if (cell.name === "TableCell") cells.push(trimmed(inline(cell, cell.from, cell.to, {}, [])));
      }
      rows.push(cells);
    }
    return { t: "table", header: rows[0] || [], rows: rows.slice(1) };
  }

  function block(node) {
    if (++count > maxBlocks) return [];
    const name = node.name;
    const level = /^(?:ATX|Setext)Heading(\d)$/.exec(name);
    if (level) return [heading(node, Number(level[1]))];
    switch (name) {
      case "Paragraph": {
        const made = paragraph(node);
        return made ? [made] : [];
      }
      case "Blockquote": {
        const blocks = [];
        for (let child = node.firstChild; child; child = child.nextSibling) if (child.name !== "QuoteMark") blocks.push(...block(child));
        return [{ t: "quote", blocks }];
      }
      case "BulletList":
      case "OrderedList":
        return [list(node)];
      case "FencedCode":
      case "CodeBlock": {
        const parts = [];
        for (let child = node.firstChild; child; child = child.nextSibling) if (child.name === "CodeText") parts.push(slice(child.from, child.to));
        const text = name === "FencedCode" ? parts.join("") : slice(node.from, node.to).replace(/^ {4}/gm, "");
        return [{ t: "code", text }];
      }
      case "Table":
        return [table(node)];
      case "HorizontalRule":
        return [{ t: "rule" }];
      case "HTMLBlock":
        return [{ t: "p", runs: [{ text: plain(slice(node.from, node.to).replace(/<[^>]*>/g, " ")).trim() }] }];
      case "FrontMatter":
      case "CommentBlock":
      case "LinkReference":
      case "ProcessingInstructionBlock":
        return [];
      default:
        return [];
    }
  }

  const blocks = [];
  for (let node = tree.topNode.firstChild; node; node = node.nextSibling) blocks.push(...block(node));
  const notes = [...noteNumbers.entries()]
    .sort((a, b) => a[1] - b[1])
    .map(([label, number]) => ({ number, blocks: definitions.get(label) || [] }));
  const bib = bibliography();
  return { meta: frontMatter(text), blocks: blocks.filter((b) => b.t !== "p" || b.runs.length), notes, bibliography: bib };
}
