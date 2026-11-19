import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build } from "esbuild";

for (const [n, e] of [["sealed", "src/sealed.ts"], ["photos", "src/photos/model.ts"], ["protocol", "src/pairing/protocol.ts"]])
  await build({ entryPoints: [e], bundle: true, format: "esm", outfile: `dist-test/${n}.mjs`, platform: "node", logLevel: "silent" });
const S = await import("../dist-test/sealed.mjs"), M = await import("../dist-test/photos.mjs"), P = await import("../dist-test/protocol.mjs");
const v = JSON.parse(readFileSync("../../docs/photos-vectors.json", "utf8"));
const root = P.fromHex(v.rootKey, 32);
const b64 = (s) => Uint8Array.from(Buffer.from(s, "base64"));
const opener = (purpose, e, sealed) => S.openBlob(b64(sealed), S.objectKeyFromRoot(root, purpose, e.id), e.id);

test("the browser opens details, thumbnails and originals the real PhotoSealer sealed", () => {
  assert.equal(v.entries.length, 2);
  for (const e of v.entries) {
    const d = JSON.parse(new TextDecoder().decode(opener("photo-details", e, e.details)));
    const p = M.parsePhoto(e.id, d, e.owner);
    assert.ok(p, "details parse");
    assert.equal(p.thumbnail, e.thumbBlob);
    assert.equal(p.original, e.originalBlob);
    assert.ok(p.taken > Date.UTC(2025, 0, 1));
    assert.deepEqual(Buffer.from(opener("photo-thumbnail", e, e.thumb)), Buffer.from(b64(e.thumbPlain)));
    assert.deepEqual(Buffer.from(opener("photo", e, e.original)), Buffer.from(b64(e.originalPlain)));
    assert.throws(() => opener("photo", e, e.thumb), S.OpenFailure, "a thumbnail is not an original");
  }
});

test("another account's or another photo's details are never shown", () => {
  const e = v.entries[0];
  const d = JSON.parse(new TextDecoder().decode(opener("photo-details", e, e.details)));
  assert.equal(M.parsePhoto(e.id, d, "99999999-2222-4333-8444-555555555555"), null);
  assert.equal(M.parsePhoto(v.entries[1].id, d, e.owner), null);
});

test("what a browser shows: JPEG yes, HEIC and video no; trash is hidden; newest first", () => {
  const [a, b] = v.entries.map((e) => M.parsePhoto(e.id, JSON.parse(new TextDecoder().decode(opener("photo-details", e, e.details))), e.owner));
  assert.equal(M.showableType(a), "image/jpeg");
  assert.equal(M.showableType(b), null);
  assert.equal(M.showableType({ ...a, kind: "video" }), null);
  assert.deepEqual(M.library([a, b, { ...a, id: "x", trashed: true }]).map((p) => p.id), [b.id, a.id]);
  assert.equal(a.caption, "Trail crew <b>x</b>", "kept as literal text");
});
