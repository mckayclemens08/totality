// QuickAddParser.swift, ported rule for rule: dates, times, tags, priority and places read out of a line
// typed in English. Nothing typed leaves this browser except sealed. Words it doesn't understand stay in the title.
import { addDays, addUnits, cmpDay, weekday, type Cal, type Day } from "./repeat";

export type Part = "when" | "time" | "deadline" | "tag" | "priority" | "place";
export interface Piece { start: number; end: number; part: Part }
export interface Parsed {
  title: string; when: Day | null; isEvening: boolean; time: { hour: number; minute: number } | null; deadline: Day | null;
  tags: string[]; priority: number; place: "inbox" | "anytime" | "someday" | null; pieces: Piece[];
}
interface Word { start: number; end: number; folded: string }
export interface Ctx extends Cal { today: Day; monthFirst: boolean }

const fold = (s: string): string => s.toLowerCase().normalize("NFD").replace(/\p{M}/gu, "");
const isSpace = (c: string): boolean => /\s/u.test(c);

function split(text: string): Word[] {
  const words: Word[] = [];
  let start: number | null = null;
  for (let i = 0; i < text.length; i++) {
    if (isSpace(text[i]!)) { if (start !== null) words.push(make(text, start, i)); start = null; }
    else if (start === null) start = i;
  }
  if (start !== null) words.push(make(text, start, text.length));
  return words;
}
function make(text: string, start: number, end: number): Word {
  let f = fold(text.slice(start, end));
  while (f.length > 1 && [",", ".", ";", ":", "!", "?", ")"].includes(f[f.length - 1]!)) {
    if (f.endsWith("!") && f.startsWith("!")) break;
    f = f.slice(0, -1);
  }
  return { start, end, folded: f };
}

const PRIORITIES: Record<string, number> = { "!high": 3, "!h": 3, "!3": 3, "!!!": 3, "!medium": 2, "!med": 2, "!m": 2, "!2": 2, "!!": 2, "!low": 1, "!l": 1, "!1": 1 };
const WEEKDAYS: Record<string, number> = { sunday: 1, monday: 2, tuesday: 3, wednesday: 4, thursday: 5, friday: 6, saturday: 7 };
const SHORT_WEEKDAYS: Record<string, number> = { sun: 1, mon: 2, tue: 3, tues: 3, wed: 4, thu: 5, thur: 5, thurs: 5, fri: 6, sat: 7 };
const MONTHS: Record<string, number> = {
  january: 1, jan: 1, february: 2, feb: 2, march: 3, mar: 3, april: 4, apr: 4, may: 5, june: 6, jun: 6, july: 7, jul: 7,
  august: 8, aug: 8, september: 9, sep: 9, sept: 9, october: 10, oct: 10, november: 11, nov: 11, december: 12, dec: 12,
};
const COUNTS: Record<string, number> = { a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10 };
const own = <T>(o: Record<string, T>, k: string | null): T | undefined => (k !== null && Object.prototype.hasOwnProperty.call(o, k) ? o[k] : undefined);
const digits = (s: string): boolean => s.length > 0 && /^[0-9]+$/.test(s);
const toInt = (s: string | null): number | null => (s !== null && /^[+-]?[0-9]+$/.test(s) ? parseInt(s, 10) : null);

function dayNumber(w: string): number | null {
  let d = w;
  for (const suffix of ["st", "nd", "rd", "th"]) if (d.endsWith(suffix)) d = d.slice(0, -suffix.length);
  const n = toInt(d);
  return n !== null && n >= 1 && n <= 31 && d.length <= 2 ? n : null;
}
const year = (w: string): number | null => { const n = toInt(w); return w.length === 4 && n !== null && n >= 2000 && n <= 2200 ? n : null; };
function valid(y: number, m: number, d: number): Day | null {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCMonth() === m - 1 && t.getUTCDate() === d ? { year: y, month: m, day: d } : null;
}

class Reader {
  result: Parsed = { title: "", when: null, isEvening: false, time: null, deadline: null, tags: [], priority: 0, place: null, pieces: [] };
  private i = 0;
  constructor(private words: Word[], private c: Ctx) {}

