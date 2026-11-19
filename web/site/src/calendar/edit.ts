// Changing events the way CalendarModel.swift does: the same form (EventDraft), the same "this event only"
// and "all of them" rules, and CalendarVault's conflict rule. An event is kept as the JSON the iPhone sealed,
// so parts this version doesn't know ride along untouched.
import { sha256 } from "@noble/hashes/sha2.js";
import { addDays, cmpDay, dayOf, dayStart, fromWall, parseEvent, wall, type CalEvent, type Day, type Occurrence } from "./model";

export type Raw = Record<string, unknown>;
const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);
export const ALL_DAY_ZONE = "GMT";
export const REMINDER_CHOICES: (number | null)[] = [null, 0, 5, 10, 15, 30, 60, 1_440];
export type Freq = "daily" | "weekly" | "monthly" | "yearly";
export type Scope = "this" | "all";

/** Swift writes a Date as seconds since 2001. A whole second stays a whole number, so a skipped start matches exactly. */
export function toApple(ms: number): number {
  const s = (ms - APPLE_EPOCH_MS) / 1000;
  const r = Math.round(s * 1000) / 1000;
  return Math.abs(r - Math.round(r)) < 1e-6 ? Math.round(r) : r;
}
export const fromApple = (s: number): number => APPLE_EPOCH_MS + s * 1000;

let makeID = (): string => crypto.randomUUID().toUpperCase();
export const setIDMaker = (f: () => string): void => { makeID = f; };

/** EventDraft: what the form holds. Times are moments in milliseconds; all-day uses their days in `display`. */
export interface Draft {
  title: string; location: string; notes: string; start: number; end: number; isAllDay: boolean;
  frequency: Freq | null; until: Day | null; reminderMinutes: number | null; attachments: Raw[];
}

export const reminderName = (m: number | null): string =>
  m === null ? "None" : m === 0 ? "At the start" : m === 60 ? "1 hour before" : m === 1_440 ? "1 day before" : `${m} minutes before`;
export const freqName = (f: Freq): string => ({ daily: "Every day", weekly: "Every week", monthly: "Every month", yearly: "Every year" })[f];

/** Swift's String.trimmingCharacters(in: .whitespacesAndNewlines). */
const EDGES = new RegExp("^[\\s\\u0085\\u2028\\u2029]+|[\\s\\u0085\\u2028\\u2029]+$", "gu");
const cleaned = (s: string): string => s.replace(EDGES, "");

/** EventDraft(occurrence:display:). */
export function draftFor(o: Occurrence, raw: Raw, display: string): Draft {
  const e = o.event;
  let start = o.start, end = o.end;
  if (e.allDay) {
    const s = dayOf(o.start, e.tz), f = dayOf(o.end, e.tz);
    start = dayStart(s, display); end = dayStart(f, display);
  }
  const rule = raw.repeatRule as { until?: Day } | undefined;
  return {
    title: e.title, location: e.location, notes: e.notes, start, end, isAllDay: e.allDay,
    frequency: e.repeat?.freq ?? null, until: e.repeat && rule?.until ? { ...e.repeat.until! } : null,
    reminderMinutes: typeof raw.reminderMinutes === "number" ? raw.reminderMinutes : null,
    attachments: Array.isArray(raw.attachments) ? structuredClone(raw.attachments as Raw[]) : [],
  };
}


/** CalendarModel.newDraft: today starts at the next whole hour, another day at 9 AM (or the hour clicked), an hour long. */
export function newDraft(day: Day, today: Day, now: number, display: string, hour?: number): Draft {
  const at = (h: number) => fromWall({ y: day.year, mo: day.month, d: day.day, h, mi: 0, s: 0 }, display);
  const start = hour !== undefined ? at(hour) : cmpDay(day, today) === 0 ? fromWall({ ...wall(now, display), mi: 0, s: 0 }, display) + 3_600_000 : at(9);
  return { title: "", location: "", notes: "", start, end: start + 3_600_000, isAllDay: false, frequency: null, until: null, reminderMinutes: null, attachments: [] };
}

export class DraftProblem extends Error {}

