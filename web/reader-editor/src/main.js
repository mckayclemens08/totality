// The Reader's writing page. Swift owns everything outside the text: it loads a doc in with `load`,
// and runs commands with `command`. This page tells Swift what happened through its one message
// handler: that it's ready, that the text changed (with the text), the counts and outline, and that a
// link or another doc was asked for. It never fetches, stores, or opens anything itself.
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, drawSelection, placeholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab, undo, redo } from "@codemirror/commands";
import { markdown, markdownLanguage, markdownKeymap } from "@codemirror/lang-markdown";
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { Strikethrough, Subscript, Superscript, Table, TaskList } from "@lezer/markdown";
import { livePreview, setCitationText, refreshCitations, setWikiDocs } from "./livePreview.js";
import { wikiSyntax, wikiInsert, docSet, titleKey } from "./wiki.js";
import { scholarlySyntax, scholarlyIndex, bibliography, setBibliography, footnotes, labels } from "./scholarly.js";
import { styles, styleOf, styleChange, citedKeys, cleanItems } from "./cite.js";
import { citeprocEngine } from "./citeproc.js";
import apaStyle from "../csl/apa.csl";
import mlaStyle from "../csl/modern-language-association.csl";
import chicagoStyle from "../csl/chicago-author-date.csl";
import locale from "../csl/locales-en-US.xml";

const cslSources = { styles: { apa: apaStyle, mla: mlaStyle, chicago: chicagoStyle }, locale };
import { toggleWrap, setHeading, toggleList, toggleQuote, setLink, formatState } from "./commands.js";
import {
  outline, stats, folding, toggleSection, revealing, focusMode, typewriter, smartPunctuation,
  findSupport, setFind, matches, find,
} from "./tools.js";

/// How long typing has to pause before the text goes to Swift. Swift saves shortly after that.
const SEND_PAUSE = 250;
/// Counts and the outline are worked out over the whole doc, so they wait for a slightly longer pause.
const COUNT_PAUSE = 400;

function post(message) {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editor;
  if (handler) handler.postMessage(message);
}

// Only the words are coloured differently, and only by weight and the one accent.
const highlight = HighlightStyle.define([
  { tag: tags.monospace, class: "cm-tl-mono" },
  { tag: tags.processingInstruction, class: "cm-tl-symbol" },
  { tag: tags.meta, class: "cm-tl-symbol" },
  { tag: tags.url, class: "cm-tl-symbol" },
  { tag: tags.quote, class: "cm-tl-quote-text" },
]);

// CodeMirror's own theme sets a monospace font. Its selectors outrank a stylesheet's, so this goes
// through its theme instead.
const pageTheme = EditorView.theme({
  "&": { backgroundColor: "transparent" },
  ".cm-scroller": { fontFamily: "inherit", lineHeight: "1.6", overflow: "visible" },
  ".cm-content": { fontFamily: "inherit" },
});

const editable = new Compartment();
const focusing = new Compartment();
const centring = new Compartment();
const punctuation = new Compartment();
let settings = { focus: false, typewriter: false, smartPunctuation: true, serif: false };
let countTimer = null;
let lastOutline = "";
let library = new Map();
let engine = citeprocEngine(library, cslSources);
let lastBibliography = "";
let view;
let revision = 0;
let sendTimer = null;
let lastState = "";

function sendText() {
  clearTimeout(sendTimer);
  sendTimer = null;
  post({ type: "text", revision, text: view.state.doc.toString() });
}

function sendCounts() {
  clearTimeout(countTimer);
  countTimer = null;
  if (!view) return;
  const headings = outline(view.state.doc);
  post({ type: "stats", stats: stats(view.state, headings) });
  const text = view.state.doc.toString();
  const targets = [...labels(text).values()].map(({ id, kind, number, caption }) => ({ id, kind, number, caption }));
  const style = styleOf(text);
  const shape = JSON.stringify([headings.map((h) => [h.level, h.text, h.from]), targets, style]);
  if (shape !== lastOutline) {
    lastOutline = shape;
    post({ type: "outline", headings: headings.map(({ level, text, from }) => ({ level, text, from })), labels: targets, style });
  }
  updateBibliography(text);
}

/// Redraws the bibliography under the doc when what's cited, the library or the style changes.
function updateBibliography(text) {
  const style = styleOf(text);
  const entries = engine.bibliography(citedKeys(text), style);
  const shape = JSON.stringify([style, entries]);
  if (shape === lastBibliography) return;
  lastBibliography = shape;
  view.dispatch({ effects: setBibliography.of({ heading: styles[style].heading, entries }) });
}

