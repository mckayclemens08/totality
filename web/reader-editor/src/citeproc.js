/*!
 * citeproc-js, copyright (c) 2009-2019 Frank Bennett, used unmodified under the Common Public
 * Attribution License 1.0 (https://opensource.org/license/cpal_1-0). Source: https://github.com/Juris-M/citeproc-js
 * Citation styles and locale from the Citation Style Language project, CC BY-SA 3.0.
 */
// The style engine: citeproc-js, used unmodified under the CPAL, with the CSL project's APA, MLA and
// Chicago author-date styles and its en-US locale (CC BY-SA 3.0). The style files sit in ../csl,
// pinned to a commit there. Output is plain text, never markup, so nothing it makes can run.
import CSL from "citeproc";
import { plainEngine } from "./cite.js";

const files = { apa: "apa", mla: "modern-language-association", chicago: "chicago-author-date" };

/// Pandoc's locator words, as CSL labels: "p. 4" is page 4, "ch. 2" is chapter 2.
const labels = [
  [/^(?:pp?\.?|pages?)\s*/i, "page"],
  [/^(?:ch\.?|chaps?\.?|chapters?)\s*/i, "chapter"],
  [/^(?:sec\.?|secs\.?|sections?|§)\s*/i, "section"],
  [/^(?:para\.?|paras\.?|paragraphs?|¶)\s*/i, "paragraph"],
  [/^(?:fig\.?|figs\.?|figures?)\s*/i, "figure"],
  [/^(?:vol\.?|vols\.?|volumes?)\s*/i, "volume"],
  [/^(?:l\.|ll\.|lines?)\s*/i, "line"],
];

export function cslLocator(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return {};
  for (const [pattern, label] of labels) {
    if (pattern.test(trimmed)) return { locator: trimmed.replace(pattern, ""), label };
  }
  // A bare number is a page, as in Pandoc.
  if (/^[\d–\-–, ]+$/.test(trimmed)) return { locator: trimmed, label: "page" };
  return { suffix: `, ${trimmed}` };
}

/// `sources` holds the style files' text by short name, and the locale's text.
export function citeprocEngine(library, sources) {
  const fallback = plainEngine(library);
  const engines = new Map();
  const sys = { retrieveLocale: () => sources.locale, retrieveItem: (id) => library.get(id) };
  function engineFor(style) {
    if (!engines.has(style)) {
      let made = null;
      try {
        made = new CSL.Engine(sys, sources.styles[style]);
        made.setOutputFormat("text");
      } catch {
        made = null;
      }
      engines.set(style, made);
    }
    return engines.get(style);
  }
  const clean = (text) => String(text).replace(/\s+$/, "");
  return {
    citation(keys, locatorText, narrative, style) {
      const known = keys.filter(({ key }) => library.has(key));
      const engine = engineFor(style);
      if (!engine || known.length !== keys.length) return fallback.citation(keys, locatorText, narrative, style);
      try {
        engine.updateItems(known.map(({ key }) => key));
        const where = cslLocator(locatorText);
        const items = known.map(({ key, suppressAuthor }, index) => ({
          id: key,
          ...(suppressAuthor ? { "suppress-author": true } : {}),
          ...(index === known.length - 1 ? where : {}),
        }));
        if (narrative && items.length === 1) {
          const author = clean(engine.makeCitationCluster([{ id: items[0].id, "author-only": true }]));
          if (style === "mla") return author;
          return `${author} ${clean(engine.makeCitationCluster([{ ...items[0], "suppress-author": true }]))}`;
        }
        return clean(engine.makeCitationCluster(items));
      } catch {
        return fallback.citation(keys, locatorText, narrative, style);
      }
    },
    bibliography(keys, style) {
      const known = keys.filter((key) => library.has(key));
      const engine = engineFor(style);
      if (!engine) return fallback.bibliography(keys, style);
      if (!known.length) return [];
      try {
        engine.updateItems(known);
        const made = engine.makeBibliography();
        return made ? made[1].map(clean) : [];
      } catch {
        return fallback.bibliography(keys, style);
      }
    },
  };
}

export { files as styleFiles };
