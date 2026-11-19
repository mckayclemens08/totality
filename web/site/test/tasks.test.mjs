import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { build } from "esbuild";

for (const [n, e] of [["sealed", "src/sealed.ts"], ["tasks", "src/tasks/model.ts"], ["protocol", "src/pairing/protocol.ts"]])
  await build({ entryPoints: [e], bundle: true, format: "esm", outfile: `dist-test/${n}.mjs`, platform: "node", logLevel: "silent" });
const S = await import("../dist-test/sealed.mjs"), T = await import("../dist-test/tasks.mjs"), P = await import("../dist-test/protocol.mjs");
const v = JSON.parse(readFileSync("../../docs/tasks-vectors.json", "utf8"));
const root = P.fromHex(v.rootKey, 32);
const purpose = { task: "task", task_list: "task-list" };
const open = (e) => JSON.parse(new TextDecoder().decode(S.openBlob(Uint8Array.from(Buffer.from(e.meta, "base64")), S.objectKeyFromRoot(root, purpose[e.kind], e.id), e.id)));
const today = { year: 2026, month: 11, day: 18 };

test("the browser opens tasks and lists the real TaskVault sealed", () => {
  const tasks = v.entries.filter((e) => e.kind === "task").map((e) => T.parseTask(e.id, open(e)));
  const lists = v.entries.filter((e) => e.kind === "task_list").map((e) => T.parseList(e.id, open(e)));
  assert.equal(tasks.length, 3); assert.equal(lists.length, 1);
  assert.deepEqual(tasks.map((t) => t.title), v.entries.filter((e) => e.kind === "task").map((e) => e.title));
  const hegel = tasks[0];
  assert.deepEqual([hegel.time, hegel.priority, hegel.checklist.length, hegel.checklist[0].done, hegel.listID], [{ hour: 14, minute: 0 }, 3, 2, true, lists[0].id]);
  assert.equal(lists[0].name, "School");
  assert.equal(lists[0].kind, "area");
  const first = v.entries[0];
  assert.throws(() => S.openBlob(Uint8Array.from(Buffer.from(first.meta, "base64")), S.objectKeyFromRoot(root, "task-list", first.id), first.id), "purposes are separate");
});

test("buckets follow TaskRules, and areas hold their tasks", () => {
  const tasks = v.entries.filter((e) => e.kind === "task").map((e) => T.parseTask(e.id, open(e)));
  const lists = v.entries.filter((e) => e.kind === "task_list").map((e) => T.parseList(e.id, open(e)));
  assert.deepEqual(tasks.map((t) => T.bucketOf(t, today)), ["today", "someday", "logbook"]);
  assert.deepEqual(T.inBucket(tasks, "today", today).map((t) => t.title), ["Finish Hegel paper, section 2"]);
  assert.deepEqual(T.inBucket(tasks, "today", { year: 2026, month: 11, day: 17 }), [], "not due yet");
  assert.equal(T.bucketOf(tasks[0], { year: 2026, month: 11, day: 17 }), "upcoming");
  assert.deepEqual(T.inList(tasks, lists, lists[0].id).map((t) => t.title), ["Finish Hegel paper, section 2"]);
  assert.equal(T.bucketOf({ ...tasks[1], deadline: { year: 2026, month: 11, day: 1 }, place: "someday" }, today), "today", "an overdue deadline lands in Today");
});

test("times and days read well", () => {
  assert.equal(T.timeText({ hour: 14, minute: 0 }), "2 pm");
  assert.equal(T.timeText({ hour: 0, minute: 5 }), "12:05 am");
  assert.equal(T.dayText(today, today), "Today");
  assert.equal(T.dayText({ year: 2026, month: 11, day: 19 }, today), "Tomorrow");
});