function useLibrary(items) {
  library = cleanItems(items);
  engine = citeprocEngine(library, cslSources);
  setCitationText((keys, locatorText, narrative) => engine.citation(keys, locatorText, narrative, styleOf(view.state.doc.toString())));
  lastBibliography = "";
  if (view) {
    view.dispatch({ effects: refreshCitations.of(null) });
    updateBibliography(view.state.doc.toString());
  }
  return library.size;
}

/// The next footnote label: one more than the highest number used.
function nextNote(state) {
  const { order, defined } = footnotes(state.doc.toString());
  let highest = 0;
  for (const label of [...order.keys(), ...defined.keys()]) {
    if (/^\d+$/.test(label)) highest = Math.max(highest, Number(label));
  }
  return String(highest + 1);
}

function slug(text) {
  return text.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "").slice(0, 40) || "item";
}

/// Follows a wiki link. A heading in this doc is a jump. Another doc is Swift's to find and open.
function followWiki(target, heading) {
  if (!target) {
    jumpToHeading(heading);
    return;
  }
  post({ type: "wiki", target, heading: heading || "" });
}

/// Moves to the first heading whose words match. False if there's none.
function jumpToHeading(text) {
  if (!view || typeof text !== "string" || !text.trim()) return false;
  const wanted = titleKey(text);
  const heading = outline(view.state.doc).find((h) => titleKey(h.text) === wanted);
  if (!heading) return false;
  return tools.jump(heading.from);
}

function useDocs(titles) {
  setWikiDocs(docSet(titles), followWiki);
  if (view) view.dispatch({ effects: refreshCitations.of(null) });
}

function scheduleCounts() {
  clearTimeout(countTimer);
  countTimer = setTimeout(sendCounts, COUNT_PAUSE);
}

function applySettings() {
  document.documentElement.classList.toggle("tl-serif", Boolean(settings.serif));
  document.documentElement.classList.toggle("tl-typewriter", Boolean(settings.typewriter));
  if (!view) return;
  view.dispatch({
    effects: [
      focusing.reconfigure(settings.focus ? focusMode : []),
      centring.reconfigure(settings.typewriter ? typewriter : []),
      punctuation.reconfigure(settings.smartPunctuation ? smartPunctuation : []),
    ],
  });
}

function sendFormat() {
  const state = JSON.stringify(formatState(view.state));
  if (state === lastState) return;
  lastState = state;
  post({ type: "format", state: JSON.parse(state) });
}

/// Mac shortcuts. On iPhone the same commands come from the bar above the keyboard.
function run(transaction) {
  if (transaction) view.dispatch(transaction);
  return true;
}

const shortcuts = [
  { key: "Mod-b", run: (v) => run(v.state.update(toggleWrap(v.state, "**"), { userEvent: "input.format" })) },
  { key: "Mod-i", run: (v) => run(v.state.update(toggleWrap(v.state, "*"), { userEvent: "input.format" })) },
  { key: "Mod-Shift-x", run: (v) => run(v.state.update(toggleWrap(v.state, "~~"), { userEvent: "input.format" })) },
  { key: "Mod-k", run: () => (post({ type: "link", url: formatState(view.state).link }), true) },
  { key: "Mod-Alt-0", run: (v) => run(setHeading(v.state, 0)) },
  { key: "Mod-Alt-1", run: (v) => run(setHeading(v.state, 1)) },
  { key: "Mod-Alt-2", run: (v) => run(setHeading(v.state, 2)) },
  { key: "Mod-Alt-3", run: (v) => run(setHeading(v.state, 3)) },
  { key: "Mod-Shift-8", run: (v) => run(toggleList(v.state, "bullet")) },
  { key: "Mod-Shift-7", run: (v) => run(toggleList(v.state, "numbered")) },
  // Find belongs to Swift's bar, which also takes Command-G for the next match.
  { key: "Mod-f", run: () => (post({ type: "find" }), true) },
  { key: "Mod-g", run: (v) => (find.findNext(v), sendMatches(), true) },
  { key: "Mod-Shift-g", run: (v) => (find.findPrevious(v), sendMatches(), true) },
];

function sendMatches() {
  post({ type: "matches", ...matches(view.state) });
}

