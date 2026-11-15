// Read along on a book's own pages. This runs in a content world of its own, which the book can't see or
// reach, and the book's own scripts don't run at all. It sets the pages out, marks the sentence Listen
// is speaking, turns to it, and tells Swift which sentence a tap landed on. It changes no text: the
// marks are the browser's highlights, drawn over the page.
import { align, pageText, locate, skippedTags } from "./bookAlign.js";

const post = (message) => {
  try {
    window.webkit.messageHandlers.book.postMessage(message);
  } catch {
    // No handler means no Swift to tell, as in a test page.
  }
};

const state = {
  nodes: [],
  starts: [],
  map: null,
  base: 0,
  mode: "paged",
  // Set while this script scrolls, so the person's own scrolling can be told apart.
  movingUntil: 0,
  following: true,
  sentence: null,
};

const styleID = "totality-book-style";

function isSkipped(node) {
  for (let element = node.parentElement; element; element = element.parentElement) {
    if (skippedTags.has((element.localName || "").toLowerCase())) return true;
  }
  return false;
}

/// Every text node a reader would read, in order.
function textNodes() {
  const nodes = [];
  if (!document.body) return nodes;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (node.data.length && !isSkipped(node)) nodes.push(node);
  }
  return nodes;
}

function addStyle(options) {
  let style = document.getElementById(styleID);
  if (!style) {
    style = document.createElement("style");
    style.id = styleID;
    (document.head || document.documentElement).appendChild(style);
  }
  const pad = Number(options.pad) || 24;
  const scale = Math.max(0.5, Math.min(3, Number(options.scale) || 1));
  const colours = options.colours || {};
  style.textContent = `
    html { font-size: ${scale * 100}% !important; background: ${colours.bg || "#fff"}; }
    html.tl-paged { height: 100vh; overflow: hidden; }
    html.tl-paged body { box-sizing: border-box; height: 100vh; margin: 0; padding: ${pad}px ${pad}px;
      column-width: calc(100vw - ${pad * 2}px); column-gap: ${pad * 2}px; column-fill: auto; }
    html.tl-scroll body { box-sizing: border-box; max-width: 42em; margin: 0 auto; padding: ${pad}px; }
    img, svg, video { max-width: 100%; height: auto; }
    html.tl-paged img, html.tl-paged svg { max-height: calc(100vh - ${pad * 2}px); object-fit: contain; break-inside: avoid; }
    ::highlight(tl-sentence) { background-color: ${colours.highlight || "#e8eefc"}; }
    ::highlight(tl-word) { background-color: ${colours.highlightStrong || "#c9d8fa"}; }
  `;
}

function scroller() {
  return document.scrollingElement || document.documentElement;
}

function pageWidth() {
  return window.innerWidth || 1;
}

function pageInfo() {
  if (state.mode !== "paged") {
    const height = window.innerHeight || 1;
    const pages = Math.max(1, Math.ceil(scroller().scrollHeight / height));
    return { page: Math.min(pages, Math.floor(scroller().scrollTop / height) + 1), pages };
  }
  const pages = Math.max(1, Math.round(scroller().scrollWidth / pageWidth()));
  return { page: Math.min(pages, Math.round(scroller().scrollLeft / pageWidth()) + 1), pages };
}

function moveTo(left, top) {
  state.movingUntil = Date.now() + 400;
  scroller().scrollTo({ left, top, behavior: "instant" });
  post({ type: "page", ...pageInfo() });
}

/// Turns `by` pages. Returns false at either end, so Swift can go to the next chapter.
function turn(by) {
  const { page, pages } = pageInfo();
  const next = page + by;
  if (next < 1 || next > pages) return false;
  if (state.mode === "paged") moveTo((next - 1) * pageWidth(), 0);
  else moveTo(0, (next - 1) * (window.innerHeight || 1));
  return true;
}

function domRange(start, end) {
  if (!state.map) return null;
  const found = state.map.pageRange(start - state.base, end - state.base);
  if (!found) return null;
  const a = locate(state.starts, found[0]);
  const b = locate(state.starts, found[1] - 1);
  const range = document.createRange();
  range.setStart(state.nodes[a.piece], a.offset);
  range.setEnd(state.nodes[b.piece], b.offset + 1);
  return range;
}

function isShowing(rect) {
  return rect.right > 0 && rect.left < pageWidth() && rect.bottom > 0 && rect.top < (window.innerHeight || 1);
}

function follow(range) {
  const rect = range.getClientRects()[0] || range.getBoundingClientRect();
  if (!rect || isShowing(rect)) return;
  if (state.mode === "paged") {
    const left = scroller().scrollLeft + rect.left;
    moveTo(Math.floor(left / pageWidth()) * pageWidth(), 0);
  } else {
    moveTo(0, Math.max(0, scroller().scrollTop + rect.top - (window.innerHeight || 0) / 3));
  }
}

