// Website editing for Tasks, checked against the real Swift model both ways (issue 150).
// docs/tasks-edit-vectors.json: the iPhone's answers, which this code must give too.
// docs/tasks-web-vectors.json: what this code writes, which Swift's TaskVault opens (TasksWebEditVectorsTests).
process.env.TZ = "America/Denver";
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const { makeWebVectors } = await import("./make-tasks-vectors.mjs");
const T = await import("../dist-test/tasks-support.mjs");

const v = JSON.parse(readFileSync("../../docs/tasks-edit-vectors.json", "utf8"));
const root = T.fromHex(v.rootKey, 32);
const cal = { firstWeekday: 1 };

const stripStepIDs = (t) => ({ ...t, checklist: (t.checklist ?? []).map(({ id, ...rest }) => rest) });

test("the browser opens the phone's richest task and lists", () => {
  for (const e of v.tasks) {
    const json = JSON.parse(new TextDecoder().decode(T.openBlob(Buffer.from(e.meta, "base64"), T.objectKeyFromRoot(root, e.kind === "task" ? "task" : "task-list", e.id), e.id)));
    if (e.kind === "task") {
      const t = T.parseTask(e.id, json);
      assert.equal(t.title, "Water the garden boxes");
      assert.deepEqual([t.deadlineTime, t.blockMinutes, t.reminderCount, t.hasNagging, t.repeats, t.source.title], [{ hour: 17, minute: 0 }, 45, 3, true, true, "Garden notes"]);
      assert.equal(T.parseRule(json.repeatRule).kind, "custom");
    } else {
      const l = T.parseList(e.id, json);
      assert.equal(l.name, e.expect.name);
      if (l.kind === "project") assert.deepEqual(l.headings.map((x) => x.title), ["Research", "Drafting"]);
      if (l.kind === "smart") { assert.equal(l.isPinned, true); assert.deepEqual(T.parseRules(json.rules).rules.map((r) => r.kind), ["deadline", "tag", "priority"]); }
    }
  }
});

test("repeat dates and words match RepeatRule", () => {
  assert.ok(v.repeats.length > 40);
  for (const c of v.repeats) {
    const rule = T.parseRule(JSON.parse(c.rule));
    assert.deepEqual(T.encodeRule(rule), JSON.parse(c.rule), "the rule round-trips byte for byte in shape");
    assert.deepEqual(T.nextDay(rule, c.after, c.completed ?? null, cal), c.next ?? null, `${c.rule} after ${JSON.stringify(c.after)}`);
    assert.equal(T.summary(rule, cal), c.summary);
  }
});

test("ticking off a repeating task leaves the same next copy the phone makes", () => {
  for (const c of v.copies) {
    const got = T.following(JSON.parse(c.task), T.fromApple(c.completedAt), cal);
    if (!c.result) { assert.equal(got, null); continue; }
    assert.equal(got.id, c.followingID, "the same ID, so two devices make one copy");
    assert.equal(T.canon(stripStepIDs(got)), T.canon(stripStepIDs(JSON.parse(c.result))));
  }
  for (const c of v.skips) {
    const got = T.skippingNext(JSON.parse(c.task), cal);
    assert.equal(got && T.canon(got), c.result && T.canon(JSON.parse(c.result)));
  }
});

test("quick add reads a line the way QuickAddParser does", () => {
  const ctx = { today: T.localDay(T.fromApple(v.now)), firstWeekday: 1, monthFirst: true };
  for (const c of v.quickAdd) {
    const [p] = T.parseLines(c.text, ctx);
    const source = c.text.startsWith("- [ ] ") ? c.text.slice(6) : c.text;
    assert.deepEqual({ title: p.title, when: p.when, evening: p.isEvening, time: p.time && `${p.time.hour}:${p.time.minute}`, deadline: p.deadline, tags: p.tags, priority: p.priority, place: p.place, pieces: p.pieces.map((x) => `${x.part}:${source.slice(x.start, x.end)}`) },
      { title: c.title, when: c.when ?? null, evening: c.evening, time: c.time ?? null, deadline: c.deadline ?? null, tags: c.tags, priority: c.priority, place: c.place ?? null, pieces: c.pieces }, c.text);
  }
});

test("an edit stamps exactly the parts TaskItem.noteChanges stamps", () => {
  for (const c of v.edits) {
    const got = T.noteChanges(JSON.parse(c.new), JSON.parse(c.old), c.at);
    assert.equal(T.canon(got), T.canon(JSON.parse(c.result)));
  }
});

test("a change made from an old copy keeps what another device changed meanwhile", () => {
  const base = JSON.parse(v.edits[0].old);
  const phone = T.change(base, 785_000_500, (t) => { t.priority = 1; });
  const mine = T.change(base, 785_000_400, (t) => { t.title = "From the website"; });
  const saved = T.applying(phone, mine, base, 785_000_600);
  assert.deepEqual([saved.title, saved.priority, saved.edits.title, saved.edits.priority], ["From the website", 1, 785_000_600, 785_000_500]);
});

test("smart lists find what ListRules finds", () => {
  const lists = [{ id: "a", kind: "area", areaID: null }, { id: "p", kind: "project", areaID: "a" }];
  const base = { completedAt: null, tags: [], notes: "", priority: 0, when: null, deadline: null, order: 0, createdAt: 0, listID: null };
  const tasks = [
    { ...base, id: "1", listID: "p", deadline: { year: 2026, month: 11, day: 20 }, tags: ["School/Thesis"] },
    { ...base, id: "2", listID: "a", tags: ["someday"] },
    { ...base, id: "3", deadline: { year: 2026, month: 11, day: 10 }, notes: "x" },
  ];
  const today = { year: 2026, month: 11, day: 18 };
  const find = (rules) => T.smartTasks(T.parseRules(rules), tasks, lists, today).map((t) => t.id);
  assert.deepEqual(find({ match: "all", rules: [{ id: "r", kind: "area", listID: "A" }] }), ["1", "2"]);
  assert.deepEqual(find({ match: "all", rules: [{ id: "r", kind: "tag", tag: "#school" }] }), ["1"]);
  assert.deepEqual(find({ match: "any", rules: [{ id: "r", kind: "deadline", days: 2 }, { id: "s", kind: "hasNote" }] }), ["3", "1"]);
  assert.deepEqual(find({ match: "all", rules: [{ id: "r", kind: "tag", tag: "someday", isNegated: true }, { id: "s", kind: "future" }] }), []);
  assert.deepEqual(find({ match: "all", rules: [] }), [], "no rules find nothing");
});

test("the committed website vectors are what this code writes now", () => {
  assert.deepEqual(makeWebVectors(), JSON.parse(readFileSync("../../docs/tasks-web-vectors.json", "utf8")));
});

test("sealing matches ContentCipher and the row hash matches SealedObject.hash", () => {
  const id = "6f1c3a52-0b7e-4d1a-9c33-2e5b8a1d4f60", key = T.objectKeyFromRoot(root, "task", id);
  const sealed = T.sealBlob(new TextEncoder().encode("{}"), key, id);
  assert.equal(sealed[0], 1);
  assert.equal(new TextDecoder().decode(T.openBlob(sealed, key, id)), "{}");
  assert.throws(() => T.openBlob(sealed, key, "6f1c3a52-0b7e-4d1a-9c33-2e5b8a1d4f61"), "bound to its ID");
  assert.match(T.metaOnlyHash(sealed), /^[0-9a-f]{64}$/);
});
