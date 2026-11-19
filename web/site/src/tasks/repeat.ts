// RepeatRule.swift and TaskRepeats.swift, line for line. Days are counted on the calendar, never in 24-hour
// spans. Rules are plain JSON in the shape Swift's JSONEncoder writes them, so they round-trip untouched.
import { sha256 } from "@noble/hashes/sha2.js";
import { toHex } from "../pairing/protocol";

export interface Day { year: number; month: number; day: number }
export interface Cal { firstWeekday: number } // 1 is Sunday, as Calendar counts

export type Kind = "daily" | "weekly" | "monthly" | "yearly" | "afterFinish" | "custom";
export type Unit = "day" | "week" | "month" | "year";
export type End = { never: Record<string, never> } | { on: { _0: Day } } | { after: { times: number } };
export interface Rule {
  kind: Kind; interval: number; customUnit: Unit; weekdays: number[]; monthDays: number[];
  monthWeekday?: { ordinal: number; weekday: number }; countFrom: "completion" | "dueDate"; end: End;
  start: Day; skipped: Day[]; done: number;
}

const KINDS: Kind[] = ["daily", "weekly", "monthly", "yearly", "afterFinish", "custom"];
const UNITS: Unit[] = ["day", "week", "month", "year"];
const isDay = (v: unknown): v is Day => !!v && typeof (v as Day).year === "number" && typeof (v as Day).month === "number" && typeof (v as Day).day === "number";
const toDay = (v: Day): Day => ({ year: v.year, month: v.month, day: v.day });

/** Reads a rule as RepeatRule.init(from:) does: anything missing or odd takes its default. Null if there's no start. */
export function parseRule(v: unknown): Rule | null {
  const o = v as Record<string, unknown> | null;
  if (!o || !isDay(o.start)) return null;
  const ints = (x: unknown): number[] => (Array.isArray(x) ? x.filter((n): n is number => Number.isInteger(n)) : []);
  const e = o.end as Record<string, unknown> | undefined;
  let end: End = { never: {} };
  if (e && typeof e === "object") {
    const on = (e.on as { _0?: unknown } | undefined)?._0;
    const times = (e.after as { times?: unknown } | undefined)?.times;
    if (isDay(on)) end = { on: { _0: toDay(on) } };
    else if (Number.isInteger(times)) end = { after: { times: times as number } };
  }
  const mw = o.monthWeekday as { ordinal?: unknown; weekday?: unknown } | undefined;
  const rule: Rule = {
    kind: KINDS.includes(o.kind as Kind) ? (o.kind as Kind) : "daily",
    interval: Math.max(1, Number.isInteger(o.interval) ? (o.interval as number) : 1),
    customUnit: UNITS.includes(o.customUnit as Unit) ? (o.customUnit as Unit) : "day",
    weekdays: [...new Set(ints(o.weekdays).filter((d) => d >= 1 && d <= 7))].sort((a, b) => a - b),
    monthDays: [...new Set(ints(o.monthDays))].sort((a, b) => a - b),
    countFrom: o.countFrom === "dueDate" ? "dueDate" : "completion", end, start: toDay(o.start),
    skipped: dedupeDays((Array.isArray(o.skipped) ? o.skipped : []).filter(isDay).map(toDay)),
    done: Number.isInteger(o.done) ? (o.done as number) : 0,
  };
  if (mw && Number.isInteger(mw.ordinal) && Number.isInteger(mw.weekday)) rule.monthWeekday = { ordinal: mw.ordinal as number, weekday: mw.weekday as number };
  return rule;
}

/** The JSON Swift writes for a rule: sets sorted, monthWeekday only when there is one. */
export function encodeRule(r: Rule): Record<string, unknown> {
  const out: Record<string, unknown> = {
    kind: r.kind, interval: Math.max(1, r.interval), customUnit: r.customUnit,
    weekdays: [...new Set(r.weekdays)].sort((a, b) => a - b), monthDays: [...new Set(r.monthDays)].sort((a, b) => a - b),
  };
  if (r.monthWeekday) out.monthWeekday = { ordinal: r.monthWeekday.ordinal, weekday: r.monthWeekday.weekday };
  Object.assign(out, { countFrom: r.countFrom, end: r.end, start: toDay(r.start), skipped: dedupeDays(r.skipped), done: r.done });
  return out;
}

export function newRule(kind: Kind, start: Day): Rule {
  return { kind, interval: 1, customUnit: "day", weekdays: [], monthDays: [], countFrom: "completion", end: { never: {} }, start, skipped: [], done: 0 };
}

