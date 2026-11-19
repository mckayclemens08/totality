import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build } from "esbuild";

// Compile the TypeScript on the fly so the tests run the real source.
const out = "dist-test/protocol.mjs";
await build({ entryPoints: ["src/pairing/protocol.ts"], bundle: true, format: "esm", outfile: out, platform: "node", logLevel: "silent" });
const P = await import(`../${out}`);

const v = JSON.parse(readFileSync("../../docs/pairing-vectors.json", "utf8"));
const h = (s) => P.fromHex(s, s.length / 2);
const slotId = v.slotId;

test("vectors: key hash, code, QR text", () => {
  const pub = h(v.browserPub);
  assert.equal(P.keyHash(pub), v.keyHash);
  assert.equal(P.pairingCode(slotId, pub), v.code);
  assert.equal(P.qrText(slotId, { pub, slotSecret: h(v.slotSecret) }), v.qr);
});

test("vectors: the browser opens what TypeScript and Swift each sealed", () => {
  const keys = { priv: h(v.browserPriv), pub: h(v.browserPub), slotSecret: h(v.slotSecret) };
  for (const s of [v.tsSealed, v.swiftSealed]) {
    const root = P.openSealed({ slotId, keys, phonePub: h(s.phonePub), sealed: P.unb64(s.sealed) });
    assert.equal(P.toHex(root), v.rootKey);
  }
});

test("a full pairing, with the QR parsed on the phone side", () => {
  const keys = P.newBrowserKeys();
  const id = crypto.randomUUID();
  const qr = P.parseQR(P.qrText(id, keys));
  const root = crypto.getRandomValues(new Uint8Array(32));
  const { phonePub, sealed } = P.sealForBrowser({ qr, browserPub: keys.pub, phonePriv: crypto.getRandomValues(new Uint8Array(32)), rootKey: root });
  assert.deepEqual(P.openSealed({ slotId: id, keys, phonePub, sealed }), root);
});

test("a swapped browser key is refused by the phone", () => {
  const keys = P.newBrowserKeys(), attacker = P.newBrowserKeys();
  const id = crypto.randomUUID();
  const qr = P.parseQR(P.qrText(id, keys));
  assert.throws(() => P.sealForBrowser({ qr, browserPub: attacker.pub, phonePriv: crypto.getRandomValues(new Uint8Array(32)), rootKey: new Uint8Array(32) }), { reason: "wrongKey" });
});

test("the browser refuses a seal from someone without the slot secret, another slot, or tampering", () => {
  const keys = P.newBrowserKeys();
  const id = crypto.randomUUID();
  const qr = P.parseQR(P.qrText(id, keys));
  const root = crypto.getRandomValues(new Uint8Array(32));
  const phonePriv = crypto.getRandomValues(new Uint8Array(32));
  const good = P.sealForBrowser({ qr, browserPub: keys.pub, phonePriv, rootKey: root });
  // A relay that knows the public keys but not the slot secret.
  const forged = P.sealForBrowser({ qr: { ...qr, slotSecret: new Uint8Array(32) }, browserPub: keys.pub, phonePriv, rootKey: root });
  assert.throws(() => P.openSealed({ slotId: id, keys, phonePub: forged.phonePub, sealed: forged.sealed }), { reason: "badSeal" });
  // The same seal replayed into another slot.
  assert.throws(() => P.openSealed({ slotId: crypto.randomUUID(), keys, phonePub: good.phonePub, sealed: good.sealed }), { reason: "badSeal" });
  const flipped = good.sealed.slice(); flipped[40] ^= 1;
  assert.throws(() => P.openSealed({ slotId: id, keys, phonePub: good.phonePub, sealed: flipped }), { reason: "badSeal" });
  assert.throws(() => P.openSealed({ slotId: id, keys, phonePub: good.phonePub, sealed: good.sealed.slice(0, 20) }), { reason: "badSeal" });
});

test("bad QR text is refused", () => {
  for (const bad of ["", "totality-pair/2/x/y/z", "https://evil.example/pair", `totality-pair/1/${crypto.randomUUID()}/zz/zz`]) {
    assert.throws(() => P.parseQR(bad), { reason: "badQR" });
  }
});
