// Tasks and lists as TaskItem.swift and TaskList.swift seal them, and the buckets of TaskRules.swift.
const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);
export interface Day { year: number; month: number; day: number }
export interface Task {
  id: string; title: string; notes: string; place: "inbox" | "anytime" | "someday"; when: Day | null; time: { hour: number; minute: number } | null;
  deadline: Day | null; checklist: { title: string; done: boolean }[]; tags: string[]; priority: number; listID: string | null;
  order: number; createdAt: number; completedAt: number | null; repeats: boolean; isEvening: boolean;
}
export interface TaskList { id: string; name: string; kind: "area" | "project" | "smart"; areaID: string | null; status: string; order: number; createdAt: number }
export type Bucket = "inbox" | "today" | "upcoming" | "anytime" | "someday" | "logbook";

const str = (v: unknown): string => (typeof v === "string" ? v : "");
const num = (v: unknown, d = 0): number => (typeof v === "number" ? v : d);
const ms = (v: unknown): number => APPLE_EPOCH_MS + num(v) * 1000;
const day = (v: unknown): Day | null => {
  const o = v as Partial<Day> | null;
  return o && typeof o.year === "number" && typeof o.month === "number" && typeof o.day === "number" ? { year: o.year, month: o.month, day: o.day } : null;
};
const uuid = (v: unknown): string | null => (typeof v === "string" ? v.toLowerCase() : null);

export function parseTask(id: string, raw: unknown): Task | null {
  const o = raw as Record<string, unknown> | null;
  if (!o || typeof o.title !== "string") return null;
  const t = o.time as { hour?: number; minute?: number } | null | undefined;
  const place = o.place === "anytime" || o.place === "someday" ? o.place : "inbox";
  return {
    id, title: o.title, notes: str(o.notes), place, when: day(o.when), isEvening: o.isEvening === true,
    time: t && typeof t.hour === "number" ? { hour: t.hour, minute: num(t.minute) } : null, deadline: day(o.deadline),
    checklist: Array.isArray(o.checklist) ? (o.checklist as Record<string, unknown>[]).map((c) => ({ title: str(c.title), done: c.isDone === true })) : [],
    tags: Array.isArray(o.tags) ? (o.tags as unknown[]).filter((x): x is string => typeof x === "string") : [], priority: num(o.priority),
    listID: uuid(o.listID), order: num(o.order), createdAt: ms(o.createdAt), completedAt: o.completedAt == null ? null : ms(o.completedAt), repeats: !!o.repeatRule,
  };
}

export function parseList(id: string, raw: unknown): TaskList | null {
  const o = raw as Record<string, unknown> | null;
  if (!o || (o.kind !== "area" && o.kind !== "project" && o.kind !== "smart")) return null;
  return { id, name: str(o.name), kind: o.kind, areaID: uuid(o.areaID), status: str(o.status) || "active", order: num(o.order), createdAt: ms(o.createdAt) };
}

export const cmp = (a: Day, b: Day): number => a.year - b.year || a.month - b.month || a.day - b.day;

/** The one list a task belongs to, exactly as TaskRules.bucket does it. */
export function bucketOf(t: Task, today: Day): Bucket {
  if (t.completedAt !== null) return "logbook";
  if (t.when) return cmp(t.when, today) <= 0 ? "today" : "upcoming";
  if (t.deadline && cmp(t.deadline, today) <= 0) return "today";
  return t.place;
}

const minutes = (t: Task): number => (t.time ? t.time.hour * 60 + t.time.minute : -1);
const ordered = (a: Task, b: Task): number => (a.order === b.order ? a.createdAt - b.createdAt : a.order - b.order);

export function inBucket(all: Task[], bucket: Bucket, today: Day): Task[] {
  const chosen = all.filter((t) => bucketOf(t, today) === bucket);
  if (bucket === "today") return chosen.sort((a, b) => (minutes(a) === minutes(b) ? ordered(a, b) : minutes(a) < 0 ? -1 : minutes(b) < 0 ? 1 : minutes(a) - minutes(b)));
  if (bucket === "upcoming") return chosen.sort((a, b) => cmp(a.when ?? today, b.when ?? today) || minutes(a) - minutes(b) || a.order - b.order);
  if (bucket === "logbook") return chosen.sort((a, b) => (b.completedAt ?? 0) - (a.completedAt ?? 0));
  return chosen.sort(ordered);
}

/** A list's open tasks. An area also holds its projects' tasks. */
export function inList(all: Task[], lists: TaskList[], listId: string): Task[] {
  const ids = new Set([listId, ...lists.filter((l) => l.areaID === listId).map((l) => l.id)]);
  return all.filter((t) => t.completedAt === null && t.listID !== null && ids.has(t.listID)).sort(ordered);
}

export const timeText = (t: { hour: number; minute: number }): string => {
  const h12 = t.hour % 12 === 0 ? 12 : t.hour % 12;
  return `${h12}${t.minute ? ":" + String(t.minute).padStart(2, "0") : ""} ${t.hour < 12 ? "am" : "pm"}`;
};
export const dayText = (d: Day, today: Day): string => {
  const n = Math.round((Date.UTC(d.year, d.month - 1, d.day) - Date.UTC(today.year, today.month - 1, today.day)) / 86_400_000);
  if (n === 0) return "Today";
  if (n === 1) return "Tomorrow";
  if (n === -1) return "Yesterday";
  return new Date(Date.UTC(d.year, d.month - 1, d.day)).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
};
