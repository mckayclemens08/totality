// Website editing for Calendar, checked against the real Swift model both ways.
// docs/calendar-edit-vectors.json: the iPhone's answers (CalendarModel and CalendarVault), which this code must give too.
// docs/calendar-web-vectors.json: what this code writes, which Swift's CalendarVault opens (CalendarWebEditVectorsTests).
process.env.TZ = "America/Denver";
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const { makeWebVectors } = await import("./make-calendar-vectors.mjs");
const C = await import("../dist-test/calendar-support.mjs");

const v = JSON.parse(readFileSync("../../docs/calendar-edit-vectors.json", "utf8"));
const D = v.display;
const now = C.fromApple(v.now);
const ms = (s) => C.fromApple(s);
const toDraft = (j) => ({
  title: j.title, location: j.location, notes: j.notes, start: ms(j.start), end: ms(j.end), isAllDay: j.isAllDay,
  frequency: j.frequency ?? null, until: j.until ?? null, reminderMinutes: j.reminderMinutes ?? null, attachments: [],
});
const fromDraft = (d) => {
  const o = { title: d.title, location: d.location, notes: d.notes, start: C.toApple(d.start), end: C.toApple(d.end), isAllDay: d.isAllDay };
  if (d.frequency) o.frequency = d.frequency;
  if (d.until) o.until = d.until;
  if (d.reminderMinutes !== null) o.reminderMinutes = d.reminderMinutes;
  return o;
};
const noID = ({ id, ...rest }) => ({ ...rest, skipped: [...(rest.skipped ?? [])].sort((a, b) => a - b) });
const order = (a, b) => a.start - b.start || (a.title < b.title ? -1 : a.title > b.title ? 1 : 0);

test("creating, editing this one or all of them, and deleting give the iPhone's events", () => {
  assert.ok(v.cases.length >= 12);
  for (const c of v.cases) {
    const events = [];
    for (const step of c.steps) {
      let notice = null, saved = true;
      try {
        if (step.op === "create") events.push(C.create(toDraft(step.draft), now, D));
        else {
          const start = ms(step.occurrenceStart);
          const i = events.findIndex((e) => C.occurrences(C.parseEvent(String(e.id).toLowerCase(), e), start - 1, start + 1).some((o) => o.start === start));
          assert.ok(i >= 0, `${c.name}: no event has an occurrence at ${step.occurrenceStart}`);
          const e = events[i];
          if (step.op === "update") {
            const occ = C.occurrences(C.parseEvent(String(e.id).toLowerCase(), e), start - 1, start + 1).find((o) => o.start === start);
            assert.deepEqual(fromDraft(C.draftFor(occ, e, D)), step.draftFor, `${c.name}: the form opens with what the iPhone shows`);
            const out = C.update(e, start, toDraft(step.draft), step.scope, now, D);
            events.splice(i, 1, ...out.slice(-1));
            if (out.length === 2) events.push(out[0]);
          } else {
            const r = C.remove(e, start, step.scope, now);
            if ("save" in r) events[i] = r.save; else events.splice(i, 1);
          }
        }
      } catch (err) {
        if (!(err instanceof C.DraftProblem)) throw err;
        notice = err.message; saved = false;
      }
      if ("saved" in step) assert.equal(saved, step.saved, `${c.name}: saved`);
      assert.equal(notice, step.notice ?? null, `${c.name}: what the person is told`);
    }
    assert.deepEqual(events.sort(order).map(noID), v.cases.find((x) => x === c).events.map(noID), c.name);
  }
});

test("occurrences match CalendarEvent.occurrences", () => {
  for (const o of v.occurrences) {
    const e = C.parseEvent(o.event.id.toLowerCase(), o.event);
    assert.deepEqual(C.occurrencesBetween(e, o.from, o.through, D).map((x) => C.toApple(x.start)), o.starts, o.event.title);
  }
});

test("conflicts keep the newer and copy the older, as CalendarVault does", () => {
  for (const c of v.conflicts) {
    const r = C.resolve(c.mine, c.theirs, c.mineHash, c.theirsHash, now);
    assert.equal(r.keep, c.keep);
    if (!c.copy) { assert.equal(r.copy, null); continue; }
    const strip = ({ createdAt, updatedAt, ...rest }) => ({ ...rest, skipped: [...rest.skipped].sort() });
    assert.deepEqual(strip(r.copy), strip(c.copy));
  }
});

test("the copy's ID is UUID(derivedFrom:)", () => {
  const c = v.conflicts.find((x) => x.copy);
  assert.equal(C.derivedID(c.keep === "mine" ? c.theirsHash : c.mineHash), c.copy.id);
});

test("the committed website vectors are what this code writes now", () => {
  assert.deepEqual(JSON.parse(readFileSync("../../docs/calendar-web-vectors.json", "utf8")), JSON.parse(JSON.stringify(makeWebVectors())));
});

test("the times a person types come back the same", () => {
  for (const s of [813_769_200, 813_769_200.5, 0, -86_400]) assert.equal(C.toApple(C.fromApple(s)), s);
});