  run(): void { while (this.i < this.words.length) this.i += this.step() ?? 1; }
  private w(o: number): string | null { return this.words[this.i + o]?.folded ?? null; }
  private mark(count: number, part: Part, from = 0): void {
    this.result.pieces.push({ start: this.words[this.i + from]!.start, end: this.words[this.i + from + count - 1]!.end, part });
  }

  private step(): number | null {
    const first = this.w(0);
    if (first === null) return null;
    if (first === "every" || first === "each") return 2;
    const r = this.result;
    if (first.startsWith("#") && r.tags.length < 20) {
      const tag = first.slice(1).replace(/^\/+|\/+$/g, "");
      if (tag && /^[\p{L}\p{N}\-_/]+$/u.test(tag)) {
        if (!r.tags.includes(tag)) r.tags.push(tag);
        this.mark(1, "tag");
        return 1;
      }
    }
    const pr = own(PRIORITIES, first);
    if (first.startsWith("!") && r.priority === 0 && pr !== undefined) { r.priority = pr; this.mark(1, "priority"); return 1; }
    if (r.place === null && r.when === null && (first === "someday" || first === "anytime")) {
      r.place = first === "someday" ? "someday" : "anytime"; this.mark(1, "place"); return 1;
    }
    if (r.deadline === null && ["due", "by", "deadline"].includes(first)) {
      const d = this.date(1, true);
      if (d) { r.deadline = d[0]; this.mark(1 + d[1], "deadline"); return 1 + d[1]; }
    }
    if (r.when === null) {
      const d = this.date(0, false);
      if (d) { r.when = d[0]; if (d[2]) r.isEvening = true; this.mark(d[1], "when"); return d[1]; }
    }
    if (r.time === null) {
      const t = this.time(0);
      if (t) { r.time = t[0]; this.mark(t[1], "time"); return t[1]; }
    }
    return null;
  }

  private date(o: number, loose: boolean): [Day, number, boolean] | null {
    const first = this.w(o);
    if (first === null) return null;
    if (first === "on") { const d = this.date(o + 1, true); if (d) return [d[0], d[1] + 1, d[2]]; }
    const p = this.plainDate(o, loose);
    if (p) {
      const next = this.w(o + p[1]);
      if (next === "evening" || next === "night") return [p[0], p[1] + 1, true];
      return [p[0], p[1], false];
    }
    if (first === "tonight") return [this.c.today, 1, true];
    if (first === "this" && this.w(o + 1) === "evening") return [this.c.today, 2, true];
    return null;
  }

  private nearest(wd: number, includingToday: boolean): Day {
    let ahead = (wd - weekday(this.c.today) + 7) % 7;
    if (ahead === 0 && !includingToday) ahead = 7;
    return addDays(this.c.today, ahead);
  }
  private weekStart(d: Day): Day { return addDays(d, -((weekday(d) - this.c.firstWeekday + 7) % 7)); }
  private upcoming(m: number, d: number): Day | null {
    const t = this.c.today;
    const thisYear = valid(t.year, m, d);
    if (thisYear && cmpDay(thisYear, t) >= 0) return thisYear;
    return valid(t.year + 1, m, d);
  }

