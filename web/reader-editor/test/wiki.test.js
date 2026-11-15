import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { ensureSyntaxTree } from "@codemirror/language";
import { parseWiki, wikiText, titleKey, linkable, wikiInsert, docSet, wikiSyntax, maxDocs } from "../src/wiki.js";
import { scholarlySyntax } from "../src/scholarly.js";
import { countWords } from "../src/tools.js";

const notes = `# Act one

Lady Macbeth's reading of the letter is covered in [[The Tragic Hero in Macbeth#The letter]], and the
prophecy in [[Witches and prophecy|the witches' scene]]. See also [[#Act two]] below, and the
[open questions](https://example.org/macbeth) list [@bradley1904, p. 12].

[[Not written yet]]

\`\`\`
[[inside a code block]]
\`\`\`

# Act two`;

function wikiNodes(text) {
  const state = EditorState.create({
    doc: text,
    extensions: [markdown({ base: markdownLanguage, extensions: [scholarlySyntax, wikiSyntax] })],
  });
  const tree = ensureSyntaxTree(state, state.doc.length, 5000);
  const found = [];
  tree.iterate({ enter(node) {
    if (node.name === "WikiLink") found.push(state.sliceDoc(node.from, node.to));
    if (node.name === "Link") found.push(`link:${state.sliceDoc(node.from, node.to)}`);
    if (node.name === "Citation") found.push(`cite:${state.sliceDoc(node.from, node.to)}`);
  } });
  return found;
}

test("a wiki link names a doc, and can name a heading and the words it reads as", () => {
  assert.deepEqual(parseWiki("[[The Tragic Hero in Macbeth]] and on"),
    { length: 30, target: "The Tragic Hero in Macbeth", heading: "", alias: "" });
  assert.deepEqual(parseWiki("[[The Tragic Hero in Macbeth#The letter|the letter scene]]"),
    { length: 58, target: "The Tragic Hero in Macbeth", heading: "The letter", alias: "the letter scene" });
  assert.deepEqual(parseWiki("[[#Act two]]"), { length: 12, target: "", heading: "Act two", alias: "" });
});

test("broken or empty brackets aren't links", () => {
  assert.equal(parseWiki("[[]]"), null);
  assert.equal(parseWiki("[[ | words]]"), null);
  assert.equal(parseWiki("[[Unclosed"), null);
  assert.equal(parseWiki("[[Two\nlines]]"), null);
  assert.equal(parseWiki("[[a[b]]"), null);
  assert.equal(parseWiki(`[[${"x".repeat(201)}]]`), null);
});

test("a link reads as its words, its title, or its title and heading", () => {
  assert.equal(wikiText(parseWiki("[[Witches and prophecy|the witches' scene]]")), "the witches' scene");
  assert.equal(wikiText(parseWiki("[[Witches and prophecy]]")), "Witches and prophecy");
  assert.equal(wikiText(parseWiki("[[Witches and prophecy#Act one]]")), "Witches and prophecy › Act one");
  assert.equal(wikiText(parseWiki("[[#Act two]]")), "Act two");
});

test("the parser finds wiki links beside ordinary links and citations, and not in code", () => {
  assert.deepEqual(wikiNodes(notes), [
    "[[The Tragic Hero in Macbeth#The letter]]",
    "[[Witches and prophecy|the witches' scene]]",
    "[[#Act two]]",
    "link:[open questions](https://example.org/macbeth)",
    "cite:[@bradley1904, p. 12]",
    "[[Not written yet]]",
  ]);
});

test("titles match whatever their case and spacing", () => {
  assert.equal(titleKey("  The Tragic  Hero in MACBETH "), titleKey("The Tragic Hero in Macbeth"));
  assert.notEqual(titleKey("Macbeth"), titleKey("Macbeth notes"));
  const docs = docSet(["The Tragic Hero in Macbeth", "Witches and prophecy", 42, null, "x".repeat(201)]);
  assert.equal(docs.size, 2);
  assert.ok(docs.has(titleKey("witches and prophecy")));
});

test("the doc list is capped and anything that isn't a list is no docs", () => {
  assert.equal(docSet("The Tragic Hero in Macbeth").size, 0);
  assert.equal(docSet({ 0: "a" }).size, 0);
  const many = Array.from({ length: maxDocs + 10 }, (_, n) => `Chapter ${n}`);
  assert.equal(docSet(many).size, maxDocs);
});

test("inserting a link uses the title, and a selection becomes its words", () => {
  assert.equal(wikiInsert("Witches and prophecy", ""), "[[Witches and prophecy]]");
  assert.equal(wikiInsert("Witches and prophecy", "the witches"), "[[Witches and prophecy|the witches]]");
  assert.equal(wikiInsert("Witches and prophecy", "witches and PROPHECY"), "[[Witches and prophecy]]");
  assert.equal(wikiInsert("Witches and prophecy", "a [bad] | selection"), "[[Witches and prophecy|a  bad    selection]]");
});

test("a title with link punctuation can't be linked", () => {
  for (const title of ["C# notes", "Draft [old]", "This | that", "Two\nlines", "", "   ", 7, null]) {
    assert.equal(linkable(title), false, String(title));
    assert.equal(wikiInsert(title, ""), null);
  }
  assert.equal(linkable("Lady Macbeth's goading"), true);
});

test("a wiki link counts as the words it reads as", () => {
  assert.equal(countWords("See [[Witches and prophecy|the scene]] now."), 4);
  assert.equal(countWords("See [[Witches and prophecy]] now."), 5);
  assert.equal(countWords("See [[Macbeth#The letter]] now."), 5);
});