/** CalendarModel.times(from:keeping:). */
function times(d: Draft, original: Raw | null, display: string): { start: number; end: number; zone: string } {
  const first = dayOf(d.start, display);
  if (d.until && d.frequency && cmpDay(d.until, first) < 0) throw new DraftProblem("A repeat can't end before the event starts.");
  if (d.isAllDay) {
    const last = dayOf(d.end, display);
    if (cmpDay(last, first) < 0) throw new DraftProblem("An event can't end before it starts.");
    return { start: Date.UTC(first.year, first.month - 1, first.day), end: Date.UTC(last.year, last.month - 1, last.day), zone: ALL_DAY_ZONE };
  }
  if (d.end < d.start) throw new DraftProblem("An event can't end before it starts.");
  const zone = original && original.isAllDay !== true && typeof original.timeZoneID === "string" ? original.timeZoneID : display;
  return { start: d.start, end: d.end, zone };
}

const rule = (d: Draft): Raw | undefined => (d.frequency ? { frequency: d.frequency, ...(d.until ? { until: { year: d.until.year, month: d.until.month, day: d.until.day } } : {}) } : undefined);

/** A CalendarEvent as JSONEncoder writes it: optionals left out when nil, skipped written in order. */
function eventJson(f: { id?: string; title: string; location: string; notes: string; start: number; end: number; isAllDay: boolean; timeZoneID: string; repeatRule?: Raw; skipped: number[]; reminderMinutes: number | null; attachments: Raw[]; createdAt: number; updatedAt: number }): Raw {
  const out: Raw = {
    id: f.id ?? makeID(), title: f.title, location: f.location, notes: f.notes, start: toApple(f.start), end: toApple(f.end),
    isAllDay: f.isAllDay, timeZoneID: f.timeZoneID, skipped: [...f.skipped].sort((a, b) => a - b), attachments: f.attachments,
    createdAt: toApple(f.createdAt), updatedAt: toApple(f.updatedAt),
  };
  if (f.repeatRule) out.repeatRule = f.repeatRule;
  if (f.reminderMinutes !== null) out.reminderMinutes = f.reminderMinutes;
  return out;
}

/** CalendarModel.create. */
export function create(d: Draft, now: number, display: string): Raw {
  const t = times(d, null, display);
  return eventJson({ title: cleaned(d.title), location: cleaned(d.location), notes: d.notes, start: t.start, end: t.end, isAllDay: d.isAllDay, timeZoneID: t.zone,
    repeatRule: rule(d), skipped: [], reminderMinutes: d.reminderMinutes, attachments: d.attachments, createdAt: now, updatedAt: now });
}

const skippedOf = (raw: Raw): number[] => (Array.isArray(raw.skipped) ? (raw.skipped as unknown[]).filter((x): x is number => typeof x === "number") : []);
const sortSkipped = (s: number[]): number[] => [...new Set(s)].sort((a, b) => a - b);

/**
 * CalendarModel.update: returns what to save, in order. One occurrence of a series leaves it as its own
 * event (written first, so a failure can make a duplicate but can't lose anything).
 */
export function update(series: Raw, occurrenceStart: number, d: Draft, scope: Scope, now: number, display: string): Raw[] {
  const t = times(d, series, display);
  const out = structuredClone(series);
  if (scope === "this" && series.repeatRule) {
    const single = eventJson({ title: cleaned(d.title), location: cleaned(d.location), notes: d.notes, start: t.start, end: t.end, isAllDay: d.isAllDay, timeZoneID: t.zone,
      skipped: [], reminderMinutes: d.reminderMinutes, attachments: d.attachments, createdAt: now, updatedAt: now });
    out.skipped = sortSkipped([...skippedOf(series), toApple(occurrenceStart)]);
    out.updatedAt = toApple(now);
    return [single, out];
  }
  if (series.repeatRule && (series.isAllDay === true) === d.isAllDay) {
    // Moving one occurrence moves the whole series by the same amount.
    const shift = (t.start - occurrenceStart) / 1000;
    const start = Number(series.start) + shift;
    out.start = start;
    out.end = start + (t.end - t.start) / 1000;
    out.skipped = sortSkipped(skippedOf(series).map((s) => s + shift));
  } else {
    // Switching a series between timed and all-day starts it again from here.
    out.start = toApple(t.start);
    out.end = toApple(t.end);
    out.skipped = [];
  }
  out.title = cleaned(d.title);
  out.location = cleaned(d.location);
  out.notes = d.notes;
  out.isAllDay = d.isAllDay;
  out.timeZoneID = t.zone;
  const r = rule(d);
  if (r) out.repeatRule = r; else delete out.repeatRule;
  if (d.reminderMinutes !== null) out.reminderMinutes = d.reminderMinutes; else delete out.reminderMinutes;
  out.attachments = d.attachments;
  out.updatedAt = toApple(now);
  return [out];
}