// ---- days ----
export const cmpDay = (a: Day, b: Day): number => a.year - b.year || a.month - b.month || a.day - b.day;
export const sameDay = (a: Day, b: Day): boolean => cmpDay(a, b) === 0;
function dedupeDays(days: Day[]): Day[] {
  const sorted = [...days].sort(cmpDay);
  return sorted.filter((d, i) => i === 0 || !sameDay(d, sorted[i - 1]!));
}
const utc = (d: Day): number => Date.UTC(d.year, d.month - 1, d.day);
const fromUtc = (ms: number): Day => { const t = new Date(ms); return { year: t.getUTCFullYear(), month: t.getUTCMonth() + 1, day: t.getUTCDate() }; };
export const addDays = (d: Day, n: number): Day => fromUtc(Date.UTC(d.year, d.month - 1, d.day + n));
export const daysBetween = (a: Day, b: Day): number => Math.round((utc(b) - utc(a)) / 86_400_000);
export const weekday = (d: Day): number => new Date(utc(d)).getUTCDay() + 1;
export const lastDay = (year: number, month: number): number => new Date(Date.UTC(year, month, 0)).getUTCDate();
const has = (days: Day[], d: Day): boolean => days.some((x) => sameDay(x, d));

export function unitOf(r: Rule): Unit {
  switch (r.kind) {
    case "daily": return "day";
    case "weekly": return "week";
    case "monthly": return "month";
    case "yearly": return "year";
    default: return r.customUnit;
  }
}

function monthAdding(months: number, d: Day, wanted: number): Day {
  const index = d.year * 12 + d.month - 1 + months;
  const year = Math.floor(index / 12), month = (index % 12) + 1;
  return { year, month, day: Math.min(wanted, lastDay(year, month)) };
}
export function addUnits(count: number, unit: Unit, d: Day): Day {
  switch (unit) {
    case "day": return addDays(d, count);
    case "week": return addDays(d, 7 * count);
    case "month": return monthAdding(count, d, d.day);
    case "year": return monthAdding(12 * count, d, d.day);
  }
}
const weekStart = (d: Day, cal: Cal): Day => addDays(d, -((weekday(d) - cal.firstWeekday + 7) % 7));

function nextWeekly(r: Rule, day: Day, cal: Cal): Day | null {
  const days = r.weekdays.length ? r.weekdays : [weekday(r.start)];
  const startWeek = weekStart(r.start, cal);
  let candidate = addDays(day, 1);
  for (let i = 0; i < 7 * r.interval + 7; i++) {
    const weeks = Math.trunc(daysBetween(startWeek, weekStart(candidate, cal)) / 7);
    if (weeks >= 0 && weeks % r.interval === 0 && days.includes(weekday(candidate))) return candidate;
    candidate = addDays(candidate, 1);
  }
  return null;
}
function daysIn(r: Rule, year: number, month: number): Day[] {
  const last = lastDay(year, month);
  if (r.monthWeekday) {
    const matches: number[] = [];
    for (let d = 1; d <= last; d++) if (weekday({ year, month, day: d }) === r.monthWeekday.weekday) matches.push(d);
    const o = r.monthWeekday.ordinal;
    const pick = o < 0 ? matches[matches.length - 1] : matches[o - 1];
    return pick === undefined ? [] : [{ year, month, day: pick }];
  }
  const wanted = r.monthDays.length ? r.monthDays : [r.start.day];
  return [...new Set(wanted.map((x) => (x < 0 ? last : Math.min(x, last))))].map((day) => ({ year, month, day }));
}
function nextMonthly(r: Rule, day: Day): Day | null {
  const startIndex = r.start.year * 12 + r.start.month - 1;
  let index = Math.max(startIndex, day.year * 12 + day.month - 1);
  while ((index - startIndex) % r.interval !== 0) index++;
  for (let i = 0; i < 24; i++) {
    const found = daysIn(r, Math.floor(index / 12), (index % 12) + 1).sort(cmpDay).find((c) => cmpDay(c, day) > 0 && cmpDay(c, r.start) >= 0);
    if (found) return found;
    index += r.interval;
  }
  return null;
}
function nextYearly(r: Rule, day: Day): Day | null {
  let year = Math.max(r.start.year, day.year);
  while ((year - r.start.year) % r.interval !== 0) year++;
  for (let i = 0; i < 4; i++) {
    const c = { year, month: r.start.month, day: Math.min(r.start.day, lastDay(year, r.start.month)) };
    if (cmpDay(c, day) > 0) return c;
    year += r.interval;
  }
  return null;
}
function rawNext(r: Rule, day: Day, completed: Day | null, cal: Cal): Day | null {
  if (r.kind === "afterFinish") return addUnits(r.interval, unitOf(r), r.countFrom === "completion" ? (completed ?? day) : day);
  switch (unitOf(r)) {
    case "day": return addDays(day, r.interval);
    case "week": return nextWeekly(r, day, cal);
    case "month": return nextMonthly(r, day);
    case "year": return nextYearly(r, day);
  }
}
function pastEnd(r: Rule, d: Day): boolean {
  if ("on" in r.end) return cmpDay(d, r.end.on._0) > 0;
  if ("after" in r.end) return r.done + 1 >= r.end.after.times;
  return false;
}

