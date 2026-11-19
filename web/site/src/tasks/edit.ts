// Changing a task the way TaskItem.swift does. A task is kept as the JSON the iPhone sealed, so parts this
// version doesn't know ride along untouched. Each part (`Field`) keeps its own edit time in `edits`; a change
// stamps the parts that differ, and a merge takes the newer of each part, so two devices never lose work.
import { addDays, daysBetween, encodeRule, followingID, nextDay, parseRule, type Cal, type Day } from "./repeat";

export type Raw = Record<string, unknown>;
const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);
/** Swift's JSONEncoder writes a Date as seconds since 2001-01-01. */
export const appleNow = (ms = Date.now()): number => (ms - APPLE_EPOCH_MS) / 1000;
export const fromApple = (s: number): number => APPLE_EPOCH_MS + s * 1000;
let makeID = (): string => crypto.randomUUID().toUpperCase();
export const newID = (): string => makeID();
/** Tests make IDs in order, so what they seal is the same every run. */
export const setIDMaker = (f: () => string): void => { makeID = f; };

export const FIELDS = {
  title: ["title"], notes: ["notes"], place: ["place"], schedule: ["when", "isEvening", "time", "blockMinutes"],
  deadline: ["deadline", "deadlineTime"], checklist: ["checklist"], tags: ["tags"], priority: ["priority"],
  list: ["listID", "headingID"], order: ["order"], completion: ["completedAt"], repeating: ["repeatRule"],
  reminders: ["reminders", "nagging"], snooze: ["snoozedUntil"], link: ["source"],
} as const;
export type Field = keyof typeof FIELDS;
const FIELD_NAMES = Object.keys(FIELDS) as Field[];

/** What TaskItem.init(from:) fills in for a missing key, so "missing" and "default" compare equal. */
const DEFAULTS: Record<string, unknown> = { title: "", notes: "", place: "inbox", isEvening: false, checklist: [], tags: [], priority: 0, order: 0, reminders: [] };
const ID_KEYS = /^(id|listID|headingID|areaID)$/;

/** A stable text form of a value, keys sorted and IDs folded to one case, for comparing. */
export function canon(v: unknown, key = ""): string {
  if (v === undefined || v === null) return "null";
  if (typeof v === "string") return JSON.stringify(ID_KEYS.test(key) ? v.toLowerCase() : v);
  if (Array.isArray(v)) return "[" + v.map((x) => canon(x)).join(",") + "]";
  if (typeof v === "object") {
    const o = v as Raw;
    return "{" + Object.keys(o).filter((k) => o[k] !== undefined && o[k] !== null).sort().map((k) => JSON.stringify(k) + ":" + canon(o[k], k)).join(",") + "}";
  }
  return JSON.stringify(v);
}
const valueOf = (t: Raw, key: string): unknown => (t[key] === undefined || t[key] === null ? DEFAULTS[key] : t[key]);
export const sameField = (f: Field, a: Raw, b: Raw): boolean => FIELDS[f].every((k) => canon(valueOf(a, k), k) === canon(valueOf(b, k), k));
const take = (f: Field, into: Raw, from: Raw): void => { for (const k of FIELDS[f]) { if (from[k] === undefined || from[k] === null) delete into[k]; else into[k] = structuredClone(from[k]); } };

/** The task as Swift would encode it: every non-optional key present, no nulls. Unknown keys stay. */
export function tidy(t: Raw): Raw {
  const out: Raw = {};
  for (const [k, v] of Object.entries(t)) if (v !== null && v !== undefined) out[k] = v;
  for (const [k, v] of Object.entries(DEFAULTS)) if (out[k] === undefined) out[k] = structuredClone(v);
  if (out.updatedAt === undefined) out.updatedAt = out.createdAt;
  if (out.edits === undefined || typeof out.edits !== "object") out.edits = {};
  return out;
}

/** TaskItem.noteChanges(from:at:): stamps every part that differs from `old`. */
export function noteChanges(t: Raw, old: Raw, at: number): Raw {
  const out = tidy(t);
  const edits = { ...(out.edits as Record<string, number>) };
  let changed = false;
  for (const f of FIELD_NAMES) if (!sameField(f, out, old)) { edits[f] = at; changed = true; }
  out.edits = edits;
  if (changed) out.updatedAt = Math.max(at, Number(old.updatedAt ?? old.createdAt ?? 0));
  return out;
}

/** TaskItem.applying(_:since:at:): only the parts changed from `base` to `edited` go onto `current`. */
export function applying(current: Raw, edited: Raw, base: Raw, at: number): Raw {
  const result = structuredClone(current);
  for (const f of FIELD_NAMES) if (!sameField(f, edited, base)) take(f, result, edited);
  return noteChanges(result, current, at);
}

/** One edit to a task: apply it, then stamp what changed. */
export function change(t: Raw, at: number, edit: (t: Raw) => void): Raw {
  const next = structuredClone(t);
  edit(next);
  return noteChanges(next, t, at);
}

