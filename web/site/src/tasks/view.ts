// Tasks on the website, with the iPhone's editing: quick add, every part of a task, areas, projects with
// headings, smart lists with rules, moving and reordering by drag, several at once, and delete with Undo.
// Everything is sealed in this browser before it's saved (store.ts); this file only draws and asks.
import "./tasks.css";
import { h } from "../dom";
import type { Ctx } from "../reader/view";
import { dayText, inBucket, inList, timeText, type Bucket, type Task, type TaskList } from "./model";
import { parseRules, RULE_KINDS, smartTasks, type SmartRule } from "./rules";
import { parseLines } from "./quickadd";
import { appleNow, newID, type Raw } from "./edit";
import { renderEditor, scheduleSheet } from "./editor";
import { localToday, LINGER_MS, TasksStore, UNDO_MS, type Destination } from "./store";
import { dayFrom, dayValue, field, input, onSettled, plural, select, seg, sheet } from "../ui";

const BUCKETS: { id: Bucket; name: string }[] = [
  { id: "inbox", name: "Inbox" }, { id: "today", name: "Today" }, { id: "upcoming", name: "Upcoming" },
  { id: "anytime", name: "Anytime" }, { id: "someday", name: "Someday" }, { id: "logbook", name: "Logbook" },
];
const EMPTY: Record<Bucket, string> = {
  inbox: "Your Inbox is clear", today: "Nothing planned for today", upcoming: "Nothing coming up", anytime: "Nothing waiting", someday: "No parked ideas", logbook: "Nothing done yet",
};

let run = 0;
let cache: { ctx: Ctx; store: TasksStore } | null = null;
/** Leaving Tasks for good (another module, the lock, signing out) drops the opened tasks from memory. */
export const stopTasks = (): void => {
  const mine = ++run;
  setTimeout(() => {
    if (mine !== run || !cache) return;
    const store = cache.store;
    cache = null;
    void store.finishDelete();
  }, 0);
};

interface Ui { view: string; taskId: string | null; selecting: boolean; selected: Set<string>; lingering: Set<string>; done: { id: string; title: string; timer: ReturnType<typeof setTimeout> } | null }
const ui: Ui = { view: "today", taskId: null, selecting: false, selected: new Set(), lingering: new Set(), done: null };