function create(text, options) {
  const state = EditorState.create({
    doc: text,
    extensions: [
      history(),
      drawSelection(),
      EditorView.lineWrapping,
      EditorState.allowMultipleSelections.of(true),
      editable.of(EditorView.editable.of(!options.readOnly)),
      markdown({ base: markdownLanguage, extensions: [Strikethrough, Subscript, Superscript, Table, TaskList, scholarlySyntax, wikiSyntax] }),
      scholarlyIndex,
      bibliography,
      syntaxHighlighting(highlight),
      pageTheme,
      livePreview,
      folding,
      findSupport,
      focusing.of(settings.focus ? focusMode : []),
      centring.of(settings.typewriter ? typewriter : []),
      punctuation.of(settings.smartPunctuation ? smartPunctuation : []),
      placeholder(options.placeholder || ""),
      keymap.of([...shortcuts, ...markdownKeymap, ...historyKeymap, ...defaultKeymap, indentWithTab]),
      EditorView.contentAttributes.of({ "aria-label": "Doc", autocapitalize: "sentences", spellcheck: "true", autocorrect: "on" }),
      EditorView.updateListener.of((update) => {
        if (update.docChanged) {
          revision += 1;
          post({ type: "changed", revision });
          clearTimeout(sendTimer);
          sendTimer = setTimeout(sendText, SEND_PAUSE);
        }
        if (update.docChanged || update.selectionSet) {
          sendFormat();
          scheduleCounts();
        }
      }),
      EditorView.domEventHandlers({
        // A link opens with Command on the Mac. A plain click edits it, as in any editor.
        click(event, v) {
          if (!(event.metaKey || event.ctrlKey)) return false;
          const pos = v.posAtCoords({ x: event.clientX, y: event.clientY });
          if (pos == null) return false;
          const url = formatState(v.state.update({ selection: { anchor: pos } }).state).link;
          if (!url) return false;
          post({ type: "open", url });
          event.preventDefault();
          return true;
        },
        // Leaving the page is the last chance to send what was typed.
        blur() {
          if (sendTimer) sendText();
          return false;
        },
        // Files dropped on the page would otherwise be read by the browser.
        drop(event) {
          if (event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files.length) {
            event.preventDefault();
            return true;
          }
          return false;
        },
      }),
    ],
  });
  if (view) view.destroy();
  view = new EditorView({ state, parent: document.getElementById("editor") });
}

const formatting = {
  bold: (s) => s.update(toggleWrap(s, "**"), { userEvent: "input.format" }),
  italic: (s) => s.update(toggleWrap(s, "*"), { userEvent: "input.format" }),
  strike: (s) => s.update(toggleWrap(s, "~~"), { userEvent: "input.format" }),
  code: (s) => s.update(toggleWrap(s, "`"), { userEvent: "input.format" }),
  heading: (s, level) => setHeading(s, Math.max(0, Math.min(6, Number(level) || 0))),
  bullet: (s) => toggleList(s, "bullet"),
  numbered: (s) => toggleList(s, "numbered"),
  task: (s) => toggleList(s, "task"),
  quote: (s) => toggleQuote(s),
  link: (s, url) => setLink(s, typeof url === "string" ? url : ""),
};

