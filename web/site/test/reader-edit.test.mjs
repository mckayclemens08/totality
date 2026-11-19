// Website editing for the Reader. docs/reader-web-vectors.json is what this code writes; Swift's
// ReaderWebEditVectorsTests opens every doc in the real ReaderVault. Here: the file is current, the parts are
// sealed the way the browser reads them, and the formatting buttons write the Markdown they should.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const { makeWebVectors } = await import("./make-reader-vectors.mjs");
const R = await import("../dist-test/reader-support.mjs");

const v = JSON.parse(readFileSync("../../docs/reader-web-vectors.json", "utf8"));
const root = R.fromHex(v.rootKey, 32);

test("the committed website vectors are what this code writes now", () => {
  assert.deepEqual(v, JSON.parse(JSON.stringify(makeWebVectors())));
});

test("each doc opens again in the browser, with the hash, body hash and blob the iPhone works out", () => {
  for (const it of v.items) {
    const meta = Buffer.from(it.meta, "base64"), body = Buffer.from(it.body, "base64");
    const raw = JSON.parse(new TextDecoder().decode(R.openBlob(meta, R.objectKeyFromRoot(root, "metadata", it.id), it.id)));
    assert.equal(raw.id.toLowerCase(), it.id);
    assert.equal(raw.mime, "text/markdown; variant=pandoc");
    assert.equal(raw.byteCount, new TextEncoder().encode(it.text).length);
    assert.equal(new TextDecoder().decode(R.openBlob(body, R.objectKeyFromRoot(root, "content", it.id), it.id)), it.text);
    assert.equal(R.itemHash(meta, body), it.hash);
    assert.equal(R.bodyHash(body), it.bodyHash);
    assert.equal(R.blobID(it.owner, it.id, it.bodyHash), it.blob);
  }
  const kept = JSON.parse(new TextDecoder().decode(R.openBlob(Buffer.from(v.items[2].meta, "base64"), R.objectKeyFromRoot(root, "metadata", v.items[2].id), v.items[2].id)));
  assert.deepEqual(kept.futurePart, { kept: true }, "parts this version doesn't know ride along");
});

test("only docs already in the editor's Markdown are edited here", () => {
  assert.equal(R.editable({ kind: "note", mime: "text/markdown; variant=pandoc" }), true);
  assert.equal(R.editable({ kind: "note", mime: "text/markdown" }), false);
  assert.equal(R.editable({ kind: "note", mime: "text/plain" }), false);
  assert.equal(R.editable({ kind: "file", mime: "text/markdown; variant=pandoc" }), false);
  assert.equal(R.editable({ kind: "journal", mime: "text/markdown; variant=pandoc" }), false);
});

test("bold and italic go on, and come off again", () => {
  const on = R.wrap("make this bold", 5, 9, "**");
  assert.deepEqual(on, { text: "make **this** bold", start: 7, end: 11 });
  assert.deepEqual(R.wrap(on.text, on.start, on.end, "**"), { text: "make this bold", start: 5, end: 9 });
  assert.deepEqual(R.wrap("a *b* c", 2, 5, "*"), { text: "a b c", start: 2, end: 3 });
});

test("headings, lists and quotes mark every line chosen", () => {
  assert.equal(R.linePrefix("one\ntwo\nthree", 0, 7, "bullet").text, "- one\n- two\nthree");
  assert.equal(R.linePrefix("- one\n- two", 0, 11, "bullet").text, "one\ntwo");
  assert.equal(R.linePrefix("a\nb", 0, 3, "number").text, "1. a\n2. b");
  assert.equal(R.linePrefix("# Title", 2, 2, "h2").text, "## Title", "a heading changes level rather than stacking");
  assert.equal(R.linePrefix("x\nquote me", 4, 4, "quote").text, "x\n> quote me");
});

test("links take only web and mail addresses", () => {
  assert.equal(R.link("see here", 4, 8, "https://example.com/a b").text, "see [here](https://example.com/a%20b)");
  assert.equal(R.link("x", 0, 1, "javascript:alert(1)"), null);
  assert.equal(R.link("x", 0, 1, "data:text/html,hi"), null);
  assert.deepEqual(R.parse(R.link("x", 0, 1, "https://a.b/").text)[0].runs[0], { text: "x", href: "https://a.b/" });
});

test("words are counted the way a writer would", () => {
  assert.equal(R.words("# Title\n\nIt's a *two*-part, well-made idea — 5 ideas."), 8);
  assert.equal(R.words(""), 0);
});
