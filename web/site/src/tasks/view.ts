import { h } from "../dom";
import { loadAll } from "../sealedjson";
import { parse as parseMarkdown } from "../reader/markdown";
import { noteFrame, type Ctx } from "../reader/view";
import { bucketOf, dayText, inBucket, inList, parseList, parseTask, timeText, type Bucket, type Task, type TaskList } from "./model";

const BUCKETS: { id: Bucket; name: string }[] = [
  { id: "inbox", name: "Inbox" }, { id: "today", name: "Today" }, { id: "upcoming", name: "Upcoming" },
  { id: "anytime", name: "Anytime" }, { id: "someday", name: "Someday" }, { id: "logbook", name: "Logbook" },
];
const EMPTY: Record<Bucket, string> = {
  inbox: "Your Inbox is clear", today: "Nothing planned", upcoming: "Nothing coming up", anytime: "Nothing waiting", someday: "No parked ideas", logbook: "Nothing done yet",
};
let run = 0;
export const stopTasks = (): void => { run++; };

function localToday() { const d = new Date(); return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() }; }

export async function showTasks(into: HTMLElement, ctx: Ctx, view: string | null, taskId: string | null): Promise<void> {
  const mine = ++run;
  const today = localToday();
  const side = h("section", { class: "panel tasknav" }, h("p", { class: "status" }, "Opening your tasks…"));
  const listHost = h("section", { class: "panel tasklist" });
  const detail = h("section", { class: "panel detail" }, h("p", { class: "status" }, "Pick a task to see it here."));
  into.replaceChildren(h("div", { class: "page-head" }, h("h1", {}, "Tasks")), h("p", { class: "sub" }, "Read-only for now. Add and check off tasks on your iPhone."), h("div", { class: "reader" }, side, listHost, detail));

  let tasks: Task[] = [], lists: TaskList[] = [], unreadable = 0;
  try {
    const token = await ctx.token();
    const [t, l] = [await loadAll(token, "task", "task"), await loadAll(token, "task_list", "task-list")];
    if (mine !== run) return;
    tasks = t.items.map((i) => parseTask(i.id, i.json)).filter((x): x is Task => !!x);
    lists = l.items.map((i) => parseList(i.id, i.json)).filter((x): x is TaskList => !!x);
    unreadable = t.unreadable + l.unreadable;
  } catch (e) {
    if (mine === run) side.replaceChildren(h("p", { class: "status" }, e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your tasks. Check your connection."));
    return;
  }
  const current = view ?? "today";
  const go = (v: string, id?: string) => { location.hash = `#/tasks/${v}${id ? "/" + id : ""}`; };
  const open = tasks.filter((t) => t.completedAt === null);

  const navButton = (id: string, name: string, count: number, folder = false) =>
    h("button", { type: "button", class: "item navrow" + (current === id ? " on" : ""), onclick: () => go(id) }, h("span", { class: "item-title" }, (folder ? "▸ " : "") + name), h("span", { class: "sub count" }, String(count)));
  const areas = lists.filter((l) => l.kind === "area").sort((a, b) => a.order - b.order || a.createdAt - b.createdAt);
  const projects = lists.filter((l) => l.kind === "project" && l.status !== "finished").sort((a, b) => a.order - b.order || a.createdAt - b.createdAt);
  const smart = lists.filter((l) => l.kind === "smart").length;
  side.replaceChildren(
    ...BUCKETS.map((b) => navButton(b.id, b.name, b.id === "logbook" ? tasks.filter((t) => t.completedAt !== null).length : inBucket(tasks, b.id, today).length)),
    ...(areas.length || projects.length ? [h("div", { class: "panel-title spaced" }, "Lists")] : []),
    ...areas.map((l) => navButton(l.id, l.name.trim() || "Untitled area", inList(tasks, lists, l.id).length, true)),
    ...projects.map((l) => navButton(l.id, l.name.trim() || "Untitled project", inList(tasks, lists, l.id).length, true)),
    ...(smart ? [h("p", { class: "sub" }, `${smart} smart list${smart === 1 ? "" : "s"} open on your iPhone.`)] : []),
    ...(unreadable ? [h("p", { class: "sub" }, `${unreadable} item${unreadable === 1 ? "" : "s"} didn't open with your key and ${unreadable === 1 ? "is" : "are"} hidden.`)] : []));

  const isBucket = BUCKETS.some((b) => b.id === current);
  const shown = isBucket ? inBucket(tasks, current as Bucket, today) : inList(tasks, lists, current);
  const listName = (t: Task) => lists.find((l) => l.id === t.listID)?.name.trim() ?? "";
  const circle = (done: boolean) => h("span", { class: "circle" + (done ? " done" : ""), role: "img", "aria-label": done ? "Done" : "Not done" }, done ? "✓" : "");
  const row = (t: Task) => h("button", { type: "button", class: "item taskrow" + (t.id === taskId ? " on" : ""), onclick: () => go(current, t.id) },
    circle(t.completedAt !== null), h("span", { class: "task-title" + (t.completedAt !== null ? " done" : "") }, t.title.trim() || "Untitled task"),
    listName(t) && current !== t.listID ? h("span", { class: "chip" }, listName(t)) : null,
    t.time ? h("span", { class: "chip" }, timeText(t.time)) : null);
  listHost.replaceChildren(...(shown.length ? shown.map(row) : [h("p", { class: "status" }, isBucket ? EMPTY[current as Bucket] : "Nothing open in this list.")]));
  void open; void bucketOf;

  const t = tasks.find((x) => x.id === taskId);
  if (!t) return;
  const chips = [
    t.when ? dayText(t.when, today) + (t.time ? `, ${timeText(t.time)}` : t.isEvening ? ", evening" : "") : null,
    t.deadline ? `Due ${dayText(t.deadline, today)}` : null, listName(t) || null, t.repeats ? "Repeats" : "Repeats: never", ...t.tags,
  ].filter((x): x is string => !!x);
  detail.replaceChildren(h("h2", { class: "doc-title small" }, t.title.trim() || "Untitled task"),
    h("div", { class: "chips" }, ...chips.map((c) => h("span", { class: "chip big" }, c))),
    ...(t.notes.trim() ? [noteFrame(parseMarkdown(t.notes))] : []),
    ...(t.checklist.length ? [h("div", { class: "panel-title spaced" }, "Steps")] : []),
    ...t.checklist.map((c) => h("div", { class: "step-row" }, circle(c.done), h("span", { class: c.done ? "task-title done" : "task-title" }, c.title))));
}
