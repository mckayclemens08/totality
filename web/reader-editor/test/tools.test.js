import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState, EditorSelection } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { ensureSyntaxTree, foldService } from "@codemirror/language";
import { countWords, outline, sectionAt, stats, paragraphAt, smartReplacement, sectionFolding, matches, findSupport } from "../src/tools.js";
import { setSearchQuery, SearchQuery } from "@codemirror/search";

const chapter = `# Chapter One: The Harbour

The fog came in off the Solent before dawn, and Mrs. Hale's lamp was still lit.

## The letter

She read it twice. It was dated [the ninth](https://example.org/letters/9) of March.[^1]

\`\`\`
# not a heading
\`\`\`

## The crossing

Nobody spoke on the ferry.

# Chapter Two

The town again.

[^1]: The letter survives in the county archive.`;

function state(text, anchor = 0, head = anchor, extensions = []) {
  const s = EditorState.create({
    doc: text,
    selection: EditorSelection.single(anchor, head),
    extensions: [markdown({ base: markdownLanguage }), ...extensions],
  });
  ensureSyntaxTree(s, s.doc.length, 5000);
  return s;
}

test("words count as a reader would, without addresses or symbols", () => {
  assert.equal(countWords("The fog came in off the Solent."), 7);
  assert.equal(countWords("Mrs. Hale's lamp — well-trimmed — was lit."), 6);
  assert.equal(countWords("[the ninth](https://example.org/letters/9) of March.[^1]"), 4);
  assert.equal(countWords("## **Bold** heading"), 2);
  assert.equal(countWords(""), 0);
});

test("the outline lists headings in order and skips a code block's lines", () => {
  const headings = outline(state(chapter).doc);
  assert.deepEqual(headings.map((h) => [h.level, h.text]), [
    [1, "Chapter One: The Harbour"],
    [2, "The letter"],
    [2, "The crossing"],
    [1, "Chapter Two"],
  ]);
});

test("a section runs to the next heading at its level or higher", () => {
  const s = state(chapter);
  const letter = chapter.indexOf("She read");
  const section = sectionAt(s, letter);
  assert.equal(s.sliceDoc(section.from, section.to).trim().split("\n")[0], "## The letter");
  assert.ok(s.sliceDoc(section.from, section.to).includes("# not a heading"));
  assert.ok(!s.sliceDoc(section.from, section.to).includes("The crossing"));
  const top = sectionAt(s, 3);
  assert.ok(s.sliceDoc(top.from, top.to).includes("Nobody spoke"));
  assert.ok(!s.sliceDoc(top.from, top.to).includes("Chapter Two"));
});

test("stats count the doc, the selection, and the section", () => {
  const from = chapter.indexOf("Nobody");
  const s = state(chapter, from, from + "Nobody spoke".length);
  const counts = stats(s);
  assert.equal(counts.selection, 2);
  assert.equal(counts.section, 7);
  assert.equal(counts.words, countWords(chapter));
});

test("a heading folds its section, not the next one at its level", () => {
  const s = state(chapter, 0, 0, [sectionFolding]);
  const line = s.doc.line(3);
  const heading = s.doc.line(5);
  const range = s.facet(foldService)[0](s, heading.from, heading.to);
  assert.ok(range);
  const hidden = s.sliceDoc(range.from, range.to);
  assert.ok(hidden.includes("She read it twice"));
  assert.ok(!hidden.includes("The crossing"));
  assert.equal(s.facet(foldService)[0](s, line.from, line.to), null);
});

test("focus mode's paragraph is the lines between blank lines", () => {
  const text = "First line\nsecond line\n\nAnother paragraph";
  const p = paragraphAt(state(text), 3);
  assert.equal(text.slice(p.from, p.to), "First line\nsecond line");
});

test("straight quotes curl the right way, and two hyphens make a dash", () => {
  const typed = (text, at, char) => smartReplacement(state(text), at, char);
  assert.deepEqual(typed("She said ", 9, '"'), { from: 9, insert: "“" });
  assert.deepEqual(typed("“Yes", 4, '"'), { from: 4, insert: "”" });
  assert.deepEqual(typed("Hale", 4, "'"), { from: 4, insert: "’" });
  assert.deepEqual(typed("", 0, "'"), { from: 0, insert: "‘" });
  assert.deepEqual(typed("before -", 8, "-"), { from: 7, insert: "—" });
  // A rule, a table and code keep their hyphens and quotes.
  assert.equal(typed("--", 2, "-"), null);
  assert.equal(typed("|--", 3, "-"), null);
  assert.equal(typed("Use `say ", 9, '"'), null);
});

test("find counts matches and knows which one is selected", () => {
  let s = state("the tide, the fog, The harbour", 0, 0, [findSupport]);
  s = s.update({ effects: setSearchQuery.of(new SearchQuery({ search: "the", literal: true })) }).state;
  assert.deepEqual(matches(s), { count: 3, current: 0 });
  s = s.update({ selection: EditorSelection.single(10, 13) }).state;
  assert.deepEqual(matches(s), { count: 3, current: 2 });
  s = s.update({ effects: setSearchQuery.of(new SearchQuery({ search: "the", caseSensitive: true, literal: true })) }).state;
  assert.equal(matches(s).count, 2);
});
