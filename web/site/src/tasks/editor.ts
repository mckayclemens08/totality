// The task details pane: every part the iPhone's task screen edits. Text saves as you type; everything else
// saves on the change. Each control edits only its own part of the store's current copy, so a sync that
// lands meanwhile is never undone.
import { h } from "../dom";
import { dayText, timeText, type Task } from "./model";
import { newID, type Raw } from "./edit";
import { addDays, encodeRule, newRule, parseRule, summary, upcoming, weekday, type Day, type Kind, type Rule, type Unit } from "./repeat";
import { localToday, type TasksStore } from "./store";
import { dayFrom, dayValue, field, input, onSettled, select, seg, sheet, timeFrom, timeValue } from "./ui";

const PRIORITIES: [string, string][] = [["0", "None"], ["1", "Low"], ["2", "Medium"], ["3", "High"]];
const WEEKDAY_SHORT = ["S", "M", "T", "W", "T", "F", "S"];
const WEEKDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const OFFSETS: [string, string][] = [["hour", "1 hour before"], ["day", "1 day before"], ["morningOf", "Morning of"]];
const RADII: [string, string][] = [["100", "100 m"], ["200", "200 m"], ["500", "500 m"]];
const NAG_EVERY: [string, string][] = [["0", "Don't"], ["5", "5 minutes"], ["10", "10 minutes"], ["15", "15 minutes"], ["30", "30 minutes"], ["60", "1 hour"]];

const isDay = (v: unknown): v is Day => !!v && typeof (v as Day).year === "number";

function reminderText(r: Raw, t: Raw): string {
  const k = r.kind as Raw | undefined;
  const at = k?.at as { _0?: Day; _1?: { hour: number; minute: number } } | undefined;
  if (at?._0 && at._1) return `${dayText(at._0, localToday())}, ${timeText(at._1)}`;
  const off = (k?.beforeDeadline as { _0?: string } | undefined)?._0;
  if (off) return (OFFSETS.find((o) => o[0] === off)?.[1] ?? "Before the deadline") + (t.deadline ? "" : " (needs a deadline)");
  const place = (k?.place as { _0?: { name?: string; onArrival?: boolean } } | undefined)?._0;
  if (place) return `${place.onArrival === false ? "Leaving" : "Arriving at"} ${place.name || "a place"}`;
  return "A reminder from a newer version";
}