/** RepeatRule.next(after:completed:in:). */
export function nextDay(r: Rule, after: Day, completed: Day | null, cal: Cal): Day | null {
  let from = after;
  for (let i = 0; i < 500; i++) {
    const c = rawNext(r, from, completed, cal);
    if (!c || pastEnd(r, c)) return null;
    if (!has(r.skipped, c)) return c;
    from = c;
  }
  return null;
}

/** RepeatRule.upcoming(from:count:in:), for Coming up. */
export function upcoming(r: Rule, from: Day, count: number, cal: Cal): { day: Day; skipped: boolean }[] {
  const out = [{ day: from, skipped: has(r.skipped, from) }];
  let current = from;
  while (out.length < count) {
    const n = rawNext(r, current, null, cal);
    if (!n || pastEnd(r, n)) break;
    out.push({ day: n, skipped: has(r.skipped, n) });
    current = n;
  }
  return out;
}

// ---- words, as RepeatRule.summary ----
const SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const join = (p: string[]): string => (p.length > 1 ? p.slice(0, -1).join(", ") + " and " + p[p.length - 1] : p[0] ?? "");
const ordinal = (n: number): string => `${n}${n % 100 >= 11 && n % 100 <= 13 ? "th" : n % 10 === 1 ? "st" : n % 10 === 2 ? "nd" : n % 10 === 3 ? "rd" : "th"}`;
const sortedDays = (days: number[], cal: Cal): number[] => [...days].sort((a, b) => ((a - cal.firstWeekday + 7) % 7) - ((b - cal.firstWeekday + 7) % 7));
function dayNames(days: number[], cal: Cal): string {
  const s = [...new Set(days)].sort();
  if (s.join() === "2,3,4,5,6") return "weekday";
  if (s.length === 7) return "day";
  return join(sortedDays(s, cal).map((d) => SHORT[d - 1]!));
}
export function summary(r: Rule, cal: Cal): string {
  const n = r.interval, unit = unitOf(r);
  if (r.kind === "afterFinish") {
    const amount = `${n} ${unit}${n === 1 ? "" : "s"}`;
    return r.countFrom === "completion" ? `${amount} after I finish` : `${amount} after the due date`;
  }
  switch (unit) {
    case "day": return n === 1 ? "Every day" : `Every ${n} days`;
    case "week": {
      const names = dayNames(r.weekdays.length ? r.weekdays : [weekday(r.start)], cal);
      return n === 1 ? "Every " + names : `Every ${n} weeks on ` + names;
    }
    case "month": {
      const every = n === 1 ? "Monthly" : `Every ${n} months`;
      if (r.monthWeekday) {
        const o = r.monthWeekday.ordinal < 0 ? "last" : ["first", "second", "third", "fourth"][Math.max(0, Math.min(3, r.monthWeekday.ordinal - 1))];
        return every + ` on the ${o} ` + LONG[r.monthWeekday.weekday - 1];
      }
      const days = [...(r.monthDays.length ? r.monthDays : [r.start.day])].sort((a, b) => (a < 0 ? 99 : a) - (b < 0 ? 99 : b));
      return every + " on the " + join(days.map((d) => (d < 0 ? "last day" : ordinal(d))));
    }
    case "year": {
      const date = `${r.start.day} ${MONTHS[r.start.month - 1]}`;
      return n === 1 ? `Every ${date}` : `Every ${n} years on ${date}`;
    }
  }
}

// ---- TaskRepeats ----

/** TaskRepeats.followingID: two devices that tick off the same task make the same next copy. */
export function followingID(id: string, d: Day): string {
  const b = sha256(new TextEncoder().encode(`totality.task.repeat|${id.toLowerCase()}|${d.year}-${d.month}-${d.day}`)).slice(0, 16);
  b[6] = (b[6]! & 0x0f) | 0x50;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const x = toHex(b).toUpperCase();
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}