export async function showTasks(into: HTMLElement, ctx: Ctx, view: string | null, taskId: string | null): Promise<void> {
  const mine = ++run;
  const status = h("span", { class: "save-status", role: "status", "aria-live": "polite" });
  const side = h("section", { class: "panel tasknav", "aria-label": "Lists" }, h("p", { class: "status" }, "Opening your tasks…"));
  const listHost = h("section", { class: "panel tasklist", "aria-label": "Tasks" });
  const detail = h("section", { class: "panel detail task-editor", "aria-label": "Task details" }, h("p", { class: "status" }, "Pick a task to see and change it here."));
  const toast = h("div", { class: "toast", role: "status", "aria-live": "polite", hidden: true });
  const selectBtn = h("button", { type: "button", class: "quiet small-btn" }, "Select several");
  const addBtn = h("button", { type: "button", class: "small-btn" }, "+ New task");
  const refresh = h("button", { type: "button", class: "quiet small-btn" }, "Refresh");
  into.replaceChildren(h("div", { class: "page-head tasks-head" }, h("h1", {}, "Tasks"), status, h("span", { class: "grow" }), refresh, selectBtn, addBtn),
    h("div", { class: "reader" }, side, listHost, detail), toast);

  if (!cache || cache.ctx !== ctx) {
    cache?.store.finishDelete();
    cache = { ctx, store: new TasksStore(ctx) };
    try { await cache.store.load(); } catch (e) {
      cache = null;
      if (mine === run) side.replaceChildren(h("p", { class: "status" }, e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your tasks. Check your connection and try again."));
      return;
    }
  }
  if (mine !== run) return;
  const store = cache.store;
  if (ui.view !== (view ?? "today")) { ui.selected.clear(); ui.selecting = false; }
  ui.view = view ?? "today";
  ui.taskId = taskId;
  const go = (v: string, id?: string | null) => { location.hash = `#/tasks/${v}${id ? "/" + id : ""}`; };

  store.onStatus = (text, ok) => { status.textContent = text; status.classList.toggle("bad", !ok); };
  let editorFor: string | null = null;
  store.onChange = () => { if (mine === run) draw(); };
  refresh.onclick = async () => { refresh.disabled = true; try { await store.load(); status.textContent = "Up to date"; } catch { status.textContent = "Couldn't refresh. Check your connection."; } refresh.disabled = false; draw(); };
  selectBtn.onclick = () => { ui.selecting = !ui.selecting; ui.selected.clear(); draw(); };

  function draw(): void {
    const today = localToday();
    const tasks = store.allTasks, lists = store.allLists;
    const byOrder = (a: TaskList, b: TaskList) => a.order - b.order || a.createdAt - b.createdAt;
    const areas = lists.filter((l) => l.kind === "area").sort(byOrder);
    const projects = lists.filter((l) => l.kind === "project").sort(byOrder);
    const smart = lists.filter((l) => l.kind === "smart").sort(byOrder);
    const current = lists.find((l) => l.id === ui.view) ?? null;
    const isBucket = BUCKETS.some((b) => b.id === ui.view);
    selectBtn.textContent = ui.selecting ? "Done selecting" : "Select several";
    selectBtn.setAttribute("aria-pressed", ui.selecting ? "true" : "false");
    addBtn.onclick = () => quickAdd(store, isBucket ? (ui.view as Bucket) : null, current && current.kind !== "smart" ? current.id : null, null);

    // ---- sidebar: each row is also a place to drop dragged tasks ----
    const dropTo = (el: HTMLElement, to: Destination) => {
      el.addEventListener("dragover", (e) => { e.preventDefault(); el.classList.add("drop"); });
      el.addEventListener("dragleave", () => el.classList.remove("drop"));
      el.addEventListener("drop", (e) => { e.preventDefault(); el.classList.remove("drop"); const ids = ((e as DragEvent).dataTransfer?.getData("text/x-task-ids") ?? "").split(",").filter(Boolean); if (ids.length) void store.move(ids, to); });
      return el;
    };
    const navRow = (id: string, name: string, count: number, cls = "", to?: Destination) => {
      const b = h("button", { type: "button", class: `item navrow ${cls}` + (ui.view === id ? " on" : ""), ...(ui.view === id ? { "aria-current": "page" } : {}), onclick: () => go(id) },
        h("span", { class: "item-title" }, name), h("span", { class: "sub count" }, String(count)));
      return to ? dropTo(b, to) : b;
    };
    const openIn = (id: string) => inList(tasks, lists, id).length;
    const projectRow = (p: TaskList, nested: boolean) => navRow(p.id, (p.name.trim() || "New project") + (p.status !== "active" ? ` · ${p.status === "finished" ? "Finished" : "Someday"}` : ""), openIn(p.id), nested ? "nested" : "", { list: p.id, heading: null });
    side.replaceChildren(
      ...BUCKETS.map((b) => navRow(b.id, b.name, b.id === "logbook" ? tasks.filter((t) => t.completedAt !== null).length : inBucket(tasks, b.id, today).length, "",
        b.id === "upcoming" || b.id === "logbook" ? undefined : { bucket: b.id })),
      h("div", { class: "panel-title spaced" }, "Areas and projects"),
      ...areas.flatMap((a) => [navRow(a.id, a.name.trim() || "New area", openIn(a.id), "", { list: a.id, heading: null }), ...projects.filter((p) => p.areaID === a.id).map((p) => projectRow(p, true))]),
      ...projects.filter((p) => !p.areaID || !areas.some((a) => a.id === p.areaID)).map((p) => projectRow(p, false)),
      ...(smart.length ? [h("div", { class: "panel-title spaced" }, "Smart lists"), ...smart.map((s) => navRow(s.id, (s.isPinned ? "★ " : "") + (s.name.trim() || "New smart list"), smartTasks(parseRules(store.rawList(s.id)?.rules) ?? { match: "all", rules: [] }, tasks, lists, today).length))] : []),
      h("button", { type: "button", class: "quiet small-btn new-list", onclick: () => newListSheet(store, areas, (id) => go(id)) }, "+ New area, project or smart list"),
      ...(store.unreadable ? [h("p", { class: "sub" }, `${plural(store.unreadable, "item")} didn't open with your key and ${store.unreadable === 1 ? "is" : "are"} hidden.`)] : []));

    // ---- the list ----
    let shown: Task[];
    const linger = (t: Task) => ui.lingering.has(t.id);
    if (isBucket) {
      shown = inBucket(tasks, ui.view as Bucket, today);
      if (ui.view !== "logbook") shown = [...shown, ...tasks.filter((t) => linger(t) && !shown.includes(t))];
    } else if (current?.kind === "smart") shown = smartTasks(parseRules(store.rawList(current.id)?.rules) ?? { match: "all", rules: [] }, tasks, lists, today);
    else if (current?.kind === "project") shown = tasks.filter((t) => t.listID === current.id).sort((a, b) => a.order - b.order || a.createdAt - b.createdAt);
    else if (current) shown = [...inList(tasks, lists, current.id), ...tasks.filter((t) => linger(t) && t.listID === current.id)];
    else shown = [];

    const listName = (t: Task) => lists.find((l) => l.id === t.listID)?.name.trim() ?? "";
    const row = (t: Task) => {
      const done = t.completedAt !== null;
      const check = ui.selecting
        ? h("input", { type: "checkbox", class: "pick-box", "aria-label": `Select ${t.title || "task"}`, ...(ui.selected.has(t.id) ? { checked: true } : {}), onchange: (e) => { const on = (e.target as HTMLInputElement).checked; if (on) ui.selected.add(t.id); else ui.selected.delete(t.id); draw(); } })
        : h("button", { type: "button", class: "circle-btn" + (done ? " done" : ""), "aria-label": done ? `Mark “${t.title}” not done` : `Mark “${t.title}” done`, onclick: () => void toggle(t) }, done ? "✓" : "");
      const chips = [
        listName(t) && ui.view !== t.listID ? listName(t) : null,
        t.when && ui.view !== "today" ? dayText(t.when, today) : null,
        t.time ? timeText(t.time) : t.isEvening && ui.view === "today" ? "Evening" : null,
        t.deadline ? `Due ${dayText(t.deadline, today)}` : null, t.repeats ? "↻" : null,
        t.checklist.length ? `${t.checklist.filter((c) => c.done).length}/${t.checklist.length}` : null,
      ].filter((x): x is string => !!x);
      const el = h("div", { class: "taskrow-wrap" + (t.id === ui.taskId ? " on" : ""), draggable: "true" }, check,
        h("button", { type: "button", class: "task-open", onclick: () => go(ui.view, t.id) }, h("span", { class: "task-title" + (done ? " done" : "") }, t.title.trim() || "New task"),
          ...chips.map((c) => h("span", { class: "chip" }, c))));
      el.addEventListener("dragstart", (e) => {
        const ids = ui.selecting && ui.selected.has(t.id) ? [...ui.selected] : [t.id];
        (e as DragEvent).dataTransfer?.setData("text/x-task-ids", ids.join(","));
        (e as DragEvent).dataTransfer?.setData("text/x-task-id", t.id);
      });
      el.addEventListener("dragover", (e) => { e.preventDefault(); el.classList.add("drop"); });
      el.addEventListener("dragleave", () => el.classList.remove("drop"));
      el.addEventListener("drop", (e) => { e.preventDefault(); el.classList.remove("drop"); const id = (e as DragEvent).dataTransfer?.getData("text/x-task-id"); if (id) void store.placeBefore(id, t.id, shown); });
      return el;
    };

    const head: Node[] = current ? [listHeader(store, current, areas, projects, () => go("today"))] : [];
    const bulk = ui.selecting ? [bulkBar(store, [...ui.selected].filter((id) => shown.some((t) => t.id === id)), areas, projects, () => { ui.selected.clear(); draw(); })] : [];
    let body: Node[];
    if (current?.kind === "project") {
      const known = new Set(current.headings.map((x) => x.id));
      const loose = shown.filter((t) => !t.headingID || !known.has(t.headingID));
      body = [...loose.map(row), h("button", { type: "button", class: "quiet small-btn add-here", onclick: () => quickAdd(store, null, current.id, null) }, "Add a task here")];
      for (const hd of current.headings) {
        const name = input({ class: "heading-field", "aria-label": "Heading", value: hd.title });
        onSettled(name, (v) => void store.changeList(current.id, (l) => { const x = (l.headings as Raw[]).find((y) => String(y.id).toLowerCase() === hd.id); if (x && v.trim()) x.title = v.trim(); }));
        const headRow = h("div", { class: "heading-row" }, name, h("button", { type: "button", class: "quiet small-btn", onclick: () => void store.removeHeading(current.id, hd.id) }, "Remove heading"));
        dropRowTo(headRow, (ids) => void store.move(ids, { list: current.id, heading: hd.id }));
        const mineUnder = shown.filter((t) => t.headingID === hd.id);
        body.push(headRow, ...mineUnder.map(row), h("button", { type: "button", class: "quiet small-btn add-here", onclick: () => quickAdd(store, null, current.id, hd.id) }, "Add a task here"));
      }
      const newHeading = input({ "aria-label": "Add a heading", placeholder: "Add a heading" });
      newHeading.addEventListener("keydown", (e) => { if ((e as KeyboardEvent).key === "Enter") { const v = newHeading.value; newHeading.value = ""; void store.addHeading(current.id, v); } });
      body.push(newHeading);
    } else body = shown.length ? shown.map(row) : [h("p", { class: "status empty" }, isBucket ? EMPTY[ui.view as Bucket] : current?.kind === "smart" ? (parseRules(store.rawList(current.id)?.rules)?.rules.length ? "Nothing matches these rules" : "Add a rule to find tasks") : "Nothing open in this list"),
      ...(ui.view !== "logbook" && ui.view !== "upcoming" && current?.kind !== "smart" ? [h("button", { type: "button", class: "small-btn", onclick: () => addBtn.click() }, "Add a task")] : [])];
    listHost.replaceChildren(...head, ...bulk, ...body);

    // ---- details ----
    const t = tasks.find((x) => x.id === ui.taskId);
    const typing = detail.contains(document.activeElement) && /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName ?? "");
    if (!t) { if (editorFor !== null || !detail.childElementCount) detail.replaceChildren(h("p", { class: "status" }, ui.taskId ? "That task isn't here any more." : "Pick a task to see and change it here.")); editorFor = null; }
    else if (!(typing && editorFor === t.id)) {
      renderEditor(detail, store, t, { areas: areas.map((a) => ({ id: a.id, name: a.name || "New area" })), projects: projects.map((p) => ({ id: p.id, name: p.name || "New project", headings: p.headings })) });
      editorFor = t.id;
    }

    // ---- Undo ----
    const p = store.pending;
    if (p) {
      toast.hidden = false;
      toast.replaceChildren(h("span", {}, p.title), h("button", { type: "button", class: "toast-btn", onclick: () => store.undoDelete() }, "Undo"));
    } else if (ui.done) {
      const d = ui.done;
      toast.hidden = false;
      toast.replaceChildren(h("span", {}, `“${d.title}” done`), h("button", { type: "button", class: "toast-btn", onclick: async () => { clearTimeout(d.timer); ui.done = null; ui.lingering.delete(d.id); await store.unfinish(d.id); } }, "Undo"));
    } else toast.hidden = true;
  }

  function dropRowTo(el: HTMLElement, f: (ids: string[]) => void): void {
    el.addEventListener("dragover", (e) => { e.preventDefault(); el.classList.add("drop"); });
    el.addEventListener("dragleave", () => el.classList.remove("drop"));
    el.addEventListener("drop", (e) => { e.preventDefault(); el.classList.remove("drop"); const ids = ((e as DragEvent).dataTransfer?.getData("text/x-task-ids") ?? "").split(",").filter(Boolean); if (ids.length) f(ids); });
  }

  /** TasksModel.toggle: done stays in place for a moment, with Undo for five seconds. */
  async function toggle(t: Task): Promise<void> {
    if (t.completedAt !== null) { ui.lingering.delete(t.id); if (ui.done?.id === t.id) { clearTimeout(ui.done.timer); ui.done = null; } await store.unfinish(t.id); return; }
    ui.lingering.add(t.id);
    if (ui.done) clearTimeout(ui.done.timer);
    ui.done = { id: t.id, title: t.title.trim() || "New task", timer: setTimeout(() => { ui.done = null; draw(); }, UNDO_MS) };
    setTimeout(() => { ui.lingering.delete(t.id); draw(); }, LINGER_MS);
    if (!(await store.finish(t.id))) { ui.lingering.delete(t.id); ui.done = null; }
    draw();
  }

  draw();
}

// ---- sheets and pieces ----

function quickAdd(store: TasksStore, bucket: Bucket | null, list: string | null, heading: string | null): void {
  const text = h("textarea", { class: "notes-field", rows: "3", "aria-label": "New task", placeholder: "Email Dr. Lee tomorrow 9am #school !high" });
  const understood = h("div", { class: "chips understood", "aria-live": "polite" });
  text.addEventListener("input", () => {
    const parsed = parseLines(text.value, store.quickCtx());
    const today = localToday();
    understood.replaceChildren(...parsed.slice(0, 1).flatMap((p) => [
      h("span", { class: "sub" }, "Understood:"), h("span", { class: "chip big" }, p.title || "…"),
      ...(p.when ? [h("span", { class: "chip big" }, dayText(p.when, today) + (p.time ? `, ${timeText(p.time)}` : p.isEvening ? ", evening" : ""))] : []),
      ...(p.deadline ? [h("span", { class: "chip big" }, `Due ${dayText(p.deadline, today)}`)] : []),
      ...p.tags.map((t) => h("span", { class: "chip big" }, "#" + t)),
      ...(p.priority ? [h("span", { class: "chip big" }, ["", "Low", "Medium", "High"][p.priority] + " priority")] : []),
      ...(p.place && !p.when ? [h("span", { class: "chip big" }, p.place === "someday" ? "Someday" : "Anytime")] : []),
    ]), ...(parsed.length > 1 ? [h("span", { class: "sub" }, `and ${plural(parsed.length - 1, "more task")}`)] : []));
  });
  const d = sheet("New task", [text, understood, h("p", { class: "sub" }, "Type it like you'd say it. Paste several lines to add several tasks. Open a task afterwards for steps, repeats and reminders.")],
    [{ label: "Add", primary: true, run: async () => { if (!text.value.trim()) return false; const ids = await store.add(text.value, bucket, list, heading); if (ids.length === 1) location.hash = `#/tasks/${location.hash.split("/")[2] ?? "today"}/${ids[0]}`; return ids.length > 0; } }]);
  text.addEventListener("keydown", (e) => { const k = e as KeyboardEvent; if (k.key === "Enter" && (k.metaKey || k.ctrlKey)) (d.querySelector(".sheet-foot button:last-child") as HTMLButtonElement | null)?.click(); });
  text.focus();
}

function newListSheet(store: TasksStore, areas: TaskList[], open: (id: string) => void): void {
  let kind: "area" | "project" | "smart" = "project";
  const name = input({ "aria-label": "Name", placeholder: "Seminar paper" });
  const area = select([["", "No area"], ...areas.map((a): [string, string] => [a.id, a.name || "New area"])], "", { "aria-label": "Area" });
  const kinds = h("div", { class: "segs" });
  const areaField = field("Area", area);
  const drawKinds = () => {
    kinds.replaceChildren(...(["area", "project", "smart"] as const).map((k) => seg(k === "smart" ? "Smart list" : k[0]!.toUpperCase() + k.slice(1), kind === k, () => { kind = k; drawKinds(); })));
    areaField.hidden = kind !== "project";
  };
  drawKinds();
  sheet("New list", [kinds, field("Name", name), areaField], [{ label: "Create", primary: true, run: async () => { const id = await store.addList(name.value, kind, area.value || null); if (id) open(id); return !!id; } }]);
  name.focus();
}

function listHeader(store: TasksStore, l: TaskList, areas: TaskList[], projects: TaskList[], afterDelete: () => void): HTMLElement {
  const name = input({ class: "title-field", "aria-label": "List name", value: l.name, placeholder: l.kind === "area" ? "New area" : l.kind === "project" ? "New project" : "New smart list" });
  onSettled(name, (v) => void store.changeList(l.id, (x) => { x.name = v.trim(); }));
  const parts: Node[] = [name];
  if (l.kind === "project") {
    const status = select([["active", "Active"], ["someday", "Someday"], ["finished", "Finished"]], l.status, { "aria-label": "Status" });
    status.addEventListener("change", () => void store.changeList(l.id, (x) => { x.status = status.value; }));
    const deadline = input({ type: "date", value: dayValue(l.deadline), "aria-label": "Project deadline" });
    deadline.addEventListener("change", () => void store.changeList(l.id, (x) => { const d = dayFrom(deadline.value); if (d) x.deadline = d; else delete x.deadline; }));
    const area = select([["", "No area"], ...areas.map((a): [string, string] => [a.id, a.name || "New area"])], l.areaID ?? "", { "aria-label": "Area" });
    area.addEventListener("change", () => void store.changeList(l.id, (x) => { if (area.value) x.areaID = area.value.toUpperCase(); else delete x.areaID; }));
    const all = store.allTasks.filter((t) => t.listID === l.id);
    parts.push(h("div", { class: "grid3" }, field("Status", status), field("Deadline", deadline), field("Area", area)),
      h("p", { class: "sub" }, `${all.filter((t) => t.completedAt !== null).length} of ${all.length} done`));
  }
  if (l.kind === "smart") parts.push(rulesEditor(store, l, areas, projects));
  parts.push(h("div", { class: "list-actions" }, h("button", { type: "button", class: "quiet small-btn danger", onclick: () => { void store.delete([], [l.id]); afterDelete(); } },
    l.kind === "area" ? "Delete area and everything in it" : l.kind === "project" ? "Delete project and its tasks" : "Delete smart list")));
  return h("div", { class: "list-head" }, ...parts);
}

function rulesEditor(store: TasksStore, l: TaskList, areas: TaskList[], projects: TaskList[]): HTMLElement {
  const raw = store.rawList(l.id) ?? {};
  const rules = parseRules(raw.rules) ?? { match: "all" as const, rules: [] };
  const keep = (raw.rules as { rules?: Raw[] } | undefined)?.rules ?? [];
  const save = (edit: (rs: Raw[]) => void, match = rules.match) => void store.changeList(l.id, (x) => {
    const list = structuredClone(((x.rules as { rules?: Raw[] } | undefined)?.rules) ?? []);
    edit(list);
    x.rules = { match, rules: list };
  });
  const pin = h("input", { type: "checkbox", class: "switch", "aria-label": "Pin to Lists", ...(l.isPinned ? { checked: true } : {}) });
  pin.addEventListener("change", () => void store.changeList(l.id, (x) => { x.isPinned = pin.checked; }));
  const rows = rules.rules.map((r: SmartRule, i) => {
    const original = keep[i] ?? {};
    if (r.kind === "unknown") return h("div", { class: "rule-row" }, h("span", { class: "sub grow" }, "A rule from a newer version. It's kept as it is."));
    const kind = select(RULE_KINDS.map((k): [string, string] => [k.id, k.name]), r.kind, { "aria-label": "Rule kind" });
    const neg = select([["0", "is"], ["1", "is not"]], r.isNegated ? "1" : "0", { "aria-label": "Which" });
    let value: HTMLElement;
    const setRule = (f: (x: Raw) => void) => save((rs) => { const x = rs[i]; if (x) f(x); });
    kind.addEventListener("change", () => setRule((x) => { x.kind = kind.value; delete x.tag; delete x.listID; delete x.priority; delete x.days; }));
    neg.addEventListener("change", () => setRule((x) => { x.isNegated = neg.value === "1"; }));
    if (r.kind === "tag") { const v = input({ "aria-label": "Tag", value: r.tag ?? "", placeholder: "school" }); onSettled(v, (t) => setRule((x) => { x.tag = t.replace(/^#/, ""); })); value = v; }
    else if (r.kind === "area" || r.kind === "project") {
      const from = r.kind === "area" ? areas : projects;
      const v = select([["", "Choose…"], ...from.map((a): [string, string] => [a.id, a.name || "Untitled"])], r.listID?.toLowerCase() ?? "", { "aria-label": r.kind === "area" ? "Area" : "Project" });
      v.addEventListener("change", () => setRule((x) => { if (v.value) x.listID = v.value.toUpperCase(); else delete x.listID; })); value = v;
    } else if (r.kind === "priority") {
      const v = select([["0", "None"], ["1", "Low"], ["2", "Medium"], ["3", "High"]], String(r.priority ?? 0), { "aria-label": "Priority" });
      v.addEventListener("change", () => setRule((x) => { x.priority = Number(v.value); })); value = v;
    } else if (r.kind === "when" || r.kind === "deadline") {
      const v = select([["", "Any day"], ["0", "Today or overdue"], ["1", "Within 1 day"], ["3", "Within 3 days"], ["7", "Within 7 days"], ["14", "Within 14 days"], ["30", "Within 30 days"]], r.days === undefined ? "" : String(r.days), { "aria-label": "Within" });
      v.addEventListener("change", () => setRule((x) => { if (v.value === "") delete x.days; else x.days = Number(v.value); })); value = v;
    } else value = h("span", { class: "sub" }, "");
    void original;
    return h("div", { class: "rule-row" }, kind, neg, value, h("button", { type: "button", class: "icon-btn", "aria-label": `Remove the ${r.kind} rule`, onclick: () => save((rs) => { rs.splice(i, 1); }) }, "×"));
  });
  return h("div", { class: "rules" },
    h("div", { class: "segs" }, seg("Match all rules", rules.match === "all", () => save(() => {}, "all")), seg("Match any rule", rules.match === "any", () => save(() => {}, "any")),
      h("label", { class: "row-field" }, pin, h("span", {}, "Pin to Lists"))),
    ...rows,
    h("button", { type: "button", class: "quiet small-btn", onclick: () => save((rs) => { rs.push({ id: newID(), kind: "tag", isNegated: false }); }) }, "+ Add a rule"));
}

function bulkBar(store: TasksStore, ids: string[], areas: TaskList[], projects: TaskList[], clear: () => void): HTMLElement {
  const n = ids.length;
  const move = select([["", "Move…"], ["b:inbox", "Inbox"], ["b:today", "Today"], ["b:anytime", "Anytime"], ["b:someday", "Someday"],
    ...areas.map((a): [string, string] => [`l:${a.id}`, a.name || "New area"]), ...projects.map((p): [string, string] => [`l:${p.id}`, p.name || "New project"])], "", { "aria-label": "Move to" });
  move.addEventListener("change", () => {
    const v = move.value;
    if (!v) return;
    void store.move(ids, v.startsWith("b:") ? { bucket: v.slice(2) as Bucket } : { list: v.slice(2), heading: null }).then(clear);
  });
  const tag = input({ "aria-label": "Tag to add", placeholder: "Tag", class: "tag-input" });
  tag.addEventListener("keydown", (e) => { if ((e as KeyboardEvent).key === "Enter") { const v = tag.value; tag.value = ""; void store.addTag(v, ids); } });
  const disabled = { disabled: n === 0 };
  return h("div", { class: "bulk", role: "toolbar", "aria-label": `${n} selected` }, h("span", { class: "bulk-count" }, `${n} selected`), h("span", { class: "grow" }),
    move, h("button", { type: "button", class: "quiet small-btn", ...disabled, onclick: () => { if (ids[0]) scheduleMany(store, ids); } }, "Schedule"), tag,
    h("button", { type: "button", class: "quiet small-btn", ...disabled, onclick: () => void store.completeAll(ids).then(clear) }, "Complete"),
    h("button", { type: "button", class: "quiet small-btn danger", ...disabled, onclick: () => void store.delete(ids).then(clear) }, "Delete"));
}

function scheduleMany(store: TasksStore, ids: string[]): void {
  if (ids.length === 1) { scheduleSheet(store, ids[0]!); return; }
  const today = localToday();
  const date = input({ type: "date", value: dayValue(today), "aria-label": "Day" });
  const all = (choice: Parameters<TasksStore["schedule"]>[1]) => Promise.all(ids.map((id) => store.schedule(id, choice)));
  sheet(`Schedule ${plural(ids.length, "task")}`, [
    h("div", { class: "segs wrap" },
      h("button", { type: "button", class: "quiet", onclick: (e) => { void all({ day: today, evening: false }); (e.target as HTMLElement).closest("dialog")?.close(); } }, "Today"),
      h("button", { type: "button", class: "quiet", onclick: (e) => { void all({ day: today, evening: true }); (e.target as HTMLElement).closest("dialog")?.close(); } }, "This evening"),
      h("button", { type: "button", class: "quiet", onclick: (e) => { void all("anytime"); (e.target as HTMLElement).closest("dialog")?.close(); } }, "Anytime"),
      h("button", { type: "button", class: "quiet", onclick: (e) => { void all("someday"); (e.target as HTMLElement).closest("dialog")?.close(); } }, "Someday")),
    field("Pick a day", date)], [{ label: "Schedule", primary: true, run: () => { const d = dayFrom(date.value); return d ? all({ day: d, evening: false }) : false; } }]);
}

export const _forTests = { appleNow };