export function renderEditor(host: HTMLElement, store: TasksStore, task: Task, lists: { areas: { id: string; name: string }[]; projects: { id: string; name: string; headings: { id: string; title: string }[] }[] }): void {
  const id = task.id;
  const raw = () => store.raw(id) ?? {};
  const set = (edit: (t: Raw) => void) => void store.changeTask(id, edit);

  const title = input({ class: "title-field", "aria-label": "Title", value: task.title, placeholder: "New task" });
  onSettled(title, (v) => set((t) => { t.title = v; }));
  const notes = h("textarea", { class: "notes-field", rows: "4", "aria-label": "Notes", placeholder: "Notes" });
  notes.value = task.notes;
  onSettled(notes, (v) => set((t) => { t.notes = v; }));

  // Steps
  const steps = h("div", { class: "steps" });
  const checklist = ((raw().checklist as Raw[] | undefined) ?? []);
  checklist.forEach((c, i) => {
    const text = input({ "aria-label": "Step", value: String(c.title ?? "") });
    onSettled(text, (v) => set((t) => { const list = t.checklist as Raw[]; if (list[i]) list[i]!.title = v; }));
    const done = c.isDone === true;
    steps.append(h("div", { class: "step-edit" },
      h("button", { type: "button", class: "circle-btn" + (done ? " done" : ""), "aria-label": done ? "Mark step not done" : "Mark step done", onclick: () => set((t) => { const list = t.checklist as Raw[]; if (list[i]) list[i]!.isDone = !done; }) }, done ? "✓" : ""),
      text, h("button", { type: "button", class: "icon-btn", "aria-label": `Remove step ${String(c.title ?? "")}`, onclick: () => set((t) => { (t.checklist as Raw[]).splice(i, 1); }) }, "×")));
  });
  const newStep = input({ "aria-label": "Add a step", placeholder: "Add a step" });
  newStep.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key !== "Enter" || !newStep.value.trim()) return;
    const value = newStep.value.trim();
    newStep.value = "";
    set((t) => { t.checklist = [...((t.checklist as Raw[]) ?? []), { id: newID(), title: value, isDone: false }]; });
  });
  steps.append(newStep);

  // Schedule, deadline, repeat, reminders, snooze
  const when = task.when ? dayText(task.when, localToday()) + (task.time ? ` · ${timeText(task.time)}` : task.isEvening ? " · evening" : "") + (task.blockMinutes ? ` · ${task.blockMinutes} min` : "") : task.place === "someday" ? "Someday" : task.place === "anytime" ? "Anytime" : "Inbox";
  const deadline = task.deadline ? dayText(task.deadline, localToday()) + (task.deadlineTime ? ` · ${timeText(task.deadlineTime)}` : "") : "None";
  const rule = parseRule(raw().repeatRule);
  const reminders = (raw().reminders as Raw[] | undefined) ?? [];
  const nag = raw().nagging as { everyMinutes?: number } | undefined;
  const snoozed = task.snoozedUntil && task.snoozedUntil > Date.now() ? new Date(task.snoozedUntil).toLocaleString(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" }) : null;
  const pick = (label: string, value: string, open: () => void) => field(label, h("button", { type: "button", class: "quiet pick", onclick: open }, value));

  // Tags
  const tags = h("div", { class: "chips" }, ...task.tags.map((tag) => h("span", { class: "chip big" }, tag,
    h("button", { type: "button", class: "chip-x", "aria-label": `Remove tag ${tag}`, onclick: () => set((t) => { t.tags = (t.tags as string[]).filter((x) => x !== tag); }) }, "×"))));
  const tagInput = input({ "aria-label": "Type a tag", placeholder: "Type a tag…", class: "tag-input" });
  tagInput.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key !== "Enter") return;
    const v = tagInput.value; tagInput.value = "";
    void store.addTag(v, [id]);
  });
  tags.append(tagInput);

  // List and heading
  const listValue = task.listID ? (task.headingID ? `${task.listID}/${task.headingID}` : task.listID) : "";
  const listOptions: [string, string][] = [["", "No list"]];
  for (const a of lists.areas) listOptions.push([a.id, a.name]);
  for (const p of lists.projects) { listOptions.push([p.id, p.name]); for (const hd of p.headings) listOptions.push([`${p.id}/${hd.id}`, `${p.name} › ${hd.title}`]); }
  const listSelect = select(listOptions, listValue, { "aria-label": "List" });
  listSelect.addEventListener("change", () => {
    const [list, heading] = listSelect.value.split("/");
    if (!list) void store.move([id], { bucket: task.place === "inbox" ? "inbox" : "anytime" }).then(() => set((t) => { delete t.listID; delete t.headingID; }));
    else void store.move([id], { list, heading: heading ?? null });
  });
  const priority = select(PRIORITIES, String(task.priority), { "aria-label": "Priority" });
  priority.addEventListener("change", () => set((t) => { t.priority = Number(priority.value); }));

  host.replaceChildren(
    title,
    field("Notes", notes),
    h("div", { class: "field-label" }, "Steps"), steps,
    h("div", { class: "grid2" },
      pick("Schedule", when, () => scheduleSheet(store, id)),
      pick("Deadline", deadline, () => deadlineSheet(store, id)),
      pick("Repeats", rule ? summary(rule, store.cal) : "Never", () => repeatSheet(store, id)),
      pick("Reminders", reminders.length ? reminders.map((r) => reminderText(r, raw())).join("; ") + (nag?.everyMinutes ? ` · again every ${nag.everyMinutes} min` : "") : "None", () => reminderSheet(store, id)),
      field("Priority", priority), field("List", listSelect),
      pick("Snooze", snoozed ? `Until ${snoozed}` : "Not snoozed", () => snoozeSheet(store, id))),
    h("div", { class: "field-label" }, "Tags"), tags,
    ...(task.source ? [h("div", { class: "field-label" }, "Linked"), h("div", { class: "chips" }, h("span", { class: "chip big" }, `${task.source.module ? task.source.module[0]!.toUpperCase() + task.source.module.slice(1) + ": " : ""}${task.source.title}`),
      h("button", { type: "button", class: "quiet small-btn", onclick: () => set((t) => { delete t.source; }) }, "Remove the link"))] : []),
    h("div", { class: "editor-foot" }, h("span", { class: "sub" }, "Sealed in this browser before it saves."),
      h("button", { type: "button", class: "quiet small-btn danger", onclick: () => void store.delete([id]) }, "Delete task")),
  );
}

