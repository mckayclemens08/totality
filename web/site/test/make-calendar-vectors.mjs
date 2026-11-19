// Makes docs/calendar-web-vectors.json with the website's own code: events created, edited and deleted the way
// the website does it, sealed the way it seals them. Swift's CalendarWebEditVectorsTests opens every one in the
// real CalendarVault. Run `node test/make-calendar-vectors.mjs` after changing how the website writes events.
// Nonces and IDs are fixed, so the same code makes the same bytes and the test can tell the file is current.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

process.env.TZ = "America/Denver";
await build({ entryPoints: ["test/support/calendar.ts"], bundle: true, format: "esm", outfile: "dist-test/calendar-support.mjs", platform: "node", logLevel: "silent" });
const C = await import("../dist-test/calendar-support.mjs");
const D = "America/Denver";
const at = (y, mo, d, h = 0, mi = 0, tz = D) => C.dayStart({ year: y, month: mo, day: d }, tz) + (h * 60 + mi) * 60_000;

export function makeWebVectors() {
  const old = JSON.parse(readFileSync("../../docs/calendar-vectors.json", "utf8"));
  const root = C.fromHex(old.rootKey, 32);
  let n = 0;
  C.setIDMaker(() => `CA1E0000-0000-4000-8000-${String(++n).padStart(12, "0")}`);
  const now = at(2026, 11, 19, 7, 15);
  const items = [];
  const seal = (json, expect) => {
    const id = String(json.id).toLowerCase();
    const nonce = new Uint8Array(24).fill(items.length + 1);
    const meta = C.sealBlob(new TextEncoder().encode(JSON.stringify(json)), C.objectKeyFromRoot(root, "event", id), id, nonce);
    items.push({ id, meta: Buffer.from(meta).toString("base64"), hash: C.metaOnlyHash(meta), expect });
    return items.length - 1;
  };
  const draft = (over) => ({ title: "", location: "", notes: "", start: at(2026, 11, 20, 9), end: at(2026, 11, 20, 10), isAllDay: false, frequency: null, until: null, reminderMinutes: null, attachments: [], ...over });

  // 1. A new weekly event with every part: place, notes, an end, a reminder, a Reader doc attached.
  const doc = { module: "reader", kind: "note", id: "5E1D0000-0000-4000-8000-0000000000D1", keyRef: "crk:5e1d0000-0000-4000-8000-0000000000d1", preview: { title: "Seminar outline" } };
  const weekly = C.create(draft({ title: "  Seminar  ", location: "JFSB 4010 ", notes: "Bring the outline.\nAsk about week 9.", start: at(2026, 11, 20, 15, 30), end: at(2026, 11, 20, 16, 45),
    frequency: "weekly", until: { year: 2027, month: 4, day: 20 }, reminderMinutes: 30, attachments: [doc] }), now, D);
  seal(weekly, { title: "Seminar", location: "JFSB 4010", notes: "Bring the outline.\nAsk about week 9.", start: weekly.start, end: weekly.end, isAllDay: false, timeZoneID: D,
    repeatRule: { frequency: "weekly", until: { year: 2027, month: 4, day: 20 } }, reminderMinutes: 30, skipped: [], attachments: [doc], createdAt: C.toApple(now) });

  // 2. An all-day trip over three days.
  const trip = C.create(draft({ title: "Moab", isAllDay: true, start: at(2026, 12, 18, 9), end: at(2026, 12, 20, 9) }), now, D);
  seal(trip, { title: "Moab", isAllDay: true, timeZoneID: "GMT", start: C.toApple(Date.UTC(2026, 11, 18)), end: C.toApple(Date.UTC(2026, 11, 20)), skipped: [] });

  // 3. "This event only": the second week leaves the series, an hour later, and the series skips it.
  const second = at(2026, 11, 27, 15, 30);
  const [single, withSkip] = C.update(weekly, second, draft({ title: "Seminar (moved)", start: second + 3_600_000, end: second + 3_600_000 + 75 * 60_000 }), "this", now + 60_000, D);
  seal(single, { title: "Seminar (moved)", start: C.toApple(second + 3_600_000), skipped: [] });
  seal(withSkip, { title: "Seminar", skipped: [C.toApple(second)], updatedAt: C.toApple(now + 60_000) });

  // 4. One occurrence deleted, then "all of them" moved 30 minutes later: the skipped week moves with it.
  const third = at(2026, 12, 4, 15, 30);
  const { save: skipped2 } = C.remove(withSkip, third, "this", now + 120_000);
  const fourth = at(2026, 12, 11, 15, 30);
  const d4 = C.draftFor({ event: C.parseEvent(skipped2.id.toLowerCase(), skipped2), start: fourth, end: fourth + 75 * 60_000 }, skipped2, D);
  const [moved] = C.update(skipped2, fourth, { ...d4, start: fourth + 1_800_000, end: fourth + 1_800_000 + 75 * 60_000 }, "all", now + 180_000, D);
  seal(moved, { start: weekly.start + 1800, skipped: [C.toApple(second) + 1800, C.toApple(third) + 1800], reminderMinutes: 30, attachments: [doc] });

  // 5. An iPhone event edited on the website: unknown parts the phone may add later ride along.
  const phone = JSON.parse(new TextDecoder().decode(C.openBlob(Buffer.from(old.entries[1].meta, "base64"), C.objectKeyFromRoot(root, "event", old.entries[1].id), old.entries[1].id)));
  const phoneIndex = seal(phone, { title: phone.title });
  const o = C.occurrences(C.parseEvent(old.entries[1].id, phone), -Infinity, Infinity)[0];
  const [edited] = C.update({ ...phone, futurePart: { kept: true } }, o.start, { ...C.draftFor(o, phone, D), title: "Office hours", reminderMinutes: 10 }, "all", now, D);
  const editedIndex = seal(edited, { title: "Office hours", notes: "Bring outline", reminderMinutes: 10, updatedAt: C.toApple(now) });

  // 6. Both edited: the website's newer change stays, the phone's version is kept as a copy.
  const mine = edited;
  const theirs = items[phoneIndex];
  const r = C.resolve(mine, phone, items[editedIndex].hash, theirs.hash, now);
  const conflicts = [{ mine: editedIndex, theirs: phoneIndex, keep: r.keep, copyID: r.copy ? String(r.copy.id) : null }];
  // ...and the other way round, the phone's (older) copy as "mine": the newer website edit wins.
  const r2 = C.resolve(phone, mine, theirs.hash, items[editedIndex].hash, now);
  conflicts.push({ mine: phoneIndex, theirs: editedIndex, keep: r2.keep, copyID: r2.copy ? String(r2.copy.id) : null });

  return { note: "Made by web/site/test/make-calendar-vectors.mjs from the website's own code. Test key only.", rootKey: old.rootKey, items, conflicts };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync("../../docs/calendar-web-vectors.json", JSON.stringify(makeWebVectors(), null, 2) + "\n");
  console.log("wrote docs/calendar-web-vectors.json");
}
