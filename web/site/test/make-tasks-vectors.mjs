// Makes docs/tasks-web-vectors.json with the website's own code: tasks and lists written the way the
// website writes them, sealed the way it seals them. Swift's TasksWebEditVectorsTests opens every one in
// the real TaskVault. Run `npm run vectors` after changing how the website writes tasks.
// Nonces and IDs are fixed, so the same code makes the same bytes and the test can tell the file is current.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

process.env.TZ = "America/Denver";
await build({ entryPoints: ["test/support/tasks.ts"], bundle: true, format: "esm", outfile: "dist-test/tasks-support.mjs", platform: "node", logLevel: "silent" });
const T = await import("../dist-test/tasks-support.mjs");

export function makeWebVectors() {
  const model = JSON.parse(readFileSync("../../docs/tasks-edit-vectors.json", "utf8"));
  const root = T.fromHex(model.rootKey, 32);
  let n = 0;
  T.setIDMaker(() => `C0FFEE00-0000-4000-8000-${String(++n).padStart(12, "0")}`);
  const items = [];
  const seal = (kind, json, expect) => {
    const id = String(json.id).toLowerCase();
    const nonce = new Uint8Array(24).fill(items.length + 1);
    const meta = T.sealBlob(new TextEncoder().encode(JSON.stringify(json)), T.objectKeyFromRoot(root, kind === "task" ? "task" : "task-list", id), id, nonce);
    items.push({ id, kind, meta: Buffer.from(meta).toString("base64"), hash: T.metaOnlyHash(meta), expect });
  };
  const at = 785_100_000; // seconds since 2001, after every Swift-made time
  const cal = { firstWeekday: 1 };
  const today = { year: 2026, month: 11, day: 18 };

  // 1. Quick add, with every part it understands.
  const parsed = T.parseLines("Book campsite sat 4pm #trail-crew !high", { today, firstWeekday: 1, monthFirst: true })[0];
  const added = T.newTask({ ...T.taskFields(parsed, "inbox", null), id: "C0FFEE00-0000-4000-8000-0000000000A1", order: 3 }, at);
  seal("task", added, { title: "Book campsite sat", when: "2026-11-18", time: "16:0", tags: "trail-crew", priority: "3", place: "anytime", done: "false", edited: "" });

  // 2. The phone's richest task, edited on the website in every part. Its unknown "futurePart" stays.
  const rich = JSON.parse(new TextDecoder().decode(T.openBlob(Buffer.from(model.tasks[0].meta, "base64"), T.objectKeyFromRoot(root, "task", model.tasks[0].id), model.tasks[0].id)));
  seal("task", rich, { title: rich.title });
  const project = "A0000000-0000-4000-8000-0000000000B2", heading = "A0000000-0000-4000-8000-0000000000B3";
  const edited = T.change(rich, at, (t) => {
    t.title = "Water the garden boxes before work";
    t.notes = "Both boxes.\n\n- basil\n- **tomatoes**";
    t.checklist = [{ ...t.checklist[0], isDone: false }, { ...t.checklist[1], isDone: true }, { id: T.newID(), title: "Check the drip line", isDone: false }];
    t.tags = ["home"]; t.priority = 3; t.listID = project; t.headingID = heading; t.order = 1.5;
    t.when = { year: 2026, month: 11, day: 19 }; t.isEvening = true; delete t.time; t.blockMinutes = 30;
    t.deadline = { year: 2026, month: 11, day: 27 }; t.deadlineTime = { hour: 9, minute: 45 };
    const rule = T.newRule("monthly", { year: 2026, month: 11, day: 27 });
    rule.monthWeekday = { ordinal: -1, weekday: 6 }; rule.end = { on: { _0: { year: 2027, month: 6, day: 30 } } };
    t.repeatRule = T.encodeRule(rule);
    t.reminders = [{ id: T.newID(), kind: { at: { _0: { year: 2026, month: 11, day: 19 }, _1: { hour: 18, minute: 0 } } } },
      { id: T.newID(), kind: { beforeDeadline: { _0: "morningOf" } } },
      { id: T.newID(), kind: { place: { _0: { name: "Garden", latitude: 40.1, longitude: -111.6, radius: 500, onArrival: true } } } }];
    t.nagging = { everyMinutes: 30, giveUp: { midnight: {} } };
    t.snoozedUntil = at + 900;
    delete t.source;
  });
  seal("task", edited, {
    title: "Water the garden boxes before work", notes: "Both boxes.\n\n- basil\n- **tomatoes**", steps: "Front|Back+|Check the drip line", tags: "home", priority: "3",
    list: project.toLowerCase(), heading: heading.toLowerCase(), when: "2026-11-19", evening: "true", time: "", block: "30", deadline: "2026-11-27", deadlineTime: "9:45",
    repeat: "Monthly on the last Friday", repeatEnd: "on(TotalityTasks.TaskDay(year: 2027, month: 6, day: 30))", repeatDone: "0",
    reminders: 'at(TotalityTasks.TaskDay(year: 2026, month: 11, day: 19), TotalityTasks.TaskTime(hour: 18, minute: 0))|beforeDeadline(TotalityTasks.TaskReminder.DeadlineOffset.morningOf)|place(TotalityTasks.ReminderPlace(name: "Garden", latitude: 40.1, longitude: -111.6, radius: 500.0, onArrival: true))',
    nagging: "30/midnight", snoozed: String(at + 900), source: "",
    edited: "checklist,deadline,futurePart,link,list,notes,order,priority,reminders,repeating,schedule,snooze,tags,title", unknownKept: "yes",
  });

  // 3. A title-only edit, later, for the phone to merge with its own change to the priority.
  const renamed = T.change(rich, at + 600, (t) => { t.title = "Water the boxes (web)"; });
  seal("task", renamed, { title: "Water the boxes (web)", priority: "2", mergeBase: rich.id.toLowerCase() });

  // 4. Ticked off: the finished task, and the next copy the repeat leaves.
  const doneAt = T.fromApple(at);
  const next = T.following(rich, doneAt, cal);
  const finished = T.change(rich, at, (t) => { t.completedAt = at; delete t.snoozedUntil; if (next) delete t.repeatRule; });
  seal("task", finished, { done: "true", repeat: "", snoozed: "" });
  seal("task", next, { done: "false", when: "2026-11-19", repeatDone: "2", steps: "Front|Back", title: rich.title });

  // 5. Lists: an area, a project in it with headings and a deadline, a pinned smart list with rules.
  const area = { id: "A0000000-0000-4000-8000-0000000000B1", name: "Home", kind: "area", headings: [], status: "active", isPinned: false, order: 2, createdAt: at, updatedAt: at };
  seal("task_list", area, { name: "Home", kind: "area" });
  const proj = { id: project, name: "Garden boxes", kind: "project", areaID: area.id, headings: [{ id: heading, title: "Planting" }, { id: T.newID(), title: "Watering" }],
    deadline: { year: 2026, month: 12, day: 1 }, status: "someday", isPinned: false, order: 1, createdAt: at, updatedAt: at + 5 };
  seal("task_list", proj, { name: "Garden boxes", kind: "project", headings: "Planting|Watering", area: area.id.toLowerCase(), status: "someday", deadline: "2026-12-1" });
  const smart = { id: "A0000000-0000-4000-8000-0000000000B4", name: "Urgent at home", kind: "smart", headings: [], status: "active", isPinned: true, order: 1, createdAt: at, updatedAt: at,
    rules: { match: "all", rules: [{ id: T.newID(), kind: "area", isNegated: false, listID: area.id }, { id: T.newID(), kind: "deadline", isNegated: false, days: 3 }, { id: T.newID(), kind: "tag", isNegated: true, tag: "someday" }] } };
  seal("task_list", smart, { name: "Urgent at home", kind: "smart", pinned: "true", rules: "all:area=,deadline=3,tag!=someday" });

  return { note: "Made by web/site/test/make-tasks-vectors.mjs from the website's own code. Test key only.", rootKey: model.rootKey, items };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync("../../docs/tasks-web-vectors.json", JSON.stringify(makeWebVectors(), null, 2) + "\n");
  console.log("wrote docs/tasks-web-vectors.json");
}