// ---- sheets ----

export function scheduleSheet(store: TasksStore, id: string): void {
  const t = store.raw(id) ?? {};
  const today = localToday();
  const date = input({ type: "date", value: dayValue(isDay(t.when) ? t.when : null), "aria-label": "Day" });
  const time = input({ type: "time", value: timeValue(t.time as { hour: number; minute: number } | undefined), "aria-label": "Time" });
  const evening = input({ type: "checkbox", class: "switch", "aria-label": "In the evening" }); evening.checked = t.isEvening === true;
  const block = select([["", "None"], ["15", "15 min"], ["30", "30 min"], ["45", "45 min"], ["60", "1 hour"], ["90", "1½ hours"], ["120", "2 hours"]], String(t.blockMinutes ?? ""), { "aria-label": "Time block" });
  const choose = (choice: Parameters<TasksStore["schedule"]>[1]) => { void store.schedule(id, choice); d.close(); };
  const d = sheet("Schedule", [
    h("div", { class: "segs wrap" },
      seg("Today", false, () => choose({ day: today, evening: false })), seg("This evening", false, () => choose({ day: today, evening: true })),
      seg("Tomorrow", false, () => choose({ day: addDays(today, 1), evening: false })),
      seg("Anytime", t.place === "anytime" && !t.when, () => choose("anytime")), seg("Someday", t.place === "someday", () => choose("someday"))),
    h("div", { class: "grid2" }, field("Pick a day", date), field("At a time", time), field("Time block", block), h("label", { class: "field row-field" }, evening, h("span", {}, "In the evening"))),
  ], [{ label: "Done", primary: true, run: async () => {
    const day = dayFrom(date.value);
    if (day) await store.schedule(id, { day, evening: evening.checked });
    await store.changeTask(id, (x) => {
      const tm = timeFrom(time.value);
      if (tm && x.when) x.time = tm; else delete x.time;
      if (block.value && x.time) x.blockMinutes = Number(block.value); else delete x.blockMinutes;
    });
  } }]);
}

export function deadlineSheet(store: TasksStore, id: string): void {
  const t = store.raw(id) ?? {};
  const date = input({ type: "date", value: dayValue(isDay(t.deadline) ? t.deadline : null), "aria-label": "Deadline" });
  const time = input({ type: "time", value: timeValue(t.deadlineTime as { hour: number; minute: number } | undefined), "aria-label": "Time on the deadline" });
  sheet("Deadline", [h("div", { class: "grid2" }, field("Day", date), field("Time (optional)", time)),
    h("button", { type: "button", class: "quiet small-btn", onclick: (e) => { void store.changeTask(id, (x) => { delete x.deadline; delete x.deadlineTime; }); (e.target as HTMLElement).closest("dialog")?.close(); } }, "Remove deadline")],
  [{ label: "Save", primary: true, run: () => store.changeTask(id, (x) => {
    const day = dayFrom(date.value), tm = timeFrom(time.value);
    if (day) x.deadline = day; else delete x.deadline;
    if (day && tm) x.deadlineTime = tm; else delete x.deadlineTime;
  }) }]);
}

