// Scholarly Markdown, in Pandoc's own syntax so the same file exports the same everywhere:
//   front matter   ---\ncsl: apa\n---           (the citation style, and anything else Pandoc reads)
//   footnotes      text[^1]   …   [^1]: The note.
//   citations      [@smith2020, p. 4]   [-@smith2020]   @smith2020 says
//   cross-refs     # Method {#sec:method}   ![Map](map.png){#fig:map}   see @sec:method and [@fig:map]
// The parser below teaches CodeMirror these shapes. Nothing is converted: the text stays as typed.
import { StateField, StateEffect } from "@codemirror/state";
import { Decoration, EditorView, WidgetType } from "@codemirror/view";

// MARK: Recognising the syntax

/// Pandoc's citation key: a letter, digit or underscore, then those and some inner punctuation. It
/// can't end on punctuation, so the full stop after `@smith2020.` isn't part of the key.
export const keyPattern = /[\p{L}\p{N}_](?:[\p{L}\p{N}_:.#$%&\-+?<>~/]*[\p{L}\p{N}_])?/u;
const crossKinds = { sec: "Section", fig: "Figure", tbl: "Table" };

export function isCrossRef(key) {
  const colon = key.indexOf(":");
  return colon > 0 && Object.prototype.hasOwnProperty.call(crossKinds, key.slice(0, colon));
}

/// The keys in a bracketed citation, with whether the author is suppressed (`-@`).
export function citationKeys(text) {
  const keys = [];
  const pattern = new RegExp(`(-?)@(${keyPattern.source})`, "gu");
  for (const match of text.matchAll(pattern)) {
    const before = match.index > 0 ? text[match.index - 1] : " ";
    if (/[\p{L}\p{N}]/u.test(before) && match[1] === "") continue; // an email address
    keys.push({ key: match[2], suppressAuthor: match[1] === "-" });
  }
  return keys;
}

const bracketCitation = new RegExp(`^\\[[^\\[\\]\\n]*?-?@${keyPattern.source}[^\\[\\]\\n]*\\](?![(\\[])`, "u");
const narrative = new RegExp(`^@${keyPattern.source}`, "u");

const FrontMatter = {
  name: "FrontMatter",
  before: "HorizontalRule",
  parse(cx, line) {
    if (cx.lineStart !== 0 || line.text !== "---") return false;
    const start = cx.lineStart;
    let end = start + line.text.length;
    while (cx.nextLine()) {
      end = cx.lineStart + line.text.length;
      if (line.text === "---" || line.text === "...") {
        cx.nextLine();
        cx.addElement(cx.elt("FrontMatter", start, end));
        return true;
      }
    }
    cx.addElement(cx.elt("FrontMatter", start, end));
    return true;
  },
};

const inline = [
  {
    name: "FootnoteRef",
    before: "Link",
    parse(cx, next, pos) {
      if (next !== 91 /* [ */ || cx.char(pos + 1) !== 94 /* ^ */) return -1;
      const rest = cx.slice(pos, cx.end);
      const found = /^\[\^([^\]\s]+)\]/.exec(rest);
      return found ? cx.addElement(cx.elt("FootnoteRef", pos, pos + found[0].length)) : -1;
    },
  },
  {
    name: "InlineNote",
    before: "Link",
    parse(cx, next, pos) {
      if (next !== 94 /* ^ */ || cx.char(pos + 1) !== 91 /* [ */) return -1;
      const close = cx.slice(pos, cx.end).indexOf("]");
      return close > 2 ? cx.addElement(cx.elt("InlineNote", pos, pos + close + 1)) : -1;
    },
  },
  {
    name: "Citation",
    before: "Link",
    parse(cx, next, pos) {
      if (next !== 91 /* [ */) return -1;
      const found = bracketCitation.exec(cx.slice(pos, cx.end));
      return found ? cx.addElement(cx.elt("Citation", pos, pos + found[0].length)) : -1;
    },
  },
  {
    name: "NarrativeCitation",
    parse(cx, next, pos) {
      if (next !== 64 /* @ */) return -1;
      const before = pos > cx.offset ? cx.slice(pos - 1, pos) : " ";
      if (/[\p{L}\p{N}]/u.test(before)) return -1;
      const found = narrative.exec(cx.slice(pos, cx.end));
      return found ? cx.addElement(cx.elt("NarrativeCitation", pos, pos + found[0].length)) : -1;
    },
  },
  {
    name: "Attribute",
    parse(cx, next, pos) {
      if (next !== 123 /* { */) return -1;
      const found = /^\{#[\p{L}\p{N}_:.\-]+(?:\s[^}\n]*)?\}/u.exec(cx.slice(pos, cx.end));
      return found ? cx.addElement(cx.elt("Attribute", pos, pos + found[0].length)) : -1;
    },
  },
];

export const scholarlySyntax = {
  defineNodes: ["FrontMatter", "FootnoteRef", "InlineNote", "Citation", "NarrativeCitation", "Attribute"],
  parseBlock: [FrontMatter],
  parseInline: inline,
};

// MARK: Reading the whole doc

const footnoteRef = /\[\^([^\]\s]+)\](?!:)/g;
const footnoteDef = /^\[\^([^\]\s]+)\]:[ \t]?/;
const labelled = /\{#((?:sec|fig|tbl):[\p{L}\p{N}_:.\-]+)[^}]*\}/u;

/// Footnote numbers, in the order the notes are first referred to, and where each is defined.
export function footnotes(text) {
  const order = new Map();
  const defined = new Map();
  let offset = 0;
  let fence = false;
  for (const line of text.split("\n")) {
    if (/^\s{0,3}(```|~~~)/.test(line)) fence = !fence;
    if (!fence) {
      const definition = footnoteDef.exec(line);
      if (definition) defined.set(definition[1], offset);
      const body = definition ? line.slice(definition[0].length) : line;
      for (const match of body.matchAll(footnoteRef)) {
        if (!order.has(match[1])) order.set(match[1], order.size + 1);
      }
    }
    offset += line.length + 1;
  }
  return { order, defined };
}

/// Every label a cross-reference can point at, numbered in order within its kind.
export function labels(text) {
  const found = new Map();
  const counts = { sec: 0, fig: 0, tbl: 0 };
  let offset = 0;
  let fence = false;
  for (const line of text.split("\n")) {
    if (/^\s{0,3}(```|~~~)/.test(line)) fence = !fence;
    const match = fence ? null : labelled.exec(line);
    if (match) {
      const id = match[1];
      const kind = id.slice(0, id.indexOf(":"));
      counts[kind] += 1;
      let caption = line;
      if (kind === "sec") caption = line.replace(/^#{1,6}\s+/, "");
      else if (kind === "fig") caption = (/!\[([^\]]*)\]/.exec(line) || ["", ""])[1];
      else caption = line.replace(/^(?:Table|:)\s*:?\s*/, "");
      caption = caption.replace(labelled, "").replace(/[*_`]/g, "").trim();
      if (!found.has(id)) found.set(id, { id, kind, number: counts[kind], caption: caption.slice(0, 200), from: offset });
    }
    offset += line.length + 1;
  }
  return found;
}

/// How a cross-reference reads: "Figure 2", or a section by its heading.
export function crossRefText(key, index) {
  const target = index.get(key);
  if (!target) return `??${key}`;
  if (target.kind === "sec") return `“${target.caption}”`;
  return `${crossKinds[target.kind]} ${target.number}`;
}

/// A short form of a citation for when no style engine is there: "Smith 2020, p. 4".
export function plainCitation(keys, locatorText, library) {
  const parts = keys.map(({ key, suppressAuthor }) => {
    const item = library.get(key);
    if (!item) return `?${key}`;
    const author = (item.author && item.author[0] && (item.author[0].family || item.author[0].literal)) || item.title || key;
    const year = (item.issued && item.issued["date-parts"] && item.issued["date-parts"][0] && item.issued["date-parts"][0][0]) || "n.d.";
    return suppressAuthor ? `${year}` : `${author} ${year}`;
  });
  return parts.join("; ") + (locatorText ? `, ${locatorText}` : "");
}

/// What follows the last key in brackets, such as `, p. 4`.
export function locator(text) {
  const inner = text.replace(/^\[|\]$/g, "");
  const last = inner.split(";").pop() || "";
  const after = last.replace(new RegExp(`^[^@]*?-?@${keyPattern.source}`, "u"), "");
  return after.replace(/^\s*,\s*/, "").trim();
}

// MARK: The shared state the preview reads

/// Footnote numbers and cross-reference targets, worked out once per change of the doc.
export const scholarlyIndex = StateField.define({
  create(state) {
    const text = state.doc.toString();
    return { notes: footnotes(text), labels: labels(text) };
  },
  update(value, transaction) {
    if (!transaction.docChanged) return value;
    const text = transaction.state.doc.toString();
    return { notes: footnotes(text), labels: labels(text) };
  },
});

// MARK: Widgets

export class NoteMarker extends WidgetType {
  constructor(text) {
    super();
    this.text = text;
  }
  eq(other) {
    return other.text === this.text;
  }
  toDOM() {
    const sup = document.createElement("sup");
    sup.className = "cm-tl-noteref";
    sup.textContent = this.text;
    return sup;
  }
}

export class ChipWidget extends WidgetType {
  constructor(text, className) {
    super();
    this.text = text;
    this.className = className;
  }
  eq(other) {
    return other.text === this.text && other.className === this.className;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = this.className;
    span.textContent = this.text;
    return span;
  }
}

/// The bibliography, drawn after the last line. It's never part of the text: export makes its own.
class BibliographyWidget extends WidgetType {
  constructor(heading, entries) {
    super();
    this.heading = heading;
    this.entries = entries;
  }
  eq(other) {
    return other.heading === this.heading && other.entries.join("\n") === this.entries.join("\n");
  }
  toDOM() {
    const section = document.createElement("section");
    section.className = "cm-tl-bibliography";
    section.setAttribute("aria-label", this.heading);
    const title = document.createElement("div");
    title.className = "cm-tl-bibliography-title";
    title.textContent = this.heading;
    section.appendChild(title);
    for (const entry of this.entries) {
      const row = document.createElement("div");
      row.className = "cm-tl-bibliography-entry";
      // Entries are plain text from the style engine, never markup.
      row.textContent = entry;
      section.appendChild(row);
    }
    return section;
  }
  ignoreEvent() {
    return true;
  }
}

/// Holds the bibliography the page shows, as a block after the doc. Set by `setBibliography`. A block
/// widget has to come straight from state, so the field keeps its decoration and moves it with the end.
export const setBibliography = StateEffect.define();

function bibliographyAt(value, end) {
  if (!value.entries.length) return Decoration.none;
  const widget = new BibliographyWidget(value.heading, value.entries);
  return Decoration.set([Decoration.widget({ widget, block: true, side: 1 }).range(end)]);
}

export const bibliography = StateField.define({
  create() {
    return { heading: "", entries: [], decorations: Decoration.none };
  },
  update(value, transaction) {
    for (const effect of transaction.effects) {
      if (effect.is(setBibliography)) {
        const next = { heading: effect.value.heading, entries: effect.value.entries };
        return { ...next, decorations: bibliographyAt(next, transaction.state.doc.length) };
      }
    }
    if (!transaction.docChanged) return value;
    return { ...value, decorations: bibliographyAt(value, transaction.state.doc.length) };
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
});
