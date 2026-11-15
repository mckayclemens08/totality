import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { ensureSyntaxTree } from "@codemirror/language";
import { scholarlySyntax, citationKeys, isCrossRef, footnotes, labels, crossRefText, locator } from "../src/scholarly.js";
import { styleOf, styleChange, citedKeys, plainEngine, cleanItems, entry } from "../src/cite.js";

const thesis = `---
title: Teacher retention in rural districts
csl: chicago
---

# Introduction {#sec:intro}

Rural districts lose teachers faster than cities do.[^1] @ingersoll2001 calls this a
revolving door, and later work agrees [see @ingersoll2001, p. 499; -@ladd2011].

![Turnover by district type](turnover.png){#fig:turnover}

As @fig:turnover shows, and as [@sec:intro] argued, the gap is widening. Write to me@example.com.

[^1]: National Center for Education Statistics, 2023.`;

const library = [
  { id: "ingersoll2001", type: "article-journal", title: "Teacher Turnover and Teacher Shortages: An Organizational Analysis",
    author: [{ family: "Ingersoll", given: "Richard M." }], "container-title": "American Educational Research Journal",
    volume: "38", issue: "3", page: "499-534", issued: { "date-parts": [[2001]] }, DOI: "10.3102/00028312038003499" },
  { id: "ladd2011", type: "article-journal", title: "Teachers' Perceptions of Their Working Conditions",
    author: [{ family: "Ladd", given: "Helen F." }], "container-title": "Educational Evaluation and Policy Analysis",
    issued: { "date-parts": [[2011]] } },
];

function nodes(text) {
  const state = EditorState.create({ doc: text, extensions: [markdown({ base: markdownLanguage, extensions: [scholarlySyntax] })] });
  // The full tree comes back from ensureSyntaxTree. The state's own may stop where its first, timed parse did.
  const tree = ensureSyntaxTree(state, state.doc.length, 5000);
  const found = [];
  tree.iterate({ enter(node) {
    if (["FrontMatter", "FootnoteRef", "Citation", "NarrativeCitation", "Attribute", "InlineNote"].includes(node.name)) {
      found.push([node.name, text.slice(node.from, node.to)]);
    }
  } });
  return found;
}

test("the parser finds front matter, notes, citations, cross-references and labels", () => {
  const found = nodes(thesis);
  assert.equal(found[0][0], "FrontMatter");
  assert.ok(found[0][1].endsWith("csl: chicago\n---"));
  assert.deepEqual(found.filter(([name]) => name !== "FrontMatter"), [
    ["Attribute", "{#sec:intro}"],
    ["FootnoteRef", "[^1]"],
    ["NarrativeCitation", "@ingersoll2001"],
    ["Citation", "[see @ingersoll2001, p. 499; -@ladd2011]"],
    ["Attribute", "{#fig:turnover}"],
    ["NarrativeCitation", "@fig:turnover"],
    ["Citation", "[@sec:intro]"],
    ["FootnoteRef", "[^1]"],
  ]);
});

test("a link and an email address aren't citations", () => {
  assert.deepEqual(nodes("A [link](https://a.org) and me@example.com and [plain words]."), []);
});

test("citation keys keep their suppression, and punctuation after a key isn't part of it", () => {
  assert.deepEqual(citationKeys("[see @ingersoll2001, p. 499; -@ladd2011]"), [
    { key: "ingersoll2001", suppressAuthor: false },
    { key: "ladd2011", suppressAuthor: true },
  ]);
  assert.equal(locator("[see @ingersoll2001, p. 499]"), "p. 499");
  assert.ok(isCrossRef("fig:turnover"));
  assert.ok(!isCrossRef("ingersoll2001"));
});

test("footnotes number in the order they're first referred to", () => {
  const notes = footnotes("Second[^b] first[^a] again[^b]\n\n[^a]: A.\n[^b]: B.");
  assert.deepEqual([...notes.order.entries()], [["b", 1], ["a", 2]]);
  assert.deepEqual([...notes.defined.keys()], ["a", "b"]);
});

test("labels number within their kind, and a section reads by its heading", () => {
  const found = labels(thesis);
  assert.deepEqual([...found.keys()], ["sec:intro", "fig:turnover"]);
  assert.equal(crossRefText("fig:turnover", found), "Figure 1");
  assert.equal(crossRefText("sec:intro", found), "“Introduction”");
  assert.equal(crossRefText("fig:missing", found), "??fig:missing");
});

test("the style comes from front matter, and changing it edits only that line", () => {
  assert.equal(styleOf(thesis), "chicago");
  assert.equal(styleOf("No front matter"), "apa");
  assert.equal(styleOf("---\ncsl: modern-language-association\n---\n"), "apa");
  assert.equal(styleOf("---\ncsl: mla.csl\n---\n"), "mla");
  const change = styleChange(thesis, "mla");
  const changed = thesis.slice(0, change.from) + change.insert + thesis.slice(change.to);
  assert.ok(changed.startsWith("---\ntitle: Teacher retention in rural districts\ncsl: mla\n---"));
  assert.deepEqual(styleChange("Just text", "apa"), { from: 0, to: 0, insert: "---\ncsl: apa\n---\n\n" });
});

test("cited keys come in order, once each, without cross-references or emails", () => {
  assert.deepEqual(citedKeys(thesis), ["ingersoll2001", "ladd2011"]);
});

test("the plain engine writes in-text citations for each style", () => {
  const engine = plainEngine(cleanItems(library));
  const keys = [{ key: "ingersoll2001", suppressAuthor: false }];
  assert.equal(engine.citation(keys, "p. 499", false, "apa"), "(Ingersoll, 2001, p. 499)");
  assert.equal(engine.citation(keys, "p. 499", false, "mla"), "(Ingersoll 499)");
  assert.equal(engine.citation(keys, "p. 499", false, "chicago"), "(Ingersoll 2001 499)");
  assert.equal(engine.citation(keys, "", true, "apa"), "Ingersoll (2001)");
  assert.equal(engine.citation([{ key: "ladd2011", suppressAuthor: true }], "", false, "apa"), "(2011)");
  assert.equal(engine.citation([{ key: "nobody", suppressAuthor: false }], "", false, "apa"), "(?nobody)");
});

test("bibliography entries are plain text in each style, sorted", () => {
  const engine = plainEngine(cleanItems(library));
  const apa = engine.bibliography(["ladd2011", "ingersoll2001", "missing"], "apa");
  assert.equal(apa.length, 2);
  assert.ok(apa[0].startsWith("Ingersoll, R. M. (2001). Teacher Turnover"));
  assert.ok(apa[0].includes("https://doi.org/10.3102/00028312038003499"));
  assert.ok(entry(library[0], "mla").startsWith("Ingersoll, Richard M. “Teacher Turnover"));
  assert.ok(entry(library[0], "chicago").startsWith("Ingersoll, Richard M. 2001."));
});

test("a library keeps only items with an id, first one winning", () => {
  const items = cleanItems([{ id: "a", title: "One" }, { id: "a", title: "Two" }, { title: "No id" }, null, { id: 5 }]);
  assert.deepEqual([...items.keys()], ["a"]);
  assert.equal(items.get("a").title, "One");
  assert.equal(cleanItems("not a list").size, 0);
});
