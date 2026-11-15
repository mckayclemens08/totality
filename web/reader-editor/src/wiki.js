// Links between Reader docs, as in Obsidian, in the form Pandoc reads with its
// `wikilinks_title_after_pipe` extension:
//   [[The Tragic Hero in Macbeth]]            a doc, by its title
//   [[The Tragic Hero in Macbeth|the essay]]  the same doc, read as "the essay"
//   [[The Tragic Hero in Macbeth#The letter]] a heading inside it
//   [[#The letter]]                           a heading in this doc
// A link names a title, never an ID, so the text stays plain and portable. Swift says which titles
// exist, and finds the doc when a link is opened. Nothing here reaches outside the page.
import { WidgetType } from "@codemirror/view";

/// What a title can't contain, because the link's own punctuation would break.
const forbidden = /[\[\]|#\n]/;
export const maxTitle = 200;
export const maxDocs = 5000;

const pattern = /^\[\[([^\[\]|#\n]*)(?:#([^\[\]|\n]*))?(?:\|([^\[\]\n]*))?\]\]/;

/// The parts of a wiki link at the start of `text`, or null.
export function parseWiki(text) {
  const found = pattern.exec(text);
  if (!found) return null;
  const target = found[1].trim();
  const heading = (found[2] || "").trim();
  const alias = (found[3] || "").trim();
  if (!target && !heading) return null;
  if (target.length > maxTitle || heading.length > maxTitle) return null;
  return { length: found[0].length, target, heading, alias };
}

/// How a link reads on the page.
export function wikiText({ target, heading, alias }) {
  if (alias) return alias;
  if (!target) return heading;
  return heading ? `${target} › ${heading}` : target;
}

/// Titles match whatever their case or spacing, so `[[macbeth  essay]]` finds "Macbeth essay".
export function titleKey(title) {
  return String(title).normalize("NFKC").trim().replace(/\s+/g, " ").toLowerCase();
}

/// Whether a title can go inside `[[ ]]` as it is.
export function linkable(title) {
  return typeof title === "string" && title.trim().length > 0 && title.length <= maxTitle && !forbidden.test(title);
}

/// The text a link to `title` inserts. A selection becomes what the link reads as.
export function wikiInsert(title, selected) {
  if (!linkable(title)) return null;
  const shown = typeof selected === "string" ? selected.replace(/[\[\]|\n]/g, " ").trim() : "";
  return shown && titleKey(shown) !== titleKey(title) ? `[[${title.trim()}|${shown}]]` : `[[${title.trim()}]]`;
}

/// The titles Swift says exist, kept as match keys. Anything that isn't a short string is dropped.
export function docSet(titles) {
  const set = new Set();
  if (!Array.isArray(titles)) return set;
  for (const title of titles.slice(0, maxDocs)) {
    if (typeof title === "string" && title.length <= maxTitle) set.add(titleKey(title));
  }
  return set;
}

export const wikiSyntax = {
  defineNodes: ["WikiLink"],
  parseInline: [
    {
      name: "WikiLink",
      before: "Link",
      parse(cx, next, pos) {
        if (next !== 91 /* [ */ || cx.char(pos + 1) !== 91) return -1;
        const found = parseWiki(cx.slice(pos, cx.end));
        return found ? cx.addElement(cx.elt("WikiLink", pos, pos + found.length)) : -1;
      },
    },
  ],
};

/// A link as it reads when its line isn't being edited. Tapping it follows it, so it never moves the
/// cursor: to change the link, put the cursor on its line and the text shows.
export class WikiWidget extends WidgetType {
  constructor(link, exists, follow) {
    super();
    this.link = link;
    this.exists = exists;
    this.follow = follow;
  }
  eq(other) {
    return other.exists === this.exists && other.link.target === this.link.target &&
      other.link.heading === this.link.heading && other.link.alias === this.link.alias;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = this.exists ? "cm-tl-wiki" : "cm-tl-wiki cm-tl-wiki-missing";
    span.setAttribute("role", "link");
    span.textContent = wikiText(this.link);
    const { target, heading } = this.link;
    // A press would otherwise focus the editor and bring up the keyboard first.
    span.addEventListener("mousedown", (event) => event.preventDefault());
    span.addEventListener("click", (event) => {
      event.preventDefault();
      this.follow(target, heading);
    });
    return span;
  }
  ignoreEvent() {
    return true;
  }
}
