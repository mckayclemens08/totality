// The Clock's synced record (issue 204) as the iPhone writes it: ClockItems, JSON-encoded by Swift. Dates
// are seconds since 1 January 2001, and `removed` is Swift's dictionary form, [id, date, id, date, …].
// Alarms and timers aren't here: they stay on the iPhone that set them.

export interface City { id: string; name: string; timeZoneID: string; order: number; updatedAt: number }
export interface Preset { id: string; name: string; seconds: number; order: number; updatedAt: number }
export interface Stopwatch { startedAt: number | null; banked: number; laps: number[]; updatedAt: number }
export interface ClockItems { cities: City[]; presets: Preset[]; stopwatch: Stopwatch; removed: Map<string, number> }

const APPLE_EPOCH = 978_307_200;
/** Swift's Date as milliseconds since 1970. */
export const appleDate = (s: unknown): number => (typeof s === "number" && Number.isFinite(s) ? (s + APPLE_EPOCH) * 1000 : 0);

const str = (v: unknown): string => (typeof v === "string" ? v : "");
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const list = (v: unknown): Record<string, unknown>[] => (Array.isArray(v) ? v.filter((x) => x && typeof x === "object") : []);

export function parseItems(json: unknown): ClockItems {
  const o = (json && typeof json === "object" ? json : {}) as Record<string, unknown>;
  const removed = new Map<string, number>();
  const pairs = Array.isArray(o.removed) ? o.removed : [];
  for (let i = 0; i + 1 < pairs.length; i += 2) if (typeof pairs[i] === "string") removed.set(String(pairs[i]).toLowerCase(), appleDate(pairs[i + 1]));
  const w = (o.stopwatch && typeof o.stopwatch === "object" ? o.stopwatch : {}) as Record<string, unknown>;
  return {
    cities: list(o.cities).map((c) => ({ id: str(c.id).toLowerCase(), name: str(c.name), timeZoneID: str(c.timeZoneID), order: num(c.order), updatedAt: appleDate(c.updatedAt) })),
    presets: list(o.presets).map((p) => ({ id: str(p.id).toLowerCase(), name: str(p.name), seconds: num(p.seconds), order: num(p.order), updatedAt: appleDate(p.updatedAt) })),
    stopwatch: { startedAt: typeof w.startedAt === "number" ? appleDate(w.startedAt) : null, banked: num(w.banked), laps: Array.isArray(w.laps) ? w.laps.map(num) : [], updatedAt: appleDate(w.updatedAt) },
    removed,
  };
}

const kept = (removed: Map<string, number>) => (x: { id: string; updatedAt: number }) => !(removed.has(x.id) && x.updatedAt <= (removed.get(x.id) ?? 0));
const byOrder = (a: { order: number; id: string }, b: { order: number; id: string }) => a.order - b.order || a.id.localeCompare(b.id);

/** What the iPhone shows: items not removed since they last changed, in the person's order. */
export const shownCities = (c: ClockItems): City[] => c.cities.filter(kept(c.removed)).sort(byOrder);
export const shownPresets = (c: ClockItems): Preset[] => c.presets.filter(kept(c.removed)).sort(byOrder);

/** Two copies as one, the later of each, as ClockItems.merged does. */
export function merge(a: ClockItems, b: ClockItems): ClockItems {
  const later = <T extends { id: string; updatedAt: number }>(x: T[], y: T[]): T[] => {
    const m = new Map<string, T>();
    for (const i of [...x, ...y]) { const had = m.get(i.id); if (!had || i.updatedAt > had.updatedAt) m.set(i.id, i); }
    return [...m.values()];
  };
  const removed = new Map(a.removed);
  for (const [k, v] of b.removed) removed.set(k, Math.max(v, removed.get(k) ?? 0));
  return { cities: later(a.cities, b.cities), presets: later(a.presets, b.presets), stopwatch: b.stopwatch.updatedAt > a.stopwatch.updatedAt ? b.stopwatch : a.stopwatch, removed };
}

export const elapsed = (w: Stopwatch, now: number): number => w.banked + (w.startedAt === null ? 0 : Math.max(0, (now - w.startedAt) / 1000));

/** "12:48.07", as the iPhone's stopwatch. */
export function stopwatchText(seconds: number): string {
  const cs = Math.floor(Math.max(0, seconds) * 100);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(Math.floor(cs / 6000))}:${pad(Math.floor(cs / 100) % 60)}.${pad(cs % 100)}`;
}

/** "3 h ahead", "2 h 30 min behind", "Same time", as ClockMath.offset. */
export function offsetText(zone: string, local: string, now: number): string {
  const diff = Math.round((zoneOffset(zone, now) - zoneOffset(local, now)) / 60_000);
  if (diff === 0) return "Same time";
  const m = Math.abs(diff), hours = Math.floor(m / 60), rest = m % 60;
  const amount = rest === 0 ? `${hours} h` : hours === 0 ? `${rest} min` : `${hours} h ${rest} min`;
  return `${amount} ${diff > 0 ? "ahead" : "behind"}`;
}

/** A zone's offset from UTC at `now`, in milliseconds, from the browser's own time zone data. */
export function zoneOffset(zone: string, now: number): number {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: zone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" }).formatToParts(new Date(now));
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? 0);
  const asUTC = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  return asUTC - Math.floor(now / 1000) * 1000;
}

export const lengthText = (seconds: number): string => {
  const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60;
  const out = [h ? `${h} h` : "", m ? `${m} min` : "", s || (!h && !m) ? `${s} s` : ""].filter(Boolean);
  return out.join(" ");
};
