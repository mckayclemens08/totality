// An event as CalendarEvent.swift seals it, and its occurrences. Repeats follow the iPhone's rules: they keep
// the event's own wall-clock time through daylight saving, a repeat that doesn't exist (the 31st of a short
// month) is skipped rather than moved, and `until` is a day in the event's own zone.
const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);
const DAY = 86_400_000;

export interface Day { year: number; month: number; day: number }
export interface CalEvent {
  id: string; title: string; location: string; notes: string; start: number; end: number; allDay: boolean; tz: string;
  repeat: { freq: "daily" | "weekly" | "monthly" | "yearly"; until: Day | null } | null; skipped: Set<number>;
}
export interface Occurrence { event: CalEvent; start: number; end: number }

const num = (v: unknown, d = 0): number => (typeof v === "number" ? v : d);
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const toDay = (v: unknown): Day | null => {
  const o = v as { year?: number; month?: number; day?: number } | null;
  return o && typeof o.year === "number" && typeof o.month === "number" && typeof o.day === "number" ? { year: o.year, month: o.month, day: o.day } : null;
};

export function parseEvent(id: string, raw: unknown): CalEvent | null {
  const o = raw as Record<string, unknown> | null;
  if (!o || typeof o.start !== "number" || typeof o.end !== "number") return null;
  const r = o.repeatRule as { frequency?: string; until?: unknown } | null | undefined;
  const freq = r?.frequency;
  return {
    id, title: str(o.title), location: str(o.location), notes: str(o.notes),
    start: APPLE_EPOCH_MS + o.start * 1000, end: APPLE_EPOCH_MS + num(o.end, o.start) * 1000,
    allDay: o.isAllDay === true, tz: str(o.timeZoneID) || "GMT",
    repeat: freq === "daily" || freq === "weekly" || freq === "monthly" || freq === "yearly" ? { freq, until: toDay(r?.until) } : null,
    skipped: new Set(Array.isArray(o.skipped) ? (o.skipped as unknown[]).filter((x): x is number => typeof x === "number").map((x) => APPLE_EPOCH_MS + x * 1000) : []),
  };
}

// ---- time zones, with Intl only ----
interface Wall { y: number; mo: number; d: number; h: number; mi: number; s: number }
const fmts = new Map<string, Intl.DateTimeFormat>();
function formatter(tz: string): Intl.DateTimeFormat {
  let f = fmts.get(tz);
  if (!f) {
    try { f = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" }); }
    catch { f = formatter("UTC"); }
    fmts.set(tz, f);
  }
  return f;
}
export function wall(ms: number, tz: string): Wall {
  const p: Record<string, number> = {};
  for (const part of formatter(tz).formatToParts(new Date(ms))) if (part.type !== "literal") p[part.type] = Number(part.value);
  return { y: p.year!, mo: p.month!, d: p.day!, h: p.hour! % 24, mi: p.minute!, s: p.second! };
}
/** The moment a wall clock shows in a zone. In the hour a clock skips, it gives the moment after. */
export function fromWall(w: Wall, tz: string): number {
  const asUtc = Date.UTC(w.y, w.mo - 1, w.d, w.h, w.mi, w.s);
  let guess = asUtc;
  for (let i = 0; i < 3; i++) {
    const got = wall(guess, tz);
    const off = Date.UTC(got.y, got.mo - 1, got.d, got.h, got.mi, got.s) - guess;
    const next = asUtc - off;
    if (next === guess) break;
    guess = next;
  }
  return guess;
}
export const dayStart = (d: Day, tz: string): number => fromWall({ y: d.year, mo: d.month, d: d.day, h: 0, mi: 0, s: 0 }, tz);
export const dayOf = (ms: number, tz: string): Day => { const w = wall(ms, tz); return { year: w.y, month: w.mo, day: w.d }; };
export const addDays = (d: Day, n: number): Day => { const t = new Date(Date.UTC(d.year, d.month - 1, d.day + n)); return { year: t.getUTCFullYear(), month: t.getUTCMonth() + 1, day: t.getUTCDate() }; };
export const sameDay = (a: Day, b: Day): boolean => a.year === b.year && a.month === b.month && a.day === b.day;
export const cmpDay = (a: Day, b: Day): number => a.year - b.year || a.month - b.month || a.day - b.day;

function repeatStart(e: CalEvent, index: number): number | null {
  const w = wall(e.start, e.tz);
  if (e.repeat!.freq === "daily" || e.repeat!.freq === "weekly") {
    const d = addDays({ year: w.y, month: w.mo, day: w.d }, index * (e.repeat!.freq === "daily" ? 1 : 7));
    return fromWall({ ...w, y: d.year, mo: d.month, d: d.day }, e.tz);
  }
  let y = w.y, mo = w.mo;
  if (e.repeat!.freq === "monthly") { const t = w.mo - 1 + index; y += Math.floor(t / 12); mo = (((t % 12) + 12) % 12) + 1; } else y += index;
  const check = new Date(Date.UTC(y, mo - 1, w.d));
  if (check.getUTCMonth() !== mo - 1) return null; // that day doesn't exist that month
  return fromWall({ ...w, y, mo }, e.tz);
}

/** Every occurrence that touches [lower, upper) (milliseconds). */
export function occurrences(e: CalEvent, lower: number, upper: number): Occurrence[] {
  const length = Math.max(e.end - e.start, 0);
  const span = length + (e.allDay ? DAY : 0);
  const make = (begin: number): Occurrence | null => {
    const finish = begin + span;
    const touches = begin < upper && (finish > lower || (span === 0 && begin >= lower));
    return touches && !e.skipped.has(begin) ? { event: e, start: begin, end: begin + length } : null;
  };
  if (!e.repeat) { const o = make(e.start); return o ? [o] : []; }
  const approx = { daily: DAY, weekly: 7 * DAY, monthly: 31 * DAY, yearly: 366 * DAY }[e.repeat.freq];
  let index = Math.max(0, Math.min(Math.floor((lower - span - e.start) / approx) - 1, 2_000_000));
  const out: Occurrence[] = [];
  for (let misses = 0; misses < 500; index++) {
    const begin = repeatStart(e, index);
    if (begin === null) { misses++; continue; }
    if (begin >= upper) break;
    if (e.repeat.until && cmpDay(dayOf(begin, e.tz), e.repeat.until) > 0) break;
    const o = make(begin);
    if (o) out.push(o);
  }
  return out;
}
