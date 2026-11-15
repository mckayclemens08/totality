// Live preview, as in Obsidian: the text is the Markdown, styled in place. A line's symbols (the `#`
// of a heading, the stars around bold) show only while the cursor is on that line, so the page reads
// cleanly and nothing is hidden from the person editing it.
import { Decoration, ViewPlugin, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { StateEffect } from "@codemirror/state";
import {
  scholarlyIndex, citationKeys, isCrossRef, crossRefText, plainCitation, locator, NoteMarker, ChipWidget,
} from "./scholarly.js";
import { parseWiki, titleKey, WikiWidget } from "./wiki.js";

/// How citations read on the page. Swift's library and the style engine replace the plain form.
let citationText = (keys, locatorText, narrative) => plainCitation(keys, locatorText, new Map());

/// Sets how citations read, and redraws them.
export const refreshCitations = StateEffect.define();
export function setCitationText(render) {
  citationText = render;
}

/// The docs a wiki link can reach, and what following one does. Main sets both. Redraw with
/// `refreshCitations` after changing them.
let knownDocs = new Set();
let followWiki = () => {};
export function setWikiDocs(docs, follow) {
  knownDocs = docs;
  if (follow) followWiki = follow;
}

class BulletWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-tl-bullet";
    span.textContent = "•";
    return span;
  }
}

class CheckboxWidget extends WidgetType {
  constructor(checked, pos) {
    super();
    this.checked = checked;
    this.pos = pos;
  }
  eq(other) {
    return other.checked === this.checked && other.pos === this.pos;
  }
  toDOM(view) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.className = "cm-tl-task";
    box.checked = this.checked;
    box.setAttribute("aria-label", this.checked ? "Done" : "Not done");
    box.addEventListener("mousedown", (event) => event.preventDefault());
    box.addEventListener("click", (event) => {
      event.preventDefault();
      // The marker is `[ ]` or `[x]`. Only the middle character changes.
      view.dispatch({ changes: { from: this.pos + 1, to: this.pos + 2, insert: this.checked ? " " : "x" }, userEvent: "input.check" });
    });
    return box;
  }
  ignoreEvent() {
    return false;
  }
}

class RuleWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const rule = document.createElement("span");
    rule.className = "cm-tl-rule";
    rule.setAttribute("role", "separator");
    return rule;
  }
}

/// An image is never loaded, because the editor has no network. It shows as its description.
class ImageWidget extends WidgetType {
  constructor(alt) {
    super();
    this.alt = alt;
  }
  eq(other) {
    return other.alt === this.alt;
  }
  toDOM() {
    const chip = document.createElement("span");
    chip.className = "cm-tl-image";
    chip.textContent = this.alt ? `Image: ${this.alt}` : "Image";
    return chip;
  }
}

const hide = Decoration.replace({});
const bullet = Decoration.replace({ widget: new BulletWidget() });
const rule = Decoration.replace({ widget: new RuleWidget() });
const mark = (className) => Decoration.mark({ class: className });
const line = (className) => Decoration.line({ class: className });

const marks = {
  StrongEmphasis: mark("cm-tl-strong"),
  Emphasis: mark("cm-tl-em"),
  Strikethrough: mark("cm-tl-strike"),
  InlineCode: mark("cm-tl-code"),
  Link: mark("cm-tl-link"),
  Autolink: mark("cm-tl-link"),
  Superscript: mark("cm-tl-sup"),
  Subscript: mark("cm-tl-sub"),
};

/// The symbols that only show on the line being edited.
const inlineMarks = new Set(["EmphasisMark", "CodeMark", "StrikethroughMark", "SuperscriptMark", "SubscriptMark"]);

/// Line numbers the cursor or a selection is on.
function activeLines(state) {
  const lines = new Set();
  for (const range of state.selection.ranges) {
    const first = state.doc.lineAt(range.from).number;
    const last = state.doc.lineAt(range.to).number;
    for (let number = first; number <= last; number++) lines.add(number);
  }
  return lines;
}