  private plainDate(o: number, loose: boolean): [Day, number] | null {
    const first = this.w(o)!, today = this.c.today;
    if (first === "today" || first === "tod") return [today, 1];
    if (["tomorrow", "tmr", "tmrw", "tomorow", "tommorow"].includes(first)) return [addDays(today, 1), 1];
    if (first === "day" && this.w(o + 1) === "after" && this.w(o + 2) === "tomorrow") return [addDays(today, 2), 3];
    const wd = own(WEEKDAYS, first) ?? (loose ? own(SHORT_WEEKDAYS, first) : undefined);
    if (wd !== undefined) return [this.nearest(wd, false), 1];
    const second = this.w(o + 1);
    if ((first === "this" || first === "next") && second !== null) {
      const wd2 = own(WEEKDAYS, second) ?? own(SHORT_WEEKDAYS, second);
      if (wd2 !== undefined) {
        if (first === "this") return [this.nearest(wd2, true), 2];
        const soonest = this.nearest(wd2, false);
        return [cmpDay(this.weekStart(soonest), this.weekStart(today)) === 0 ? addDays(soonest, 7) : soonest, 2];
      }
      if (second === "week" || second === "wk") {
        if (first !== "next") return null;
        return [addDays(today, 7 - ((weekday(today) - this.c.firstWeekday + 7) % 7)), 2];
      }
      if (second === "month" && first === "next") {
        const index = today.year * 12 + today.month; // the month after, counted from zero
        return [{ year: Math.floor(index / 12), month: (index % 12) + 1, day: 1 }, 2];
      }
      if (second === "weekend") return [this.nearest(7, true), 2];
    }
    if (first === "weekend" && loose) return [this.nearest(7, true), 1];
    if (first === "in" && second !== null) {
      const amount = toInt(second) ?? own(COUNTS, second) ?? null;
      const unit = this.w(o + 2);
      if (amount !== null && amount > 0 && amount < 1000 && unit !== null) {
        if (unit === "day" || unit === "days") return [addDays(today, amount), 3];
        if (["week", "weeks", "wk", "wks"].includes(unit)) return [addDays(today, amount * 7), 3];
        if (unit === "month" || unit === "months") return [addUnits(amount, "month", today), 3];
      }
    }
    const month = own(MONTHS, first);
    if (month !== undefined) {
      const dn = second !== null ? dayNumber(second) : null;
      if (dn !== null) {
        const y = this.w(o + 2), yy = y !== null ? year(y) : null, v = yy !== null ? valid(yy, month, dn) : null;
        if (v) return [v, 3];
        const u = this.upcoming(month, dn);
        return u ? [u, 2] : null;
      }
    }
    const dn = dayNumber(first), m2 = own(MONTHS, second);
    if (dn !== null && m2 !== undefined) {
      const y = this.w(o + 2), yy = y !== null ? year(y) : null, v = yy !== null ? valid(yy, m2, dn) : null;
      if (v) return [v, 3];
      const u = this.upcoming(m2, dn);
      return u ? [u, 2] : null;
    }
    const iso = first.split("-").map(toInt).filter((n): n is number => n !== null);
    if (iso.length === 3 && first.length === 10) { const v = valid(iso[0]!, iso[1]!, iso[2]!); if (v) return [v, 1]; }
    const slashed = first.split("/");
    if ((slashed.length === 2 || slashed.length === 3) && slashed.every(digits)) {
      const n = slashed.map((s) => parseInt(s, 10));
      const [m, d] = this.c.monthFirst ? [n[0]!, n[1]!] : [n[1]!, n[0]!];
      if (n.length === 3) { const y = n[2]! < 100 ? 2000 + n[2]! : n[2]!; const v = valid(y, m, d); return v ? [v, 1] : null; }
      const u = this.upcoming(m, d);
      return u ? [u, 1] : null;
    }
    return null;
  }

  private time(o: number): [{ hour: number; minute: number }, number] | null {
    const first = this.w(o);
    if (first === null) return null;
    if (first === "at" || first === "@") {
      const next = this.w(o + 1);
      if (next === null) return null;
      const c = this.clock(o + 1);
      if (c) return [c[0], c[1] + 1];
      const hour = toInt(next);
      if (hour !== null && hour >= 0 && hour <= 23 && next.length <= 2 && digits(next)) {
        return [{ hour: hour >= 1 && hour <= 6 ? hour + 12 : hour, minute: 0 }, 2];
      }
      return null;
    }
    return this.clock(o);
  }

