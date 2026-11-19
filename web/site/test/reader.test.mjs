import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build } from "esbuild";

for (const [name, entry] of [["sealed", "src/sealed.ts"], ["item", "src/reader/item.ts"], ["markdown", "src/reader/markdown.ts"], ["protocol", "src/pairing/protocol.ts"]]) {
  await build({ entryPoints: [entry], bundle: true, format: "esm", outfile: `dist-test/${name}.mjs`, platform: "node", logLevel: "silent" });
}
const S = await import("../dist-test/sealed.mjs"), I = await import("../dist-test/item.mjs"), M = await import("../dist-test/markdown.mjs"), P = await import("../dist-test/protocol.mjs");
const v = JSON.parse(readFileSync("../../docs/reader-vectors.json", "utf8"));
const root = P.fromHex(v.rootKey, 32);
const b64 = (s) => Uint8Array.from(Buffer.from(s, "base64"));
const text = (b) => new TextDecoder().decode(b);

test("the browser opens what the real ReaderVault sealed on the iPhone", () => {
  assert.ok(v.entries.length >= 2);
  for (const e of v.entries) {
    const meta = S.openBlob(b64(e.meta), S.objectKeyFromRoot(root, "metadata", e.id), e.id);
    const item = I.parseItem(text(meta));
    assert.equal(item.id, e.id);
    assert.equal(item.title, e.title);
    assert.equal(item.kind, "note");
    assert.equal(item.mime, e.mime);
    assert.ok(Math.abs(item.updatedAt - Date.now()) < 5 * 365 * 864e5, "date converts from the Apple epoch");
    const body = S.openBlob(b64(e.body), S.objectKeyFromRoot(root, "content", e.id), e.id);
    assert.equal(text(body), e.text);
  }
});

test("a blob opens only with the right purpose, id and key", () => {
  const e = v.entries[0];
  const sealed = b64(e.body);
  assert.throws(() => S.openBlob(sealed, S.objectKeyFromRoot(root, "metadata", e.id), e.id), S.OpenFailure);
  assert.throws(() => S.openBlob(sealed, S.objectKeyFromRoot(root, "content", v.entries[1].id), v.entries[1].id), S.OpenFailure);
  assert.throws(() => S.openBlob(sealed, S.objectKeyFromRoot(new Uint8Array(32), "content", e.id), e.id), S.OpenFailure);
  assert.throws(() => S.openBlob(sealed, S.objectKeyFromRoot(root, "content", e.id), v.entries[1].id), S.OpenFailure, "the id is authenticated");
  const flipped = sealed.slice(); flipped[60] ^= 1;
  assert.throws(() => S.openBlob(flipped, S.objectKeyFromRoot(root, "content", e.id), e.id), S.OpenFailure);
});

test("storage keys name only this account's sealed blobs", () => {
  const owner = "11111111-2222-4333-8444-555555555555", blob = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  assert.equal(I.blobIdFromKey(`${owner}/sealed/${blob}`, owner), blob);
  assert.equal(I.blobIdFromKey(`${owner}/old/path.body`, owner), null);
  assert.equal(I.blobIdFromKey(`99999999-2222-4333-8444-555555555555/sealed/${blob}`, owner), null);
  assert.equal(I.blobIdFromKey(null, owner), null);
});

test("markdown becomes a tree, and markup in a note stays text", () => {
  const blocks = M.parse(v.entries[0].text);
  assert.equal(blocks[0].t, "h");
  assert.equal(blocks.find((b) => b.t === "ul").items.length, 2);
  const last = blocks[blocks.length - 1];
  assert.ok(last.runs.some((r) => r.text.includes("<b>not html</b>")), "kept as literal text");
  assert.ok(last.runs.some((r) => r.bold && r.text === "Hegel"));
});

test("only http(s) links survive, and scripts never do", () => {
  const link = (u) => M.inline(`[x](${u})`)[0];
  assert.equal(link("https://example.com/a").href, "https://example.com/a");
  for (const bad of ["javascript:alert(1)", "data:text/html,x", "//evil.example", "vbscript:x"]) assert.equal(link(bad).href, undefined);
  assert.deepEqual(M.plain("a\n\nb").map((b) => b.runs[0].text), ["a", "b"]);
});