/// Commands that act on the view and answer Swift with a result.
const tools = {
  undo: () => undo(view),
  redo: () => redo(view),
  find: (options) => {
    setFind(view, options && typeof options === "object" ? options : {});
    return matches(view.state);
  },
  findNext: () => (find.findNext(view), matches(view.state)),
  findPrevious: () => (find.findPrevious(view), matches(view.state)),
  replace: () => (find.replaceNext(view), matches(view.state)),
  replaceAll: () => (find.replaceAll(view), matches(view.state)),
  closeFind: () => find.closeSearchPanel(view),
  // Puts the keyboard away on iPhone.
  blur: () => view.contentDOM.blur(),
  jump: (pos) => {
    const at = Math.max(0, Math.min(Number(pos) || 0, view.state.doc.length));
    view.dispatch({
      effects: [...revealing(view.state, at), EditorView.scrollIntoView(at, { y: "start", yMargin: 24 })],
      selection: { anchor: at },
    });
    return true;
  },
  fold: (pos) => toggleSection(view, Number(pos) || 0),
  /// A numbered note: the marker where the cursor is, and its text at the end of the doc.
  footnote: () => {
    const state = view.state;
    const label = nextNote(state);
    const at = state.selection.main.head;
    const text = state.doc.toString();
    const lastLine = state.doc.line(state.doc.lines).text;
    const gap = text.length === 0 ? "" : /^\[\^[^\]]+\]:/.test(lastLine) ? "\n" : text.endsWith("\n") ? "\n" : "\n\n";
    const note = `${gap}[^${label}]: `;
    const marker = `[^${label}]`;
    view.dispatch({
      changes: [{ from: at, insert: marker }, { from: state.doc.length, insert: note }],
      selection: { anchor: state.doc.length + marker.length + note.length },
      scrollIntoView: true,
      userEvent: "input.footnote",
    });
    view.focus();
    return label;
  },
  /// Adds a key to the citation the cursor is in, or starts a new one.
  cite: (key) => {
    if (typeof key !== "string" || !/^[\p{L}\p{N}_][\p{L}\p{N}_:.#$%&\-+?<>~/]*$/u.test(key)) return false;
    const state = view.state;
    const at = state.selection.main.head;
    const line = state.doc.lineAt(at);
    const before = state.sliceDoc(line.from, at);
    const open = before.lastIndexOf("[");
    const close = state.sliceDoc(at, line.to).indexOf("]");
    const inside = open >= 0 && close >= 0 && /@/.test(state.sliceDoc(line.from + open, at + close)) && !before.slice(open).includes("]");
    const change = inside ? { from: at + close, insert: `; @${key}` } : { from: at, to: state.selection.main.to, insert: `[@${key}]` };
    view.dispatch({ changes: change, selection: { anchor: change.from + change.insert.length + (inside ? 1 : 0) }, userEvent: "input.cite" });
    view.focus();
    return true;
  },
  /// A cross-reference to a labelled section, figure or table.
  crossref: (id) => {
    if (typeof id !== "string" || !/^(?:sec|fig|tbl):[\p{L}\p{N}_:.\-]+$/u.test(id)) return false;
    const range = view.state.selection.main;
    const insert = `@${id}`;
    view.dispatch({ changes: { from: range.from, to: range.to, insert }, selection: { anchor: range.from + insert.length }, userEvent: "input.cite" });
    view.focus();
    return true;
  },
  /// Gives the heading or figure at a position a label, unless it has one. Returns the label.
  label: (pos) => {
    const state = view.state;
    const line = state.doc.lineAt(Math.max(0, Math.min(Number(pos) || 0, state.doc.length)));
    const existing = /\{#((?:sec|fig|tbl):[^\s}]+)/u.exec(line.text);
    if (existing) return existing[1];
    const heading = /^#{1,6}\s+(.*)$/.exec(line.text);
    const figure = /!\[([^\]]*)\]\([^)]*\)/.exec(line.text);
    if (!heading && !figure) return "";
    const kind = heading ? "sec" : "fig";
    const taken = labels(state.doc.toString());
    const base = `${kind}:${slug(heading ? heading[1] : figure[1])}`;
    let id = base;
    for (let n = 2; taken.has(id); n++) id = `${base}-${n}`;
    const at = heading ? line.to : line.from + figure.index + figure[0].length;
    view.dispatch({ changes: { from: at, insert: heading ? ` {#${id}}` : `{#${id}}` }, userEvent: "input.label" });
    return id;
  },
  library: (items) => useLibrary(items),
  /// The titles of every doc, so a link to one that doesn't exist yet reads differently.
  docs: (titles) => (useDocs(titles), true),
  /// A link to another doc where the cursor is. A selection becomes what the link reads as.
  wikilink: (title) => {
    const range = view.state.selection.main;
    const insert = wikiInsert(title, view.state.sliceDoc(range.from, range.to));
    if (!insert) return false;
    view.dispatch({ changes: { from: range.from, to: range.to, insert }, selection: { anchor: range.from + insert.length }, userEvent: "input.link" });
    view.focus();
    return true;
  },
  /// Jumps to a heading by its words, for a link that named one.
  goToHeading: (text) => jumpToHeading(text),
  style: (name) => {
    if (!Object.prototype.hasOwnProperty.call(styles, name)) return false;
    view.dispatch({ changes: styleChange(view.state.doc.toString(), name), userEvent: "input.style" });
    return true;
  },
  settings: (next) => {
    if (next && typeof next === "object") {
      for (const key of Object.keys(settings)) {
        if (key in next) settings[key] = Boolean(next[key]);
      }
    }
    applySettings();
    return settings;
  },
};

window.totality = Object.freeze({
  /// Replaces the page's doc. `revision` restarts, because Swift only compares within one load.
  load(text, options) {
    revision = 0;
    lastState = "";
    lastOutline = "";
    create(typeof text === "string" ? text : "", options || {});
    tools.settings(options && options.settings);
    useDocs(options && options.docs);
    useLibrary(options && options.library);
    sendFormat();
    sendCounts();
  },
  /// The current text, for a save that can't wait for the next pause.
  text() {
    if (sendTimer) clearTimeout(sendTimer);
    sendTimer = null;
    return { revision, text: view ? view.state.doc.toString() : "" };
  },
  command(name, argument) {
    if (!view) return false;
    if (Object.prototype.hasOwnProperty.call(tools, name)) {
      const result = tools[name](argument);
      if (name === "undo" || name === "redo") view.focus();
      return result === undefined ? true : result;
    }
    if (!Object.prototype.hasOwnProperty.call(formatting, name)) return false;
    const transaction = formatting[name](view.state, argument);
    if (transaction) view.dispatch(transaction);
    view.focus();
    return true;
  },
  setEditable(isEditable) {
    if (view) view.dispatch({ effects: editable.reconfigure(EditorView.editable.of(Boolean(isEditable))) });
  },
  focus() {
    if (view) view.focus();
  },
});

post({ type: "ready" });
