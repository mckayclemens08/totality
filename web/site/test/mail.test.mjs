import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build } from "esbuild";

for (const [n, e] of [["hpke", "src/mail/hpke.ts"], ["mime", "src/mail/mime.ts"], ["protocol", "src/pairing/protocol.ts"], ["sealed", "src/sealed.ts"]])
  await build({ entryPoints: [e], bundle: true, format: "esm", outfile: `dist-test/${n}.mjs`, platform: "node", logLevel: "silent" });
const H = await import("../dist-test/hpke.mjs"), X = await import("../dist-test/mime.mjs"), P = await import("../dist-test/protocol.mjs");
const v = JSON.parse(readFileSync("../../docs/mail-vectors.json", "utf8"));
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
const root = P.fromHex(v.rootKey, 32);
const seed = hkdf(sha256, root, new Uint8Array(0), new TextEncoder().encode("totality/mail-key/v1"), 32);
const b64 = (s) => Uint8Array.from(Buffer.from(s, "base64"));
const entry = (l) => v.entries.find((e) => e.label === l);
const open = (e) => H.splitEnvelope(H.openMail(b64(e.sealed), seed, v.mailbox, e.id));

test("the browser opens mail the server's real seal() made", () => {
  const plain = open(entry("plain"));
  assert.equal(plain.flagged, false);
  assert.ok(plain.received > Date.UTC(2026, 0, 1));
  const m = X.parseMail(plain.rest);
  assert.equal(m.subject, "The engine");
  assert.equal(m.from, "Charles Babbage <charles@example.org>");
  assert.equal(m.html, null);
  assert.match(m.text, /gears arrived on Tuesday\.\r?\n<b>not html<\/b>/);
});

test("a message moved to another mailbox or id, or opened with another key, is refused", () => {
  const e = entry("plain");
  assert.throws(() => H.openMail(b64(e.sealed), seed, "99999999-2222-4333-8444-555555555555", e.id), H.MailOpenFailure);
  assert.throws(() => H.openMail(b64(e.sealed), seed, v.mailbox, entry("rich").id), H.MailOpenFailure);
  assert.throws(() => H.openMail(b64(e.sealed), new Uint8Array(32).fill(7), v.mailbox, e.id), H.MailOpenFailure);
  const flipped = b64(e.sealed); flipped[60] ^= 1;
  assert.throws(() => H.openMail(flipped, seed, v.mailbox, e.id), H.MailOpenFailure);
});

test("rich mail: encoded words, quoted-printable, multipart, inline image, attachment, spam flag", () => {
  const env = open(entry("rich"));
  assert.equal(env.flagged, true);
  const m = X.parseMail(env.rest);
  assert.equal(m.subject, "Café menu");
  assert.equal(m.from, "Élègant Sender <sender@example.org>");
  assert.equal(m.text.trim(), "Plain version ✓");
  assert.match(m.html, /<p style="color:red">Hello/);
  assert.match(m.html, /src="data:image\/png;base64,/, "the inline image became a data: URL");
  assert.match(m.html, /https:\/\/tracker\.example\/p\.gif/, "remote images are left for the frame's CSP to block");
  assert.deepEqual(m.attachments.map((a) => [a.name, a.type]), [["menu.pdf", "application/pdf"]]);
  assert.equal(m.date, Date.parse("2026-11-18T16:30:00Z"));
});

test("only http(s) links are offered, and de-duplicated", () => {
  const m = X.parseMail(open(entry("rich")).rest);
  const fake = (h) => ({ querySelectorAll: () => [...h.matchAll(/<a href="([^"]*)">([^<]*)<\/a>/g)].map((x) => ({ getAttribute: () => x[1], textContent: x[2] })) });
  const links = X.linksIn(m.html, (h) => fake(h));
  assert.deepEqual(links, [{ href: "https://example.com/a", label: "a link" }]);
});

test("a message from another Totality account is marked, not opened", () => {
  const env = open(entry("direct"));
  assert.equal(env.from, "grace_hopper");
});

test("the parser survives hostile and broken mail", () => {
  for (const raw of ["", "\n\n", "Content-Type: multipart/mixed; boundary=\"x\"\n\n--x\n--x\n--x--", "Subject: =?utf-8?B?!!!?=\n\nbody", "Content-Type: multipart/mixed; boundary=a\n\n" + "--a\nContent-Type: multipart/mixed; boundary=a\n\n".repeat(60)])
    assert.doesNotThrow(() => X.parseMail(new TextEncoder().encode(raw)));
});
