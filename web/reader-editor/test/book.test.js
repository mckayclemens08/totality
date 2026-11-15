import { test } from "node:test";
import assert from "node:assert/strict";
import { align, pageText, locate } from "../src/bookAlign.js";

// Chapter 1 of Pride and Prejudice (1813, public domain), as a Project Gutenberg EPUB sets it out. The
// page's text nodes include the spaces and line breaks between tags, and a page number Listen never reads.
const pieces = [
  "\n  ", "CHAPTER I.", "\n\n  ",
  "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.",
  "\n\n  ",
  "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered as the rightful property of some one or other of their daughters.",
  "\n\n  ", "[Pg 2]", "\n  ",
  "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”",
  "\n\n  ", "Mr. Bennet replied that he had not.", "\n",
];

// What the Reader's chapter parser gives Listen for the same chapter: blocks joined by line breaks.
const listen = [
  "CHAPTER I.",
  "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.",
  "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered as the rightful property of some one or other of their daughters.",
  "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”",
  "Mr. Bennet replied that he had not.",
].join("\n");

const page = pageText(pieces);
const map = align(listen, page.text);

const words = (range) => page.text.slice(range[0], range[1]);
const sentence = (text) => {
  const start = listen.indexOf(text);
  return [start, start + text.length];
};

test("every word Listen reads is found on the page", () => {
  assert.equal(map.coverage, 1);
});

test("a sentence Listen speaks is the same words on the page", () => {
  const spoken = "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.";
  assert.equal(words(map.pageRange(...sentence(spoken))), spoken);
  const quoted = "“My dear Mr. Bennet,” said his lady to him one day, “have you heard that Netherfield Park is let at last?”";
  assert.equal(words(map.pageRange(...sentence(quoted))), quoted);
});

test("a range Listen has after something only the page has still lands on its own words", () => {
  const last = "Mr. Bennet replied that he had not.";
  assert.equal(words(map.pageRange(...sentence(last))), last);
  assert.equal(words(map.pageRange(...sentence("Bennet replied"))), "Bennet replied");
});

test("a tap on the page finds the place in Listen's text", () => {
  const onPage = page.text.indexOf("Netherfield");
  assert.equal(listen.slice(map.listenOffset(onPage), map.listenOffset(onPage) + 11), "Netherfield");
  // A tap on the page number, which Listen doesn't read, goes to the next words it does.
  const pageNumber = page.text.indexOf("[Pg 2]");
  assert.equal(listen.slice(map.listenOffset(pageNumber)).startsWith("“My dear"), true);
  // Past the last word there's nothing to go to.
  assert.equal(map.listenOffset(page.text.length), null);
});

test("a place in the joined text is found in its own text piece", () => {
  const place = page.text.indexOf("Mr. Bennet replied");
  const found = locate(page.starts, place);
  assert.equal(pieces[found.piece].slice(found.offset).startsWith("Mr. Bennet replied"), true);
  assert.deepEqual(locate(page.starts, 0), { piece: 0, offset: 0 });
});

test("a saved article lines up though the page decodes an entity Listen kept as written", () => {
  // The page shows the entity as its character. Listen's simpler reader left one as written.
  const article = pageText([
    "Why teachers leave rural schools", "\n",
    "Turnover is less about pay than about how a school is run. ",
    "Teachers who leave name the principal before the salary — and the drive to town comes next.",
    "\n", "Districts that kept their staff asked teachers first.",
  ]);
  const said = [
    "Why teachers leave rural schools",
    "Turnover is less about pay than about how a school is run. Teachers who leave name the principal before the salary &mdash; and the drive to town comes next.",
    "Districts that kept their staff asked teachers first.",
  ].join("\n");
  const articleMap = align(said, article.text);
  assert.ok(articleMap.coverage > 0.9);
  const last = "Districts that kept their staff asked teachers first.";
  const start = said.indexOf(last);
  const range = articleMap.pageRange(start, start + last.length);
  assert.equal(article.text.slice(range[0], range[1]), last);
  const tail = "and the drive to town comes next.";
  const tailStart = said.indexOf(tail);
  const tailRange = articleMap.pageRange(tailStart, tailStart + tail.length);
  assert.equal(article.text.slice(tailRange[0], tailRange[1]), tail);
});

test("text with nothing in common maps to nothing, and empty text is safe", () => {
  const other = align("Completely different words here.", "Nothing at all alike in this one!");
  assert.ok(other.coverage < 0.5);
  const empty = align("", "");
  assert.equal(empty.coverage, 0);
  assert.equal(empty.pageRange(0, 10), null);
  assert.equal(empty.listenOffset(0), null);
});
