// The Reader's writing page. Swift owns everything outside the text: it loads a doc in with `load`,
// and runs commands with `command`. This page tells Swift only three things through its one message
// handler: that it's ready, that the text changed (with the text), and that a link was asked for.
// It never fetches, stores, or opens anything itself.
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, drawSelection, placeholder } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage, markdownKeymap } from "@codemirror/lang-markdown";
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { tags } from "@lezer/highlight";
import { Strikethrough, Subscript, Superscript, Table, TaskList } from "@lezer/markdown";
import { livePreview } from "./livePreview.js";
import { toggleWrap, setHeading, toggleList, toggleQuote, setLink, formatState } from "./commands.js";

/// How long typing has to pause before the text goes to Swift. Swift saves shortly after that.
const SEND_PAUSE = 250;

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
let view;
let revision = 0;
let sendTimer = null;
let lastState = "";

function sendText() {
  clearTimeout(sendTimer);
  sendTimer = null;
  post({ type: "text", revision, text: view.state.doc.toString() });
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
];

function create(text, options) {
  const state = EditorState.create({
    doc: text,
    extensions: [
      history(),
      drawSelection(),
      EditorView.lineWrapping,
      EditorState.allowMultipleSelections.of(true),
      editable.of(EditorView.editable.of(!options.readOnly)),
      markdown({ base: markdownLanguage, extensions: [Strikethrough, Subscript, Superscript, Table, TaskList] }),
      syntaxHighlighting(highlight),
      pageTheme,
      livePreview,
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
        if (update.docChanged || update.selectionSet) sendFormat();
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

window.totality = Object.freeze({
  /// Replaces the page's doc. `revision` restarts, because Swift only compares within one load.
  load(text, options) {
    revision = 0;
    lastState = "";
    create(typeof text === "string" ? text : "", options || {});
    document.documentElement.classList.toggle("tl-serif", Boolean(options && options.serif));
    sendFormat();
  },
  /// The current text, for a save that can't wait for the next pause.
  text() {
    if (sendTimer) clearTimeout(sendTimer);
    sendTimer = null;
    return { revision, text: view ? view.state.doc.toString() : "" };
  },
  command(name, argument) {
    if (!view || !Object.prototype.hasOwnProperty.call(formatting, name)) return false;
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
