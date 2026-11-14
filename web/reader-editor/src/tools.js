// Writing tools: word counts, the outline and section folding, focus mode, typewriter scrolling,
// smart punctuation, and find and replace. Each works on the Markdown text itself, so nothing here
// changes what's stored except the punctuation the person types.
import { EditorState, EditorSelection } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin } from "@codemirror/view";
import { foldService, foldEffect, unfoldEffect, foldedRanges, syntaxTree, codeFolding } from "@codemirror/language";
import { SearchQuery, setSearchQuery, getSearchQuery, findNext, findPrevious, replaceNext, replaceAll, search, openSearchPanel, closeSearchPanel } from "@codemirror/search";

// MARK: Counting

const wordPattern = /[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/gu;

/// Words as a reader would count them: a link's address, a note's marker and the symbols don't count.
export function countWords(markdown) {
  const words = markdown
    .replace(/\]\([^)\n]*\)/g, "]")
    .replace(/\[\^[^\]\n]+\]:?/g, " ")
    .replace(/<(?:https?|mailto):[^>\s]+>/g, " ")
    .replace(/^```.*$/gm, " ");
  const found = words.match(wordPattern);
  return found ? found.length : 0;
}

const headingLine = /^(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/;
const fenceLine = /^[ \t]{0,3}(`{3,}|~{3,})/;