  private clock(o: number): [{ hour: number; minute: number }, number] | null {
    const first = this.w(o);
    if (first === null) return null;
    if (first === "noon" || first === "midday") return [{ hour: 12, minute: 0 }, 1];
    let text = first, used = 1, half: "am" | "pm" | null = null;
    for (const suffix of ["am", "pm", "a.m", "p.m", "a", "p"]) {
      if (text.endsWith(suffix) && text.length > suffix.length) {
        const rest = text.slice(0, -suffix.length);
        if (/[0-9]$/.test(rest)) { half = suffix.startsWith("a") ? "am" : "pm"; text = rest; break; }
      }
    }
    const next = this.w(o + 1);
    if (half === null && next !== null && ["am", "pm", "a.m", "p.m"].includes(next)) { half = next.startsWith("a") ? "am" : "pm"; used = 2; }
    const parts = text.split(/[:.]/);
    if (parts.length < 1 || parts.length > 2 || !parts.every(digits) || parts[0]!.length > 2 || (parts.length === 2 && parts[1]!.length !== 2)) return null;
    let hour = parseInt(parts[0]!, 10);
    const minute = parts.length === 2 ? parseInt(parts[1]!, 10) : 0;
    if (half) {
      if (hour < 1 || hour > 12) return null;
      if (half === "pm" && hour !== 12) hour += 12;
      if (half === "am" && hour === 12) hour = 0;
    } else if (parts.length === 1 || text.includes(".")) return null;
    return hour >= 0 && hour < 24 && minute >= 0 && minute < 60 ? [{ hour, minute }, used] : null;
  }
}

/** QuickAddParser.title(of:without:). */
function titleOf(text: string, pieces: Piece[]): string {
  let kept = "", at = 0;
  for (const p of [...pieces].sort((a, b) => a.start - b.start)) {
    if (p.start < at) continue;
    kept += text.slice(at, p.start) + " ";
    at = p.end;
  }
  kept += text.slice(at);
  const tidy = kept.split(/\s+/u).filter((w) => w && ![",", ".", ";", "-", "–"].includes(w));
  let title = tidy.join(" ");
  while (title && [",", ";", "-", "–"].includes(title[title.length - 1]!)) title = title.slice(0, -1);
  return title.trim();
}

export function parse(text: string, c: Ctx): Parsed {
  const reader = new Reader(split(text), c);
  reader.run();
  const p = reader.result;
  p.pieces.sort((a, b) => a.start - b.start);
  p.title = titleOf(text, p.pieces);
  if (p.time && !p.when && p.place !== "someday") p.when = p.deadline ?? c.today;
  if (p.isEvening && !p.when) p.when = c.today;
  if (p.when && p.place === "someday") p.place = null;
  return p;
}

export function parseLines(text: string, c: Ctx): Parsed[] {
  return text.split(new RegExp("\\r\\n|[\\n\\r\\u2028\\u2029\\u0085\\u000b\\u000c]")).flatMap((line) => {
    const cleaned = line.trim().replace(/^([-*•]\s*(\[[ xX]\]\s*)?|\d+[.)]\s*)/u, "");
    return cleaned.trim() ? [parse(cleaned, c)] : [];
  });
}

/** ParsedTask.task(defaultPlace:defaultWhen:order:now:), as the fields a new task takes. */
export function taskFields(p: Parsed, defaultPlace: "inbox" | "anytime" | "someday", defaultWhen: Day | null): Record<string, unknown> {
  const place = p.place ?? defaultPlace;
  const when = p.when ?? (place === "someday" ? null : defaultWhen);
  const out: Record<string, unknown> = { title: p.title, place: when === null ? place : place === "inbox" ? "anytime" : place, isEvening: when === null ? false : p.isEvening, tags: p.tags, priority: p.priority };
  if (when) out.when = when;
  if (when && p.time) out.time = p.time;
  if (p.deadline) out.deadline = p.deadline;
  return out;
}

/** Whether this browser's region writes the month before the day, as DateFormatter's "Md" template says. */
export function monthFirst(): boolean {
  try {
    const parts = new Intl.DateTimeFormat(undefined, { month: "numeric", day: "numeric" }).formatToParts(new Date(2026, 10, 20));
    return parts.findIndex((p) => p.type === "month") < parts.findIndex((p) => p.type === "day");
  } catch { return true; }
}