function decorate(view, focused) {
  const { state } = view;
  // Without focus nothing is being edited, so every line reads as finished.
  const active = focused ? activeLines(state) : new Set();
  const isActive = (pos) => active.has(state.doc.lineAt(pos).number);
  const found = [];
  const lineClass = (from, to, className) => {
    for (let pos = from; pos <= to; ) {
      const each = state.doc.lineAt(pos);
      found.push(line(className).range(each.from));
      pos = each.to + 1;
    }
  };

  const index = state.field(scholarlyIndex, false) || { notes: { order: new Map() }, labels: new Map() };

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter(node) {
        const name = node.name;
        const heading = /^(?:ATX|Setext)Heading(\d)$/.exec(name);
        if (heading) {
          lineClass(node.from, node.to, `cm-tl-h${heading[1]}`);
          return;
        }
        if (name === "HeaderMark") {
          const text = state.sliceDoc(node.from, node.to);
          if (isActive(node.from) || !text.startsWith("#")) return;
          // The space after `#` goes too, or the heading would start with a gap.
          const end = state.sliceDoc(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
          if (node.to > node.from) found.push(hide.range(node.from, end));
          return;
        }
        if (marks[name]) {
          if (node.to > node.from) found.push(marks[name].range(node.from, node.to));
          if (name === "Link" && !isActive(node.from)) {
            // `[words](address)` reads as just the words.
            const text = state.sliceDoc(node.from, node.to);
            const close = text.indexOf("](");
            if (text.startsWith("[") && close > 0) {
              found.push(hide.range(node.from, node.from + 1));
              found.push(hide.range(node.from + close, node.to));
            }
            return false;
          }
          return;
        }
        if (inlineMarks.has(name)) {
          if (!isActive(node.from) && node.to > node.from) found.push(hide.range(node.from, node.to));
          return;
        }
        if (name === "Image") {
          if (!isActive(node.from)) {
            const text = state.sliceDoc(node.from, node.to);
            const alt = text.slice(2, Math.max(2, text.indexOf("](")));
            found.push(Decoration.replace({ widget: new ImageWidget(alt) }).range(node.from, node.to));
          }
          return false;
        }
        if (name === "Escape") {
          if (!isActive(node.from)) found.push(hide.range(node.from, node.from + 1));
          return;
        }
        if (name === "Blockquote") {
          lineClass(node.from, node.to, "cm-tl-quote");
          return;
        }
        if (name === "QuoteMark") {
          if (isActive(node.from)) return;
          const end = state.sliceDoc(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
          found.push(hide.range(node.from, end));
          return;
        }
        if (name === "ListItem") {
          // Only the item's first line: a wrapped line hangs under the words, not the bullet.
          found.push(line("cm-tl-item").range(state.doc.lineAt(node.from).from));
          return;
        }
        if (name === "ListMark") {
          const text = state.sliceDoc(node.from, node.to);
          const task = state.sliceDoc(node.to + 1, node.to + 4);
          // A task's own box stands in for its bullet.
          if (/^[-*+]$/.test(text) && !isActive(node.from) && !/^\[[ xX]\]$/.test(task)) {
            const end = state.sliceDoc(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
            found.push(bullet.range(node.from, end));
          }
          return;
        }
        if (name === "TaskMarker") {
          if (isActive(node.from)) return;
          const checked = /x/i.test(state.sliceDoc(node.from, node.to));
          const lineStart = state.doc.lineAt(node.from).from;
          const before = state.sliceDoc(lineStart, node.from);
          const listMark = before.search(/[-*+][ \t]+$/);
          // The bullet before the box goes, so a task reads as a box and its words.
          const from = listMark >= 0 ? lineStart + listMark : node.from;
          const end = state.sliceDoc(node.to, node.to + 1) === " " ? node.to + 1 : node.to;
          found.push(Decoration.replace({ widget: new CheckboxWidget(checked, node.from) }).range(from, end));
          if (checked) {
            const lineEnd = state.doc.lineAt(node.from).to;
            if (lineEnd > node.to) found.push(mark("cm-tl-done").range(node.to, lineEnd));
          }
          return;
        }
        if (name === "HorizontalRule") {
          if (isActive(node.from)) {
            lineClass(node.from, node.to, "cm-tl-rule-line");
          } else {
            found.push(rule.range(node.from, node.to));
          }
          return;
        }
        if (name === "FencedCode" || name === "CodeBlock") {
          lineClass(node.from, node.to, "cm-tl-codeblock");
          return false;
        }
        if (name === "FrontMatter") {
          lineClass(node.from, node.to, "cm-tl-frontmatter");
          return false;
        }
        if (name === "FootnoteRef") {
          const text = state.sliceDoc(node.from, node.to);
          const label = text.slice(2, -1);
          const lineStart = state.doc.lineAt(node.from).from;
          const isDefinition = node.from === lineStart && state.sliceDoc(node.to, node.to + 1) === ":";
          const number = index.notes.order.get(label);
          if (isDefinition) {
            lineClass(node.from, node.from, "cm-tl-notedef");
            if (!isActive(node.from)) {
              const end = state.sliceDoc(node.to + 1, node.to + 2) === " " ? node.to + 2 : node.to + 1;
              found.push(Decoration.replace({ widget: new NoteMarker(number ? `${number}.` : `${label}.`) }).range(node.from, end));
            }
          } else if (!isActive(node.from)) {
            found.push(Decoration.replace({ widget: new NoteMarker(number ? String(number) : "?") }).range(node.from, node.to));
          }
          return false;
        }
        if (name === "InlineNote") {
          found.push(mark("cm-tl-inlinenote").range(node.from, node.to));
          return false;
        }
        if (name === "Citation" || name === "NarrativeCitation") {
          const text = state.sliceDoc(node.from, node.to);
          const keys = name === "Citation" ? citationKeys(text) : [{ key: text.slice(1), suppressAuthor: false }];
          const cross = keys.length > 0 && keys.every(({ key }) => isCrossRef(key));
          if (isActive(node.from)) {
            found.push(mark(cross ? "cm-tl-xref-src" : "cm-tl-cite-src").range(node.from, node.to));
          } else {
            const shown = cross
              ? keys.map(({ key }) => crossRefText(key, index.labels)).join(", ")
              : citationText(keys, name === "Citation" ? locator(text) : "", name === "NarrativeCitation");
            found.push(Decoration.replace({ widget: new ChipWidget(shown, cross ? "cm-tl-xref" : "cm-tl-cite") }).range(node.from, node.to));
          }
          return false;
        }
        if (name === "WikiLink") {
          const link = parseWiki(state.sliceDoc(node.from, node.to));
          if (!link) return false;
          if (isActive(node.from)) {
            found.push(mark("cm-tl-wiki-src").range(node.from, node.to));
          } else {
            // A heading in this doc always exists as far as the page can tell. The jump finds it or not.
            const exists = !link.target || knownDocs.has(titleKey(link.target));
            found.push(Decoration.replace({ widget: new WikiWidget(link, exists, followWiki) }).range(node.from, node.to));
          }
          return false;
        }
        if (name === "Attribute") {
          if (isActive(node.from)) found.push(mark("cm-tl-symbol").range(node.from, node.to));
          else found.push(hide.range(state.sliceDoc(node.from - 1, node.from) === " " ? node.from - 1 : node.from, node.to));
          return false;
        }
        if (name === "Table") {
          lineClass(node.from, node.to, "cm-tl-table");
          return false;
        }
      },
    });
  }
  return Decoration.set(found, true);
}

export const livePreview = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = decorate(view, view.hasFocus);
    }
    update(update) {
      const refreshed = update.transactions.some((tr) => tr.effects.some((effect) => effect.is(refreshCitations)));
      if (refreshed || update.docChanged || update.viewportChanged || update.selectionSet || update.focusChanged ||
          syntaxTree(update.startState) !== syntaxTree(update.state)) {
        this.decorations = decorate(update.view, update.view.hasFocus);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);
