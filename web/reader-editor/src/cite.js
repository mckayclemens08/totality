// Citations and the bibliography. The person's reference library comes from Swift as CSL JSON, the
// format Zotero and Pandoc share. The style is named in the doc's front matter (`csl: apa`).
//
// citeproc.js formats with the real styles. The plain formatter here is what it falls back to when a
// key isn't in the library or a style can't be read, so a citation always shows something.
import { citationKeys, isCrossRef, keyPattern } from "./scholarly.js";

export const styles = {
  apa: { name: "APA", heading: "References" },
  mla: { name: "MLA", heading: "Works Cited" },
  chicago: { name: "Chicago", heading: "Bibliography" },
};

/// The style a doc's front matter names, or APA. Only the three bundled styles are known.
export function styleOf(text) {
  const front = /^---\n([\s\S]*?)\n(?:---|\.\.\.)\s*(?:\n|$)/.exec(text);
  if (!front) return "apa";
  const csl = /^csl:\s*["']?([\w.-]+?)(?:\.csl)?["']?\s*$/m.exec(front[1]);
  const name = csl ? csl[1].toLowerCase().replace(/-.*$/, "") : "apa";
  return Object.prototype.hasOwnProperty.call(styles, name) ? name : "apa";
}

/// Sets `csl:` in the front matter, adding front matter if there's none. Returns the change to make.
export function styleChange(text, style) {
  const front = /^---\n([\s\S]*?)\n(---|\.\.\.)(\s*(?:\n|$))/.exec(text);
  if (!front) return { from: 0, to: 0, insert: `---\ncsl: ${style}\n---\n\n` };
  const body = front[1];
  const line = /^csl:.*$/m.exec(body);
  if (line) {
    const from = 4 + line.index;
    return { from, to: from + line[0].length, insert: `csl: ${style}` };
  }
  return { from: 4, to: 4, insert: `csl: ${style}\n` };
}

/// Every key cited in the doc, in order of first citation, leaving out cross-references.
export function citedKeys(text) {
  const keys = [];
  const seen = new Set();
  const pattern = new RegExp(`\\[[^\\[\\]\\n]*?-?@${keyPattern.source}[^\\[\\]\\n]*\\](?![(\\[])|(?<![\\p{L}\\p{N}])@${keyPattern.source}`, "gu");
  let fence = false;
  for (const line of text.split("\n")) {
    if (/^\s{0,3}(```|~~~)/.test(line)) fence = !fence;
    if (fence) continue;
    for (const match of line.matchAll(pattern)) {
      const found = match[0].startsWith("[") ? citationKeys(match[0]) : [{ key: match[0].slice(1) }];
      for (const { key } of found) {
        if (!isCrossRef(key) && !seen.has(key)) {
          seen.add(key);
          keys.push(key);
        }
      }
    }
  }
  return keys;
}

function year(item) {
  const parts = item.issued && item.issued["date-parts"];
  return (parts && parts[0] && parts[0][0]) || "n.d.";
}

function names(item) {
  return (item.author || item.editor || []).map((person) => ({
    family: person.family || person.literal || "",
    given: person.given || "",
  }));
}

/// APA joins two authors with "&" inside parentheses and "and" in running text.
function authorShort(item, style, narrative = false) {
  const people = names(item);
  if (!people.length) return item.title || item.id;
  if (people.length === 1) return people[0].family;
  if (people.length === 2) return `${people[0].family} ${style === "apa" && !narrative ? "&" : "and"} ${people[1].family}`;
  return `${people[0].family} et al.`;
}

function initials(given) {
  return given.split(/[\s-]+/).filter(Boolean).map((part) => `${part[0]}.`).join(" ");
}

/// One bibliography entry as plain text, in a simple form of the style.
export function entry(item, style) {
  const people = names(item);
  const title = item.title || "";
  const container = item["container-title"] || "";
  const publisher = item.publisher || "";
  const volume = item.volume ? `${item.volume}${item.issue ? `(${item.issue})` : ""}` : "";
  const page = String(item.page || "").replace(/(\d)\s*-{1,2}\s*(\d)/g, "$1\u2013$2");
  const doi = item.DOI ? `https://doi.org/${item.DOI}` : item.URL || "";
  // A part that already ends a sentence doesn't get a second full stop.
  const join = (parts, separator = ". ") =>
    parts.filter(Boolean).reduce((text, part) => {
      if (!text) return String(part);
      const ends = separator === ". " && /[.?!]["\u201D]?$/.test(text);
      return text + (ends ? " " : separator) + part;
    }, "");
  const close = (text) => (/[.?!]["\u201D]?$/.test(text) ? text : `${text}.`);
  if (style === "mla") {
    const author = people.length
      ? people.length === 1
        ? `${people[0].family}, ${people[0].given}`
        : people.length === 2
          ? `${people[0].family}, ${people[0].given}, and ${people[1].given} ${people[1].family}`
          : `${people[0].family}, ${people[0].given}, et al`
      : "";
    const titled = container ? `“${title}.”` : title;
    const issueText = item.volume ? `vol. ${item.volume}${item.issue ? `, no. ${item.issue}` : ""}` : "";
    return close(join([author, titled, join([container, issueText, publisher, year(item), page && `pp. ${page}`], ", "), doi]));
  }
  if (style === "chicago") {
    const author = people.length
      ? people.map((p, i) => (i === 0 ? `${p.family}, ${p.given}` : `${p.given} ${p.family}`)).join(people.length > 2 ? ", " : " and ")
      : "";
    const titled = container ? `“${title}.”` : title;
    const where = [item.volume, item.issue && `no. ${item.issue}`].filter(Boolean).join(", ");
    return close(join([author, year(item), titled, join([container, [where, page].filter(Boolean).join(": ")], " "), publisher, doi]));
  }
  const author = people.length
    ? people.map((p) => `${p.family}, ${initials(p.given)}`).join(people.length > 2 ? ", " : " & ")
    : "";
  // APA ends an entry with its DOI or address, which takes no full stop.
  const body = close(join([author, `(${year(item)})`, title, close(join([container, volume, page], ", ")).replace(/^\.$/, ""), publisher]));
  return doi ? `${body} ${doi}` : body;
}

/// The stand-in engine: "(Smith & Jones, 2020, p. 4)" for APA, "(Smith 4)" for MLA, and Chicago's
/// author-date "(Smith 2020, 4)".
export function plainEngine(library) {
  return {
    citation(keys, locatorText, narrative, style) {
      const parts = keys.map(({ key, suppressAuthor }) => {
        const item = library.get(key);
        if (!item) return { author: `?${key}`, year: "" };
        return { author: suppressAuthor ? "" : authorShort(item, style, narrative && keys.length === 1), year: String(year(item)) };
      });
      const where = locatorText ? (style === "apa" ? `, ${locatorText}` : ` ${locatorText.replace(/^(?:p|pp)\.\s*/, "")}`) : "";
      if (narrative && parts.length === 1) {
        const [{ author, year: when }] = parts;
        return style === "mla" ? author : `${author} (${when}${where.replace(/^ /, ", ")})`;
      }
      const inner = parts
        .map(({ author, year: when }) => {
          if (style === "mla") return author;
          if (!author) return when;
          if (!when) return author;
          return style === "apa" ? `${author}, ${when}` : `${author} ${when}`;
        })
        .join("; ");
      return `(${inner}${where})`;
    },
    bibliography(keys, style) {
      const entries = keys.filter((key) => library.has(key)).map((key) => entry(library.get(key), style));
      return entries.sort((a, b) => a.localeCompare(b));
    },
  };
}

/// Only plain CSL fields cross into the page's library: strings, numbers, names and dates.
export function cleanItems(items) {
  const library = new Map();
  if (!Array.isArray(items)) return library;
  for (const item of items.slice(0, 20000)) {
    if (!item || typeof item.id !== "string" || !item.id) continue;
    if (!library.has(item.id)) library.set(item.id, item);
  }
  return library;
}