/** CalendarModel.delete: one occurrence becomes a skip; otherwise the whole event goes. */
export function remove(series: Raw, occurrenceStart: number, scope: Scope, now: number): { save: Raw } | { tombstone: true } {
  if (scope === "this" && series.repeatRule) {
    const out = structuredClone(series);
    out.skipped = sortSkipped([...skippedOf(series), toApple(occurrenceStart)]);
    out.updatedAt = toApple(now);
    return { save: out };
  }
  return { tombstone: true };
}

// ---- CalendarVault.resolveConflict ----

const KNOWN = ["id", "title", "location", "notes", "start", "end", "isAllDay", "timeZoneID", "repeatRule", "skipped", "reminderMinutes", "attachments", "createdAt", "updatedAt"];
function canon(v: unknown): string {
  if (v === undefined || v === null) return "null";
  if (Array.isArray(v)) return "[" + v.map(canon).join(",") + "]";
  if (typeof v === "object") { const o = v as Raw; return "{" + Object.keys(o).filter((k) => o[k] != null).sort().map((k) => JSON.stringify(k) + ":" + canon(o[k])).join(",") + "}"; }
  if (typeof v === "string") return JSON.stringify(v);
  return JSON.stringify(v);
}
/** CalendarEvent's == : every field Swift knows, the skipped days as a set, IDs in any case. */
export function sameEvent(a: Raw, b: Raw): boolean {
  return KNOWN.every((k) => {
    let x = a[k], y = b[k];
    if (k === "skipped") { x = sortSkipped(skippedOf(a)); y = sortSkipped(skippedOf(b)); }
    if (k === "id") { x = String(x).toLowerCase(); y = String(y).toLowerCase(); }
    if (k === "isAllDay") { x = x === true; y = y === true; }
    return canon(x) === canon(y);
  });
}

export { derivedID } from "../ids";
import { derivedID } from "../ids";

const displayTitle = (e: Raw): string => (typeof e.title === "string" && e.title !== "" ? e.title : "Untitled event");

/**
 * The newer version stays, and an older one that really differs is kept as "(conflict copy)", named for the
 * version it preserves: the row hash of each version (SealedObject.hash), so a retry can't make two.
 */
export function resolve(mine: Raw, theirs: Raw, mineHash: string, theirsHash: string, now: number): { keep: "mine" | "theirs"; copy: Raw | null } {
  const keepMine = Number(mine.updatedAt) >= Number(theirs.updatedAt);
  const older = structuredClone(keepMine ? theirs : mine), newer = keepMine ? mine : theirs;
  older.updatedAt = newer.updatedAt;
  if (sameEvent(older, newer)) return { keep: keepMine ? "mine" : "theirs", copy: null };
  const copy = eventJson({
    id: derivedID(keepMine ? theirsHash : mineHash), title: `${displayTitle(older)} (conflict copy)`, location: String(older.location ?? ""), notes: String(older.notes ?? ""),
    start: fromApple(Number(older.start)), end: fromApple(Number(older.end)), isAllDay: older.isAllDay === true, timeZoneID: String(older.timeZoneID ?? ALL_DAY_ZONE),
    repeatRule: older.repeatRule as Raw | undefined, skipped: skippedOf(older), reminderMinutes: typeof older.reminderMinutes === "number" ? older.reminderMinutes : null,
    attachments: Array.isArray(older.attachments) ? (older.attachments as Raw[]) : [], createdAt: now, updatedAt: now,
  });
  copy.start = older.start; copy.end = older.end; copy.skipped = sortSkipped(skippedOf(older));
  return { keep: keepMine ? "mine" : "theirs", copy };
}

export const asEvent = (raw: Raw): CalEvent | null => parseEvent(String(raw.id).toLowerCase(), raw);
export { addDays };
