import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build } from "esbuild";

for (const [n, e] of [["sealed", "src/sealed.ts"], ["cal", "src/calendar/model.ts"], ["protocol", "src/pairing/protocol.ts"]])
  await build({ entryPoints: [e], bundle: true, format: "esm", outfile: `dist-test/${n}.mjs`, platform: "node", logLevel: "silent" });
const S = await import("../dist-test/sealed.mjs"), C = await import("../dist-test/cal.mjs"), P = await import("../dist-test/protocol.mjs");
const v = JSON.parse(readFileSync("../../docs/calendar-vectors.json", "utf8"));
const root = P.fromHex(v.rootKey, 32);
const open = (e) => JSON.parse(new TextDecoder().decode(S.openBlob(Uint8Array.from(Buffer.from(e.meta, "base64")), S.objectKeyFromRoot(root, "event", e.id), e.id)));

test("the browser opens events the real CalendarVault sealed", () => {
  assert.equal(v.entries.length, 3);
  for (const e of v.entries) {
    const ev = C.parseEvent(e.id, open(e));
    assert.equal(ev.title, e.title);
    assert.equal(ev.start, Date.UTC(2001, 0, 1) + e.start * 1000);
    assert.equal(ev.allDay, e.allDay);
    assert.equal(ev.repeat?.freq ?? null, e.repeats ?? null);
  }
  const wrong = v.entries[0];
  assert.throws(() => S.openBlob(Uint8Array.from(Buffer.from(wrong.meta, "base64")), S.objectKeyFromRoot(root, "metadata", wrong.id), wrong.id));
});

const ev = (o) => ({ id: "x", title: "t", location: "", notes: "", allDay: false, tz: "America/Denver", repeat: null, skipped: new Set(), ...o });
const at = (iso) => Date.parse(iso);

test("weekly repeats keep the wall-clock time through daylight saving", () => {
  // Mon 9:00 in Denver (MST, UTC-7) before the March 2026 change, then MDT (UTC-6) after.
  const e = ev({ start: at("2026-03-02T16:00:00Z"), end: at("2026-03-02T17:00:00Z"), repeat: { freq: "weekly", until: null } });
  const got = C.occurrences(e, at("2026-03-01T00:00:00Z"), at("2026-03-24T00:00:00Z")).map((o) => new Date(o.start).toISOString());
  assert.deepEqual(got, ["2026-03-02T16:00:00.000Z", "2026-03-09T15:00:00.000Z", "2026-03-16T15:00:00.000Z", "2026-03-23T15:00:00.000Z"]);
});

test("monthly repeats skip months without that day, until stops them, skipped removes one", () => {
  const e = ev({ start: at("2026-01-31T19:00:00Z"), end: at("2026-01-31T20:00:00Z"), repeat: { freq: "monthly", until: { year: 2026, month: 5, day: 31 } } });
  const days = C.occurrences(e, at("2026-01-01T00:00:00Z"), at("2027-01-01T00:00:00Z")).map((o) => new Date(o.start).toISOString().slice(0, 10));
  assert.deepEqual(days, ["2026-01-31", "2026-03-31", "2026-05-31"]);
  const skipped = ev({ start: at("2026-01-05T17:00:00Z"), end: at("2026-01-05T18:00:00Z"), repeat: { freq: "daily", until: null }, skipped: new Set([at("2026-01-06T17:00:00Z")]) });
  assert.equal(C.occurrences(skipped, at("2026-01-05T00:00:00Z"), at("2026-01-08T00:00:00Z")).length, 2);
});

test("all-day events cover their days, and a far-off repeat is cheap", () => {
  const e = ev({ tz: "GMT", allDay: true, start: at("2026-11-18T00:00:00Z"), end: at("2026-11-19T00:00:00Z") });
  assert.equal(C.occurrences(e, at("2026-11-20T00:00:00Z"), at("2026-11-21T00:00:00Z")).length, 0);
  assert.equal(C.occurrences(e, at("2026-11-19T00:00:00Z"), at("2026-11-20T00:00:00Z")).length, 1);
  const daily = ev({ start: at("2000-01-01T17:00:00Z"), end: at("2000-01-01T18:00:00Z"), repeat: { freq: "daily", until: null } });
  const t = Date.now();
  assert.equal(C.occurrences(daily, at("2026-11-16T00:00:00Z"), at("2026-11-23T00:00:00Z")).length, 7);
  assert.ok(Date.now() - t < 500);
});

test("zone helpers round-trip", () => {
  const ms = at("2026-07-04T18:30:00Z");
  const w = C.wall(ms, "America/Denver");
  assert.deepEqual([w.h, w.mi], [12, 30]);
  assert.equal(C.fromWall(w, "America/Denver"), ms);
});