export function newTask(fields: Raw, at: number): Raw {
  return tidy({ id: newID(), title: "", notes: "", place: "inbox", isEvening: false, checklist: [], tags: [], priority: 0, order: 0, createdAt: at, updatedAt: at, edits: {}, reminders: [], ...fields });
}

export const isDone = (t: Raw): boolean => t.completedAt !== undefined && t.completedAt !== null;
const dayOf = (v: unknown): Day | null => {
  const o = v as Day | null;
  return o && typeof o.year === "number" && typeof o.month === "number" && typeof o.day === "number" ? { year: o.year, month: o.month, day: o.day } : null;
};
/** Swift's TaskDay(completedAt, in: calendar): the day on this browser's clock. */
export const localDay = (ms: number): Day => { const d = new Date(ms); return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() }; };

/** TaskRepeats.anchor: When, or the deadline when there's no When. */
export const anchorOf = (t: Raw): Day | null => dayOf(t.when) ?? dayOf(t.deadline);

/** TaskRepeats.moved: the task shifted from `anchor` to `next`, with `rule`, as a copy (new ID) or in place. */
function moved(t: Raw, anchor: Day, next: Day, rule: Raw, id: string, now: number): Raw {
  const shift = daysBetween(anchor, next);
  const when = dayOf(t.when), deadline = dayOf(t.deadline);
  const same = id.toLowerCase() === String(t.id).toLowerCase();
  const checklist = (Array.isArray(t.checklist) ? t.checklist : []) as Raw[];
  const copy: Raw = {
    id, title: t.title ?? "", notes: t.notes ?? "", place: t.place === "inbox" || t.place === undefined ? "anytime" : t.place,
    isEvening: t.isEvening === true, checklist: same ? structuredClone(checklist) : checklist.map((c) => ({ id: newID(), title: c.title ?? "", isDone: false })),
    tags: structuredClone(t.tags ?? []), priority: t.priority ?? 0, order: t.order ?? 0,
    createdAt: same ? t.createdAt : now, edits: same ? structuredClone(t.edits ?? {}) : {}, reminders: [],
  };
  copy.updatedAt = same ? t.updatedAt : copy.createdAt;
  if (when) copy.when = addDays(when, shift);
  if (t.time) copy.time = structuredClone(t.time);
  copy.deadline = when === null ? next : deadline ? addDays(deadline, shift) : undefined;
  if (t.listID) copy.listID = t.listID;
  if (t.headingID) copy.headingID = t.headingID;
  if (t.deadlineTime) copy.deadlineTime = structuredClone(t.deadlineTime);
  copy.repeatRule = rule;
  if (t.nagging) copy.nagging = structuredClone(t.nagging);
  copy.reminders = ((Array.isArray(t.reminders) ? t.reminders : []) as Raw[]).map((r) => {
    const at = (r.kind as Raw | undefined)?.at as { _0?: unknown; _1?: unknown } | undefined;
    const d = dayOf(at?._0);
    return at && d ? { id: r.id, kind: { at: { _0: addDays(d, shift), _1: at._1 } } } : structuredClone(r);
  });
  return tidy(copy);
}

/** TaskRepeats.following: the next copy of a task finished at `completedAtMs`, or null. */
export function following(t: Raw, completedAtMs: number, cal: Cal): Raw | null {
  const rule = parseRule(t.repeatRule);
  if (!rule) return null;
  const completedDay = localDay(completedAtMs);
  const anchor = anchorOf(t) ?? completedDay;
  const next = nextDay(rule, anchor, completedDay, cal);
  if (!next) return null;
  const rule2 = { ...rule, done: rule.done + 1 };
  return moved(t, anchor, next, encodeRule(rule2), followingID(String(t.id), next), appleNow(completedAtMs));
}

/** TaskRepeats.skippingNext: passes over the occurrence that's due. */
export function skippingNext(t: Raw, cal: Cal): Raw | null {
  const rule = parseRule(t.repeatRule), anchor = anchorOf(t);
  if (!rule || !anchor) return null;
  rule.skipped = [...rule.skipped, anchor];
  const next = nextDay(rule, anchor, null, cal);
  if (!next) return null;
  rule.skipped = rule.skipped.filter((d) => d.year * 10000 + d.month * 100 + d.day >= anchor.year * 10000 + anchor.month * 100 + anchor.day);
  const result = moved(t, anchor, next, encodeRule(rule), String(t.id), Number(t.updatedAt));
  if (t.completedAt !== undefined) result.completedAt = t.completedAt;
  return result;
}

/** The finished task whose waiting copy this is, if `copy` is one (TasksModel.unfinish). */
export function isFollowingOf(copy: Raw, finishedID: string): boolean {
  const day = anchorOf(copy);
  return !isDone(copy) && !!copy.repeatRule && !!day && followingID(finishedID, day).toLowerCase() === String(copy.id).toLowerCase();
}
