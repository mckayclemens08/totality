import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { build } from "esbuild";

for (const [n, e] of [["rules", "src/messages/rules.ts"], ["attach", "src/messages/attach.ts"]])
  await build({ entryPoints: [e], bundle: true, format: "esm", outfile: `dist-test/${n}.mjs`, platform: "node", logLevel: "silent" });
const R = await import("../dist-test/rules.mjs"), A = await import("../dist-test/attach.mjs");

test("usernames follow the iPhone's rule", () => {
  assert.equal(R.normalizedUsername("  @@Jonah_Hikes "), "jonah_hikes");
  assert.equal(R.normalizedUsername("ab"), null);
  assert.equal(R.normalizedUsername("has space"), null);
  assert.equal(R.displayName("@sam_r:usetotality.com"), "sam_r");
  assert.equal(R.displayName("not-an-id"), "not-an-id");
});

test("disappearing settings are stored exactly as the iPhone writes them", () => {
  // Disappearing.stateJSON in Sources/TotalityMessages/Messages.swift.
  assert.deepEqual(R.disappearingContent("off"), {});
  assert.deepEqual(R.disappearingContent("afterViewing"), { "app.totality.after_viewing": true });
  assert.deepEqual(R.disappearingContent("day"), { max_lifetime: 86_400_000 });
  assert.deepEqual(R.disappearingContent("week"), { max_lifetime: 604_800_000 });
  for (const d of R.DISAPPEARING) assert.equal(R.disappearingFrom(R.disappearingContent(d)), d);
  assert.equal(R.disappearingFrom({ max_lifetime: 3_600_000 }), "day");
  assert.equal(R.disappearingFrom({ max_lifetime: 0 }), "off");
  assert.equal(R.disappearingFrom(null), "off");
});

const msg = (over) => ({ id: "x", sender: "@a:usetotality.com", body: "hi", isOwn: false, time: 0, state: "sent", decrypted: true, seen: false, kind: { type: "text" }, reactions: [], replyTo: null, canReply: true, ...over });

test("disappearing messages: only messages sent after it began, hidden and removed on time", () => {
  const since = 1_000_000;
  const day = { setting: "day", since, changedBy: null };
  const before = msg({ id: "old", time: since - 1 });
  const mineOld = msg({ id: "mine", isOwn: true, time: since + 2 });
  const theirsNew = msg({ id: "new", time: since + 86_400_000 });
  const now = since + 86_400_000 + 5;
  assert.deepEqual(R.visibleMessages([before, mineOld, theirsNew], day, now, null).map((m) => m.id), ["old", "new"]);
  assert.deepEqual(R.dueMessages([before, mineOld, theirsNew], day, now).map((m) => m.id), ["mine"]);
  const after = { setting: "afterViewing", since, changedBy: null };
  const seen = msg({ id: "seen", isOwn: true, time: since + 1, seen: true });
  assert.deepEqual(R.dueMessages([seen, msg({ id: "unseen", isOwn: true, time: since + 2 })], after, now).map((m) => m.id), ["seen"]);
  assert.deepEqual(R.visibleMessages([msg({ id: "read", time: since + 5 }), msg({ id: "unread", time: since + 50 })], after, now, since + 10).map((m) => m.id), ["unread"]);
  assert.deepEqual(R.dueMessages([msg({ id: "f", isOwn: true, time: since + 1, state: "failed" })], day, now), [], "unsent messages are never removed");
});

test("seen marks your messages up to the newest one someone else read", () => {
  const list = [msg({ id: "1", isOwn: true }), msg({ id: "2" }), msg({ id: "3", isOwn: true })];
  assert.deepEqual(R.markingSeen(list, 1).map((m) => m.seen), [true, false, false]);
  assert.deepEqual(R.markingSeen(list, null).map((m) => m.seen), [false, false, false]);
});

