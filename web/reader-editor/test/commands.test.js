import { test } from "node:test";
import assert from "node:assert/strict";
import { EditorState, EditorSelection } from "@codemirror/state";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { ensureSyntaxTree } from "@codemirror/language";
import { Strikethrough, TaskList } from "@lezer/markdown";
import { toggleWrap, setHeading, toggleList, toggleQuote, setLink, formatState, linkDestination } from "../src/commands.js";

function state(text, anchor = 0, head = anchor) {
  const s = EditorState.create({
    doc: text,
    selection: EditorSelection.single(anchor, head),
    extensions: [markdown({ base: markdownLanguage, extensions: [Strikethrough, TaskList] }), EditorState.allowMultipleSelections.of(true)],
  });
  ensureSyntaxTree(s, s.doc.length, 5000);
  return s;
}

const apply = (s, spec) => s.update(spec).state;
const text = (s) => s.doc.toString();

test("bold wraps the selection and unwraps it again", () => {
  const s = state("The Waste Land", 4, 9);
  const bold = apply(s, toggleWrap(s, "**"));
  assert.equal(text(bold), "The **Waste** Land");
  const back = apply(bold, toggleWrap(bold, "**"));
  assert.equal(text(back), "The Waste Land");
});

test("italic inside bold doesn't take the bold away", () => {
  const s = state("**April is the cruellest month**", 2, 7);
  const italic = apply(s, toggleWrap(s, "*"));
  assert.equal(text(italic), "***April* is the cruellest month**");
});

test("an empty selection gets a pair of markers with the cursor between", () => {
  const s = state("Shantih ", 8);
  const next = apply(s, toggleWrap(s, "*"));
  assert.equal(text(next), "Shantih **");
  assert.equal(next.selection.main.head, 9);
});

test("a heading replaces another heading and comes off when applied twice", () => {
  const s = state("## The Burial of the Dead", 3);
  const one = s.update(setHeading(s, 1)).state;
  assert.equal(text(one), "# The Burial of the Dead");
  const off = one.update(setHeading(one, 1)).state;
  assert.equal(text(off), "The Burial of the Dead");
});

test("a numbered list numbers each selected line, and a bullet list turns it back", () => {
  const s = state("Chapter one\nChapter two\nChapter three", 0, 30);
  const numbered = s.update(toggleList(s, "numbered")).state;
  assert.equal(text(numbered), "1. Chapter one\n2. Chapter two\n3. Chapter three");
  const all = numbered.update({ selection: EditorSelection.single(0, numbered.doc.length) }).state;
  const bullets = all.update(toggleList(all, "bullet")).state;
  assert.equal(text(bullets), "- Chapter one\n- Chapter two\n- Chapter three");
  const again = bullets.update({ selection: EditorSelection.single(0, bullets.doc.length) }).state;
  assert.equal(text(again.update(toggleList(again, "bullet")).state), "Chapter one\nChapter two\nChapter three");
});

test("a task list item reads as a task", () => {
  const s = state("Return library books", 0);
  const task = s.update(toggleList(s, "task")).state;
  assert.equal(text(task), "- [ ] Return library books");
  ensureSyntaxTree(task, task.doc.length, 5000);
  assert.equal(formatState(task).list, "task");
});

test("a quote toggles on and off", () => {
  const s = state("Hurry up please its time", 0);
  const quoted = s.update(toggleQuote(s)).state;
  assert.equal(text(quoted), "> Hurry up please its time");
  assert.equal(text(quoted.update(toggleQuote(quoted)).state), "Hurry up please its time");
});

test("a link wraps the selection, changes its address, and comes off keeping its words", () => {
  const s = state("Read the Norton edition", 9, 15);
  const linked = s.update(setLink(s, "https://wwnorton.com/books/the-waste-land")).state;
  assert.equal(text(linked), "Read the [Norton](https://wwnorton.com/books/the-waste-land) edition");
  const inside = state(text(linked), 11);
  assert.equal(formatState(inside).link, "https://wwnorton.com/books/the-waste-land");
  const moved = inside.update(setLink(inside, "https://example.org/a (b)")).state;
  assert.equal(text(moved), "Read the [Norton](https://example.org/a%20\\(b\\)) edition");
  const again = state(text(moved), 11);
  assert.equal(text(again.update(setLink(again, "")).state), "Read the Norton edition");
});

test("an address can't break out of its brackets", () => {
  assert.equal(linkDestination("https://a.org/x)y"), "https://a.org/x\\)y");
});

test("the format state follows the cursor", () => {
  const s = state("# Notes\n\nSome **bold** and *italic* and ~~gone~~ words", 18);
  const f = formatState(s);
  assert.equal(f.bold, true);
  assert.equal(f.italic, false);
  assert.equal(formatState(state(text(s), 3)).heading, 1);
  assert.equal(formatState(state(text(s), 30)).italic, true);
  assert.equal(formatState(state(text(s), 42)).strike, true);
});