/// The headings, in order, with where each starts. A `#` inside a code block isn't one.
export function outline(doc, limit = 2000) {
  const headings = [];
  let fence = null;
  for (let number = 1; number <= doc.lines && headings.length < limit; number++) {
    const line = doc.line(number);
    const open = fenceLine.exec(line.text);
    if (fence) {
      if (open && open[1][0] === fence[0] && open[1].length >= fence.length) fence = null;
      continue;
    }
    if (open) {
      fence = open[1];
      continue;
    }
    const heading = headingLine.exec(line.text);
    if (heading) {
      const text = heading[2].replace(/\\(.)/g, "$1").replace(/[*_`~]+/g, "").replace(/\[([^\]]*)\]\([^)]*\)/g, "$1");
      headings.push({ level: heading[1].length, text: text.slice(0, 200), from: line.from, line: number });
    }
  }
  return headings;
}

/// Where the section a position is in starts and ends: from its heading to the next heading at the same
/// level or higher. Before the first heading, the section is everything up to it.
export function sectionAt(state, pos, headings = outline(state.doc)) {
  let start = 0;
  let level = 0;
  let index = -1;
  headings.forEach((heading, i) => {
    if (heading.from <= pos) {
      start = heading.from;
      level = heading.level;
      index = i;
    }
  });
  let end = state.doc.length;
  for (let i = index + 1; i < headings.length; i++) {
    if (level === 0 || headings[i].level <= level) {
      end = headings[i].from;
      break;
    }
  }
  return { from: start, to: end };
}

export function stats(state, headings = outline(state.doc)) {
  const text = state.doc.toString();
  const selected = state.selection.ranges.map((range) => state.sliceDoc(range.from, range.to)).join(" ");
  const section = sectionAt(state, state.selection.main.head, headings);
  return {
    words: countWords(text),
    selection: countWords(selected),
    section: countWords(state.sliceDoc(section.from, section.to)),
    characters: text.length,
  };
}

// MARK: Folding sections

/// A heading folds everything under it, up to the next heading at its level or higher.
export const sectionFolding = foldService.of((state, lineStart, lineEnd) => {
  const line = state.doc.lineAt(lineStart);
  const heading = headingLine.exec(line.text);
  if (!heading) return null;
  const level = heading[1].length;
  let end = state.doc.length;
  let fence = null;
  for (let number = line.number + 1; number <= state.doc.lines; number++) {
    const next = state.doc.line(number);
    const open = fenceLine.exec(next.text);
    if (fence) {
      if (open && open[1][0] === fence[0]) fence = null;
      continue;
    }
    if (open) {
      fence = open[1];
      continue;
    }
    const found = headingLine.exec(next.text);
    if (found && found[1].length <= level) {
      end = next.from - 1;
      break;
    }
  }
  // Blank lines before the next heading stay visible, so a folded section keeps its spacing.
  while (end > lineEnd && /\s/.test(state.sliceDoc(end - 1, end))) end -= 1;
  return end > lineEnd ? { from: lineEnd, to: end } : null;
});

export const folding = [sectionFolding, codeFolding({ placeholderText: "…" })];

/// Folds or unfolds the section a heading starts. Returns whether it's folded now.
export function toggleSection(view, pos) {
  const line = view.state.doc.lineAt(Math.max(0, Math.min(pos, view.state.doc.length)));
  let folded = null;
  foldedRanges(view.state).between(line.to, line.to + 1, (from, to) => {
    if (from === line.to) folded = { from, to };
  });
  if (folded) {
    view.dispatch({ effects: unfoldEffect.of(folded) });
    return false;
  }
  const range = view.state.facet(foldService)[0](view.state, line.from, line.to);
  if (!range) return false;
  view.dispatch({ effects: foldEffect.of(range) });
  return true;
}

/// Unfolds anything that hides a position, so jumping there shows it.
export function revealing(state, pos) {
  const effects = [];
  foldedRanges(state).between(pos, pos, (from, to) => {
    if (from < pos && to >= pos) effects.push(unfoldEffect.of({ from, to }));
  });
  return effects;
}

// MARK: Focus mode and typewriter scrolling

const dim = Decoration.line({ class: "cm-tl-dim" });

/// The paragraph the cursor is in: the lines between the blank lines around it.
export function paragraphAt(state, pos) {
  let first = state.doc.lineAt(pos);
  let last = first;
  while (first.number > 1) {
    const previous = state.doc.line(first.number - 1);
    if (!previous.text.trim()) break;
    first = previous;
  }
  while (last.number < state.doc.lines) {
    const next = state.doc.line(last.number + 1);
    if (!next.text.trim()) break;
    last = next;
  }
  return { from: first.from, to: last.to };
}

function dimmed(view) {
  const ranges = [];
  const current = paragraphAt(view.state, view.state.selection.main.head);
  for (const { from, to } of view.visibleRanges) {
    for (let pos = from; pos <= to; ) {
      const line = view.state.doc.lineAt(pos);
      if (line.to < current.from || line.from > current.to) ranges.push(dim.range(line.from));
      pos = line.to + 1;
    }
  }
  return Decoration.set(ranges);
}

/// Everything but the paragraph being written fades back.
export const focusMode = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = dimmed(view);
    }
    update(update) {
      if (update.docChanged || update.selectionSet || update.viewportChanged) this.decorations = dimmed(update.view);
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

/// Keeps the line being written in the middle of the screen, as on a typewriter.
export const typewriter = EditorState.transactionExtender.of((transaction) => {
  if (!transaction.selection && !transaction.docChanged) return null;
  if (!transaction.isUserEvent("input") && !transaction.isUserEvent("delete") && !transaction.isUserEvent("select")) return null;
  const head = (transaction.selection || transaction.startState.selection.map(transaction.changes)).main.head;
  return { effects: EditorView.scrollIntoView(head, { y: "center" }) };
});

// MARK: Smart punctuation

const opensBefore = /[\s([{—–"'“‘]/;

function inCode(state, pos) {
  // Inline code that isn't closed yet isn't in the syntax tree, but an odd count of backticks means it.
  const line = state.doc.lineAt(pos);
  if ((state.sliceDoc(line.from, pos).match(/`/g) || []).length % 2 === 1) return true;
  for (let node = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
    if (["InlineCode", "FencedCode", "CodeBlock", "CodeText"].includes(node.name)) return true;
  }
  return false;
}

/// What a straight quote or a second hyphen becomes, given what comes before it. Null keeps it as typed.
export function smartReplacement(state, from, text) {
  if (inCode(state, from)) return null;
  const before = state.sliceDoc(Math.max(0, from - 1), from);
  const opening = from === 0 || opensBefore.test(before);
  if (text === '"') return { from, insert: opening ? "“" : "”" };
  if (text === "'") return { from, insert: opening ? "‘" : "’" };
  if (text === "-" && before === "-") {
    // A line of dashes is a rule or a table, never a dash.
    const line = state.doc.lineAt(from);
    if (/^[\s\-|:]*$/.test(state.sliceDoc(line.from, from))) return null;
    return { from: from - 1, insert: "—" };
  }
  return null;
}

export const smartPunctuation = EditorView.inputHandler.of((view, from, to, text) => {
  if (from !== to || text.length !== 1) return false;
  const replacement = smartReplacement(view.state, from, text);
  if (!replacement) return false;
  view.dispatch({
    changes: { from: replacement.from, to, insert: replacement.insert },
    selection: EditorSelection.cursor(replacement.from + replacement.insert.length),
    userEvent: "input.type",
  });
  return true;
});

// MARK: Find and replace

/// The search runs without CodeMirror's own panel: Swift draws the bar, and this keeps an empty one
/// open so matches are highlighted.
export const findSupport = search({
  top: true,
  createPanel: () => {
    const dom = document.createElement("div");
    dom.className = "cm-tl-find";
    return { dom, top: true };
  },
});

/// How many matches there are, and which one is selected, counting no further than `limit`.
export function matches(state, limit = 10000) {
  const query = getSearchQuery(state);
  if (!query.valid) return { count: 0, current: 0 };
  const cursor = query.getCursor(state);
  const selected = state.selection.main;
  let count = 0;
  let current = 0;
  for (let next = cursor.next(); !next.done && count < limit; next = cursor.next()) {
    count += 1;
    if (next.value.from === selected.from && next.value.to === selected.to) current = count;
  }
  return { count, current };
}

export function setFind(view, options) {
  const query = new SearchQuery({
    search: String(options.query || ""),
    replace: String(options.replace || ""),
    caseSensitive: Boolean(options.caseSensitive),
    wholeWord: Boolean(options.wholeWord),
    literal: true,
  });
  openSearchPanel(view);
  view.dispatch({ effects: setSearchQuery.of(query) });
}

export const find = { findNext, findPrevious, replaceNext, replaceAll, closeSearchPanel };
