// Formatting commands. Each one edits the Markdown text directly, so what's stored is exactly what was
// typed and nothing is converted on save. They take and return plain CodeMirror state, so they run in
// tests without a page.
import { EditorSelection } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";

/// Wraps each selection in a marker such as `**`, or takes the marker away if it's already there.
export function toggleWrap(state, marker) {
  const n = marker.length;
  return state.changeByRange((range) => {
    const before = state.sliceDoc(range.from - n, range.from);
    const after = state.sliceDoc(range.to, range.to + n);
    // `*` mustn't match half of a `**`, or italic inside bold would take bold away.
    const outer = state.sliceDoc(range.from - n - 1, range.from - n);
    const outerAfter = state.sliceDoc(range.to + n, range.to + n + 1);
    const single = n === 1 && (outer === marker || outerAfter === marker);
    if (before === marker && after === marker && !single) {
      return {
        changes: [{ from: range.from - n, to: range.from }, { from: range.to, to: range.to + n }],
        range: EditorSelection.range(range.anchor - n, range.head - n),
      };
    }
    const text = state.sliceDoc(range.from, range.to);
    if (text.length >= 2 * n && text.startsWith(marker) && text.endsWith(marker)) {
      return {
        changes: { from: range.from, to: range.to, insert: text.slice(n, text.length - n) },
        range: EditorSelection.range(range.from, range.to - 2 * n),
      };
    }
    return {
      changes: [{ from: range.from, insert: marker }, { from: range.to, insert: marker }],
      range: EditorSelection.range(range.from + n, range.to + n),
    };
  });
}

/// The lines any selection touches, each once.
function selectedLines(state) {
  const lines = new Map();
  for (const range of state.selection.ranges) {
    for (let pos = range.from; ; ) {
      const line = state.doc.lineAt(pos);
      lines.set(line.number, line);
      if (line.to >= range.to) break;
      pos = line.to + 1;
    }
  }
  return [...lines.values()].sort((a, b) => a.from - b.from);
}

const headingPrefix = /^#{1,6}[ \t]+/;
const listPrefix = /^([ \t]*)(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?/;
const quotePrefix = /^>[ \t]?/;

/// Replaces what starts each selected line. Applying the same thing again takes it away.
function setLinePrefix(state, matcher, prefixFor) {
  const lines = selectedLines(state);
  const all = lines.every((line) => {
    const found = line.text.match(matcher.current);
    return found && found[0] === prefixFor(line, 0, found);
  });
  const changes = lines.map((line, index) => {
    const found = line.text.match(matcher.any);
    const length = found ? found[0].length : 0;
    const insert = all ? "" : prefixFor(line, index, found);
    return { from: line.from, to: line.from + length, insert };
  });
  return state.update({ changes, scrollIntoView: true, userEvent: "input.format" });
}

export function setHeading(state, level) {
  const prefix = level > 0 ? "#".repeat(level) + " " : "";
  const lines = selectedLines(state);
  const changes = lines.map((line) => {
    const found = line.text.match(headingPrefix);
    const current = found ? found[0] : "";
    const insert = current.trim() === prefix.trim() ? "" : prefix;
    return { from: line.from, to: line.from + current.length, insert };
  });
  return state.update({ changes, scrollIntoView: true, userEvent: "input.format" });
}

export function toggleList(state, kind) {
  const marker = (index) => (kind === "numbered" ? `${index + 1}. ` : kind === "task" ? "- [ ] " : "- ");
  const current = kind === "numbered" ? /^[ \t]*\d{1,9}[.)][ \t]+/ : kind === "task" ? /^[ \t]*[-*+][ \t]+\[[ xX]\][ \t]+/ : /^[ \t]*[-*+][ \t]+(?!\[[ xX]\])/;
  return setLinePrefix(state, { current, any: listPrefix }, (line, index, found) => {
    if (found && current.test(line.text)) return found[0];
    return (found ? found[1] : "") + marker(index);
  });
}

export function toggleQuote(state) {
  return setLinePrefix(state, { current: quotePrefix, any: quotePrefix }, (line, index, found) => (found ? found[0] : "> "));
}

/// The link the cursor is in, if any: its whole extent and its address.
export function linkAt(state, pos = state.selection.main.head) {
  let node = syntaxTree(state).resolveInner(pos, -1);
  for (; node; node = node.parent) {
    if (node.name === "Link") {
      const url = node.getChild("URL");
      return { from: node.from, to: node.to, url: url ? state.sliceDoc(url.from, url.to) : "" };
    }
  }
  return null;
}

/// An address in a link can't hold a space or an unmatched bracket, so those are written escaped.
export function linkDestination(url) {
  return url.replace(/[()\\ ]/g, (character) => (character === " " ? "%20" : "\\" + character));
}

/// Makes the selection a link, or changes the address of the link the cursor is in. An empty address
/// takes the link away and keeps its words.
export function setLink(state, url) {
  const existing = linkAt(state);
  if (existing) {
    const text = state.sliceDoc(existing.from, existing.to);
    const label = text.slice(1, text.indexOf("]("));
    const insert = url ? `[${label}](${linkDestination(url)})` : label;
    return state.update({ changes: { from: existing.from, to: existing.to, insert }, userEvent: "input.format" });
  }
  if (!url) return null;
  const range = state.selection.main;
  const label = state.sliceDoc(range.from, range.to) || url;
  const insert = `[${label}](${linkDestination(url)})`;
  return state.update({
    changes: { from: range.from, to: range.to, insert },
    selection: { anchor: range.from + insert.length },
    userEvent: "input.format",
  });
}

/// What the format bar shows as on, for where the cursor is.
export function formatState(state) {
  const pos = state.selection.main.head;
  const line = state.doc.lineAt(pos);
  const heading = line.text.match(headingPrefix);
  const list = line.text.match(/^[ \t]*(?:([-*+])[ \t]+(\[[ xX]\])?|(\d{1,9})[.)][ \t]+)/);
  const result = {
    bold: false,
    italic: false,
    strike: false,
    code: false,
    heading: heading ? heading[0].trim().length : 0,
    list: list ? (list[3] ? "numbered" : list[2] ? "task" : "bullet") : "",
    quote: quotePrefix.test(line.text),
    link: "",
  };
  for (let node = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
    if (node.name === "StrongEmphasis") result.bold = true;
    if (node.name === "Emphasis") result.italic = true;
    if (node.name === "Strikethrough") result.strike = true;
    if (node.name === "InlineCode") result.code = true;
  }
  const link = linkAt(state, pos);
  if (link) result.link = link.url;
  return result;
}