const hasHighlights = () => typeof CSS !== "undefined" && CSS.highlights && typeof Highlight === "function";

function mark(sentence, word) {
  if (!hasHighlights()) return;
  CSS.highlights.delete("tl-sentence");
  CSS.highlights.delete("tl-word");
  if (sentence) CSS.highlights.set("tl-sentence", new Highlight(sentence));
  if (word) CSS.highlights.set("tl-word", new Highlight(word));
}

function swipe() {
  let start = null;
  addEventListener("touchstart", (event) => {
    if (state.mode !== "paged" || event.touches.length !== 1) return;
    start = { x: event.touches[0].clientX, y: event.touches[0].clientY, time: Date.now() };
  }, { passive: true });
  addEventListener("touchend", (event) => {
    if (!start || state.mode !== "paged") return;
    const touch = event.changedTouches[0];
    const dx = touch.clientX - start.x;
    const dy = touch.clientY - start.y;
    start = null;
    if (Math.abs(dx) < 40 || Math.abs(dx) < Math.abs(dy)) return;
    userMoved();
    const by = dx < 0 ? 1 : -1;
    if (!turn(by)) post({ type: "edge", direction: by > 0 ? "next" : "previous" });
  }, { passive: true });
  addEventListener("keydown", (event) => {
    const by = { ArrowRight: 1, ArrowLeft: -1, PageDown: 1, PageUp: -1, " ": 1 }[event.key];
    if (!by || state.mode !== "paged") return;
    event.preventDefault();
    userMoved();
    if (!turn(by)) post({ type: "edge", direction: by > 0 ? "next" : "previous" });
  });
}

function userMoved() {
  if (state.following) {
    state.following = false;
    post({ type: "scrolled" });
  }
}

/// A tap on words moves Listen there. A tap on a link is the link's.
function taps() {
  addEventListener("click", (event) => {
    if (!state.map || event.target.closest?.("a[href]")) return;
    const caret = document.caretRangeFromPoint?.(event.clientX, event.clientY);
    if (!caret || caret.startContainer.nodeType !== Node.TEXT_NODE) return;
    const piece = state.nodes.indexOf(caret.startContainer);
    if (piece === -1) return;
    const offset = state.map.listenOffset(state.starts[piece] + caret.startOffset);
    if (offset !== null) post({ type: "tap", offset: offset + state.base });
  });
  addEventListener("scroll", () => {
    if (Date.now() > state.movingUntil) {
      userMoved();
      post({ type: "page", ...pageInfo() });
    }
  }, { passive: true });
  addEventListener("resize", () => {
    if (state.mode === "paged") {
      const { page } = pageInfo();
      moveTo((page - 1) * pageWidth(), 0);
    }
  });
}

window.totalityBook = {
  /// Sets the page out and reads its text. `listen` is Listen's text for this chapter, which starts at
  /// `base` in the whole book's text. `progress`, from 0 to 1, is how far through the chapter to open.
  setup(options) {
    state.mode = options.mode === "scroll" ? "scroll" : "paged";
    document.documentElement.classList.toggle("tl-paged", state.mode === "paged");
    document.documentElement.classList.toggle("tl-scroll", state.mode === "scroll");
    addStyle(options);
    state.nodes = textNodes();
    const joined = pageText(state.nodes.map((node) => node.data));
    state.starts = joined.starts;
    state.base = Number(options.base) || 0;
    state.map = typeof options.listen === "string" ? align(options.listen, joined.text) : null;
    if (options.atEnd) {
      const { pages } = pageInfo();
      turn(pages - 1);
    } else if (Number(options.progress) > 0) {
      // Where the person stopped, as a share of the chapter, so it lands on the same words at any size.
      const { pages } = pageInfo();
      turn(Math.round(Math.min(1, Number(options.progress)) * (pages - 1)));
    }
    return {
      textLength: joined.text.trim().length,
      scripts: document.getElementsByTagName("script").length,
      coverage: state.map ? state.map.coverage : 0,
      ...pageInfo(),
    };
  },
  mode(options) {
    return this.setup(options);
  },
  turn(by) {
    return turn(by);
  },
  /// Marks a sentence and a word, by their places in the whole book's text. Turns to them when following.
  highlight(sentenceStart, sentenceEnd, wordStart, wordEnd, following) {
    state.following = Boolean(following);
    const sentence = domRange(sentenceStart, sentenceEnd);
    const word = wordStart === null || wordStart === undefined ? null : domRange(wordStart, wordEnd);
    mark(sentence, word);
    if (sentence && state.following) follow(sentence);
    return Boolean(sentence);
  },
  clear() {
    mark(null, null);
  },
};

swipe();
taps();
post({ type: "loaded" });