test("groups and one-to-one chats follow the iPhone's rules", () => {
  assert.deepEqual(R.parseGroupMembers("jonah, @Sam_R  mckay jonah", "mckay"), ["jonah", "sam_r"]);
  assert.throws(() => R.parseGroupMembers("jonah", "mckay"), /at least two/);
  assert.throws(() => R.parseGroupMembers("jonah, no!", "mckay"), /isn't a Totality username/);
  assert.throws(() => R.parseGroupMembers(Array.from({ length: 20 }, (_, i) => `user${i}`).join(","), "mckay"), /up to 20/);
  assert.equal(R.cleanGroupName("  Trail\ncrew  "), "Trail crew");
  assert.equal(R.cleanGroupName("   "), null);
  assert.equal([...R.cleanGroupName("x".repeat(80))].length, 60);
  assert.ok(R.isJustTheTwoOfYou(["@me:s", "@you:s"], "@me:s", "@you:s"));
  assert.ok(!R.isJustTheTwoOfYou(["@me:s", "@you:s", "@them:s"], "@me:s", "@you:s"));
  assert.ok(!R.isJustTheTwoOfYou(["@me:s", "@me:s"], "@me:s", "@you:s"));
  assert.ok(R.isSharedRoom("Totality shared list", null) && R.isSharedRoom(null, "app.totality.tasks.v1") && !R.isSharedRoom("Trail crew", null));
});

test("only this server's own media is ever fetched", () => {
  assert.ok(R.isOwnMedia("mxc://usetotality.com/AbC_123-x"));
  for (const bad of ["mxc://evil.example/abc", "mxc://usetotality.com/../x", "https://usetotality.com/x", "mxc://usetotality.com/a/b", 5, null])
    assert.ok(!R.isOwnMedia(bad), String(bad));
});

test("attachments are sealed per the Matrix v2 format and open again", async () => {
  const plain = new TextEncoder().encode("a photo's bytes ".repeat(500));
  const { data, info } = await A.encryptAttachment(plain);
  assert.notDeepEqual(data, plain);
  assert.equal(info.v, "v2");
  assert.equal(info.key.alg, "A256CTR");
  assert.match(info.iv, /^[A-Za-z0-9+/]{22}$/, "16-byte IV, unpadded base64");
  assert.deepEqual([...Buffer.from(info.iv, "base64").subarray(8)], [0, 0, 0, 0, 0, 0, 0, 0], "counter half starts at zero");
  assert.match(info.key.k, /^[A-Za-z0-9_-]{43}$/, "32-byte key, base64url");
  assert.deepEqual(await A.decryptAttachment(data, { ...info, url: "mxc://usetotality.com/x" }), plain);
  const tampered = data.slice(); tampered[3] ^= 1;
  await assert.rejects(A.decryptAttachment(tampered, info), /hash/);
  await assert.rejects(A.decryptAttachment(data, { ...info, key: { ...info.key, alg: "A128CTR" } }));
});

test("attachments made by another client open (spec example shape)", async () => {
  // Built with Node's own AES-CTR, the way other Matrix clients do it.
  const { createCipheriv, createHash, randomBytes } = await import("node:crypto");
  const key = randomBytes(32), iv = Buffer.concat([randomBytes(8), Buffer.alloc(8)]);
  const plain = Buffer.from("from another client");
  const c = createCipheriv("aes-256-ctr", key, iv);
  const data = Buffer.concat([c.update(plain), c.final()]);
  const file = { v: "v2", url: "mxc://usetotality.com/x", iv: iv.toString("base64").replace(/=+$/, ""), hashes: { sha256: createHash("sha256").update(data).digest("base64").replace(/=+$/, "") },
    key: { alg: "A256CTR", ext: true, k: key.toString("base64url"), key_ops: ["encrypt", "decrypt"], kty: "oct" } };
  assert.equal(Buffer.from(await A.decryptAttachment(new Uint8Array(data), file)).toString(), "from another client");
});

test("the browser never resets the account's Matrix keys (review M4)", () => {
  const files = readdirSync("src/messages").map((f) => readFileSync(`src/messages/${f}`, "utf8")).join("\n");
  for (const call of ["setupNewCrossSigning", "bootstrapSecretStorage", "resetKeyBackup", "resetEncryption", "createRecoveryKeyFromPassphrase", "resetCrossSigning", "deleteKeyBackupVersion"])
    assert.ok(!files.includes(call), `${call} appears in Messages`);
  const engine = readFileSync("src/messages/engine.ts", "utf8");
  assert.match(engine, /authUploadDeviceSigningKeys: async \(\) => \{ throw/, "a reset could never upload new keys");
  assert.match(engine, /if \(!tuple \|\| stored\.some/, "stops when the account's keys aren't all in secret storage");
});

test("Messages is off on shared computers, uses a plain device name, and the SDK stays quiet", () => {
  const view = readFileSync("src/messages/view.ts", "utf8"), engine = readFileSync("src/messages/engine.ts", "utf8");
  assert.match(view, /ctx\.ownComputer === false\) \{ body\.replaceChildren\(sharedScreen\(\)\); return; \}/);
  assert.equal(R.DEVICE_NAME, "Totality web");
  assert.match(engine, /logger: silent/);
  assert.match(engine, /methodFactory = \(\) => \(\) => \{\}/);
  assert.doesNotMatch(view + engine, /formatted_body|innerHTML/, "message HTML is never used");
});

test("the Matrix SDK is pinned exactly and loads only with Messages", () => {
  const pkg = JSON.parse(readFileSync("package.json", "utf8"));
  assert.equal(pkg.devDependencies["matrix-js-sdk"], "45.0.0");
  const lock = JSON.parse(readFileSync("package-lock.json", "utf8"));
  assert.equal(lock.packages["node_modules/@matrix-org/matrix-sdk-crypto-wasm"].version, "18.9.0");
  const app = readdirSync("dist").find((f) => /^app\..*\.js$/.test(f));
  assert.doesNotMatch(readFileSync(`dist/${app}`, "utf8"), /OlmMachine|matrix_sdk_crypto/, "the SDK isn't in the main bundle");
  assert.equal(readdirSync("dist/assets").filter((f) => f.endsWith(".wasm")).length, 1);
});