export function snoozeSheet(store: TasksStore, id: string): void {
  sheet("Snooze", [h("p", { class: "sub" }, "Nothing rings for this task, reminders and nagging included, until then. Your iPhone does the ringing."),
    h("div", { class: "segs wrap" },
      h("button", { type: "button", class: "quiet", onclick: (e) => { void store.snooze(id, "15"); (e.target as HTMLElement).closest("dialog")?.close(); } }, "15 minutes"),
      h("button", { type: "button", class: "quiet", onclick: (e) => { void store.snooze(id, "tomorrow"); (e.target as HTMLElement).closest("dialog")?.close(); } }, "Tomorrow, 9 AM"),
      h("button", { type: "button", class: "quiet", onclick: (e) => { void store.snooze(id, "clear"); (e.target as HTMLElement).closest("dialog")?.close(); } }, "Stop snoozing"))]);
}

export function repeatSheet(store: TasksStore, id: string): void {
  const t = store.raw(id) ?? {};
  const anchor = (isDay(t.when) ? t.when : isDay(t.deadline) ? t.deadline : null) ?? localToday();
  let rule: Rule | null = parseRule(t.repeatRule);
  const body = h("div", { class: "stack" });
  const draw = () => {
    const kinds: [Kind | null, string][] = [[null, "Never"], ["daily", "Daily"], ["weekly", "Weekly"], ["monthly", "Monthly"], ["yearly", "Yearly"], ["afterFinish", "After I finish"], ["custom", "Custom"]];
    const parts: Node[] = [h("div", { class: "segs wrap", role: "group", "aria-label": "How it repeats" }, ...kinds.map(([k, name]) => seg(name, (rule?.kind ?? null) === k, () => {
      if (k === null) rule = null;
      else { const keep = rule; rule = newRule(k, keep?.start ?? anchor); if (keep) { rule.skipped = keep.skipped; rule.done = keep.done; rule.end = keep.end; } if (k === "custom" || k === "afterFinish") rule.customUnit = k === "custom" ? "week" : "day"; }
      draw();
    })))];
    if (rule) {
      const r = rule;
      const every = select(Array.from({ length: 30 }, (_, i): [string, string] => [String(i + 1), String(i + 1)]), String(r.interval), { "aria-label": "Every" });
      every.addEventListener("change", () => { r.interval = Number(every.value); draw(); });
      const unitPick = select([["day", "days"], ["week", "weeks"], ["month", "months"], ["year", "years"]], r.customUnit, { "aria-label": "Unit" });
      unitPick.addEventListener("change", () => { r.customUnit = unitPick.value as Unit; draw(); });
      parts.push(h("div", { class: "grid2" }, field("Every", every), ...(r.kind === "custom" || r.kind === "afterFinish" ? [field("Unit", unitPick)] : [])));
      const unit = r.kind === "custom" || r.kind === "afterFinish" ? r.customUnit : r.kind === "weekly" ? "week" : r.kind === "monthly" ? "month" : null;
      if (r.kind === "afterFinish") {
        parts.push(h("div", { class: "segs" }, seg("After I finish", r.countFrom === "completion", () => { r.countFrom = "completion"; draw(); }), seg("After the due date", r.countFrom === "dueDate", () => { r.countFrom = "dueDate"; draw(); })));
      } else if (unit === "week") {
        parts.push(field("On", h("div", { class: "segs", role: "group", "aria-label": "Weekdays" }, ...WEEKDAY_SHORT.map((s, i) => {
          const b = seg(s, r.weekdays.includes(i + 1), () => { r.weekdays = r.weekdays.includes(i + 1) ? r.weekdays.filter((x) => x !== i + 1) : [...r.weekdays, i + 1].sort(); draw(); });
          b.setAttribute("aria-label", WEEKDAY_NAMES[i]!); return b;
        }))));
      } else if (unit === "month") {
        const days = input({ "aria-label": "Days of the month", value: r.monthDays.map((d) => (d < 0 ? "last" : String(d))).join(", "), placeholder: `${r.start.day}` });
        days.addEventListener("change", () => { r.monthDays = days.value.split(/[,\s]+/).flatMap((x) => (x.toLowerCase() === "last" ? [-1] : /^\d+$/.test(x) && +x >= 1 && +x <= 31 ? [+x] : [])); delete r.monthWeekday; draw(); });
        const ord = select([["", "On days"], ["1", "First"], ["2", "Second"], ["3", "Third"], ["4", "Fourth"], ["-1", "Last"]], r.monthWeekday ? String(r.monthWeekday.ordinal) : "", { "aria-label": "Which" });
        const wd = select(WEEKDAY_NAMES.map((n, i): [string, string] => [String(i + 1), n]), String(r.monthWeekday?.weekday ?? weekday(r.start)), { "aria-label": "Weekday" });
        const setMW = () => { if (ord.value) { r.monthWeekday = { ordinal: Number(ord.value), weekday: Number(wd.value) }; r.monthDays = []; } else delete r.monthWeekday; draw(); };
        ord.addEventListener("change", setMW); wd.addEventListener("change", setMW);
        parts.push(h("div", { class: "grid2" }, field("Which", ord), r.monthWeekday ? field("Weekday", wd) : field("Days (1–31, or last)", days)));
      }
      const endKind = "on" in r.end ? "on" : "after" in r.end ? "after" : "never";
      const endPick = select([["never", "Never"], ["on", "On a day"], ["after", "After a number of times"]], endKind, { "aria-label": "Last day" });
      endPick.addEventListener("change", () => { r.end = endPick.value === "on" ? { on: { _0: anchor } } : endPick.value === "after" ? { after: { times: 10 } } : { never: {} }; draw(); });
      const endValue = "on" in r.end ? input({ type: "date", value: dayValue(r.end.on._0), "aria-label": "Last day" }) : "after" in r.end ? input({ type: "number", min: "1", max: "999", value: String(r.end.after.times), "aria-label": "How many times" }) : null;
      endValue?.addEventListener("change", () => {
        if ("on" in r.end) { const d = dayFrom(endValue.value); if (d) r.end = { on: { _0: d } }; } else if ("after" in r.end) r.end = { after: { times: Math.max(1, Number(endValue.value) || 1) } };
        draw();
      });
      parts.push(h("div", { class: "grid2" }, field("Ends", endPick), ...(endValue ? [field("on" in r.end ? "Last day" : "Times", endValue)] : [])));
      parts.push(h("p", { class: "sub" }, summary(r, store.cal)));
      if (t.repeatRule && r.kind !== "afterFinish") {
        const coming = upcoming(r, anchor, 6, store.cal);
        parts.push(h("div", { class: "field-label" }, "Coming up"), h("div", { class: "chips" }, ...coming.map((c) => h("button", { type: "button", class: "chip big" + (c.skipped ? " struck" : ""), "aria-pressed": c.skipped ? "true" : "false", onclick: () => {
          r.skipped = c.skipped ? r.skipped.filter((x) => !(x.year === c.day.year && x.month === c.day.month && x.day === c.day.day)) : [...r.skipped, c.day]; draw();
        } }, dayText(c.day, localToday())))),
        h("button", { type: "button", class: "quiet small-btn", onclick: (e) => { void store.skipNext(id); (e.target as HTMLElement).closest("dialog")?.close(); } }, "Skip the next one"));
      }
    }
    body.replaceChildren(...parts);
  };
  draw();
  sheet("Repeats", [body], [{ label: "Done", primary: true, run: () => store.changeTask(id, (x) => {
    if (!rule) { delete x.repeatRule; return; }
    x.repeatRule = encodeRule(rule);
    // TasksModel.setRepeat: a task with no day starts on the rule's first.
    if (!isDay(x.when) && !isDay(x.deadline)) { x.when = rule.start; if (x.place !== "anytime") x.place = "anytime"; }
  }) }]);
}

export function reminderSheet(store: TasksStore, id: string): void {
  const body = h("div", { class: "stack" });
  const draw = () => {
    const t = store.raw(id) ?? {};
    const list = (t.reminders as Raw[] | undefined) ?? [];
    const nag = t.nagging as { everyMinutes?: number; giveUp?: Raw } | undefined;
    const every = select(NAG_EVERY, String(nag?.everyMinutes ?? 0), { "aria-label": "Remind again every" });
    const hours = (nag?.giveUp?.afterHours as { _0?: number } | undefined)?._0;
    const giveUp = select([["midnight", "At midnight"], ["1", "After 1 hour"], ["2", "After 2 hours"], ["4", "After 4 hours"]], hours ? String(hours) : "midnight", { "aria-label": "Give up at" });
    const saveNag = () => void store.changeTask(id, (x) => {
      if (every.value === "0") { delete x.nagging; return; }
      x.nagging = { everyMinutes: Number(every.value), giveUp: giveUp.value === "midnight" ? { midnight: {} } : { afterHours: { _0: Number(giveUp.value) } } };
    }).then(draw);
    every.addEventListener("change", saveNag); giveUp.addEventListener("change", saveNag);

    const kind = select([["at", "At a time"], ["deadline", "Before the deadline"], ["place", "At a place"]], "at", { "aria-label": "Kind of reminder" });
    const adder = h("div", { class: "stack" });
    const drawAdder = () => {
      if (kind.value === "at") {
        const date = input({ type: "date", value: dayValue(localToday()), "aria-label": "Day" }), time = input({ type: "time", value: "09:00", "aria-label": "Time" });
        adder.replaceChildren(h("div", { class: "grid2" }, field("Day", date), field("Time", time)), add(() => { const d = dayFrom(date.value), tm = timeFrom(time.value); return d && tm ? { at: { _0: d, _1: tm } } : null; }));
      } else if (kind.value === "deadline") {
        const off = select(OFFSETS, "morningOf", { "aria-label": "When" });
        adder.replaceChildren(field("When", off), add(() => ({ beforeDeadline: { _0: off.value } })));
      } else {
        const name = input({ "aria-label": "Place name", placeholder: "Home" }), lat = input({ type: "number", step: "any", "aria-label": "Latitude", placeholder: "40.25" }), lon = input({ type: "number", step: "any", "aria-label": "Longitude", placeholder: "-111.65" });
        const radius = select(RADII, "200", { "aria-label": "Within" }), arrive = select([["1", "Arriving"], ["0", "Leaving"]], "1", { "aria-label": "Remind me when I'm" });
        adder.replaceChildren(field("Place", name), h("div", { class: "grid2" }, field("Latitude", lat), field("Longitude", lon), field("Within", radius), field("Remind me when I'm", arrive)),
          h("p", { class: "sub" }, "The place is sealed with the task. Your iPhone checks where you are; this browser never does."),
          add(() => {
            const la = Number(lat.value), lo = Number(lon.value);
            if (!lat.value || !lon.value || !(Math.abs(la) <= 90) || !(Math.abs(lo) <= 180)) return null;
            return { place: { _0: { name: name.value.trim() || "A place", latitude: la, longitude: lo, radius: Number(radius.value), onArrival: arrive.value === "1" } } };
          }));
      }
    };
    const add = (make: () => Raw | null) => h("button", { type: "button", class: "small-btn", onclick: () => { const k = make(); if (k) void store.changeTask(id, (x) => { x.reminders = [...((x.reminders as Raw[]) ?? []), { id: newID(), kind: k }]; }).then(draw); } }, "Add reminder");
    kind.addEventListener("change", drawAdder);
    drawAdder();
    body.replaceChildren(
      ...list.map((r) => h("div", { class: "step-edit" }, h("span", { class: "grow" }, reminderText(r, t)),
        h("button", { type: "button", class: "icon-btn", "aria-label": "Remove reminder", onclick: () => void store.changeTask(id, (x) => { x.reminders = ((x.reminders as Raw[]) ?? []).filter((y) => y.id !== r.id); }).then(draw) }, "×"))),
      ...(list.length ? [] : [h("p", { class: "sub" }, "No reminders yet.")]),
      field("New reminder", kind), adder,
      h("div", { class: "grid2" }, field("Remind again every", every), field("Give up", giveUp)),
      h("p", { class: "sub" }, "Reminders ring on your iPhone."));
  };
  draw();
  sheet("Reminders", [body]);
}

