import { h } from "../dom";
import { loadAll } from "../sealedjson";
import type { Ctx } from "../reader/view";
import { addDays, cmpDay, dayOf, dayStart, occurrences, parseEvent, sameDay, wall, type CalEvent, type Day, type Occurrence } from "./model";

type Mode = "day" | "week" | "month";
const HOUR = 48; // px per hour
const local = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const dow = (d: Day) => new Date(Date.UTC(d.year, d.month - 1, d.day)).getUTCDay();
const startOfWeek = (d: Day) => addDays(d, -dow(d));
const clock = (ms: number) => new Date(ms).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit", timeZone: local });

let run = 0;
export const stopCalendar = (): void => { run++; };

/** An all-day event is a plain date: midnight GMT on its first day, and again on its last. */
function allDayDays(o: Occurrence): Day[] {
  const first = dayOf(o.start, "GMT"), last = dayOf(o.end, "GMT");
  const out: Day[] = [];
  for (let d = first; cmpDay(d, last) <= 0 && out.length < 400; d = addDays(d, 1)) out.push(d);
  return out;
}

function on(events: CalEvent[], d: Day): { timed: Occurrence[]; allDay: Occurrence[] } {
  const lo = dayStart(d, local), hi = dayStart(addDays(d, 1), local);
  const timed: Occurrence[] = [], allDay: Occurrence[] = [];
  for (const e of events) {
    if (e.allDay) { for (const o of occurrences(e, Date.UTC(d.year, d.month - 1, d.day) - 400 * 86_400_000, Date.UTC(d.year, d.month - 1, d.day) + 86_400_000)) if (allDayDays(o).some((x) => sameDay(x, d))) allDay.push(o); }
    else for (const o of occurrences(e, lo, hi)) timed.push(o);
  }
  timed.sort((a, b) => a.start - b.start);
  return { timed, allDay };
}

function chip(o: Occurrence, pick: (o: Occurrence) => void, cls = "ev"): HTMLElement {
  return h("button", { type: "button", class: cls, onclick: () => pick(o) }, o.event.title.trim() || "Untitled event");
}

function timedColumn(d: Day, events: CalEvent[], pick: (o: Occurrence) => void): HTMLElement {
  const col = h("div", { class: "daycol" });
  const { timed } = on(events, d);
  // Overlapping events sit side by side.
  const lanes: number[] = [];
  const placed = timed.map((o) => {
    let lane = lanes.findIndex((end) => end <= o.start);
    if (lane < 0) { lane = lanes.length; lanes.push(0); }
    lanes[lane] = o.end;
    return { o, lane };
  });
  for (const { o, lane } of placed) {
    const w = wall(o.start, local), mins = w.h * 60 + w.mi;
    const dur = Math.max((o.end - o.start) / 60000, 30);
    const b = chip(o, pick, "ev block");
    // Set through the style object, not a style attribute, which the page's CSP forbids.
    const n = Math.max(lanes.length, 1);
    Object.assign(b.style, { top: `${(mins / 60) * HOUR}px`, height: `${(Math.min(dur, 1440 - mins) / 60) * HOUR - 2}px`, left: `${(lane / n) * 100}%`, width: `${100 / n}%` });
    col.append(b);
  }
  return col;
}

function weekLike(days: Day[], events: CalEvent[], pick: (o: Occurrence) => void, today: Day): HTMLElement {
  const head = h("div", { class: "grid-head" }, h("div", {}), ...days.map((d) => h("div", { class: "dayhead" + (sameDay(d, today) ? " today" : "") }, h("span", { class: "sub" }, WEEKDAYS[dow(d)]!), h("b", {}, String(d.day)))));
  const strip = h("div", { class: "grid-head allday" }, h("div", { class: "sub" }, "all day"), ...days.map((d) => h("div", { class: "alldaycell" }, ...on(events, d).allDay.map((o) => chip(o, pick, "ev pill")))));
  const hours = h("div", { class: "hours" }, ...Array.from({ length: 24 }, (_, i) => h("div", { class: "hour sub" }, i === 0 ? "" : new Date(2000, 0, 1, i).toLocaleTimeString(undefined, { hour: "numeric" }))));
  const body = h("div", { class: "grid-body" }, hours, ...days.map((d) => timedColumn(d, events, pick)));
  for (const r of [head, strip, body]) r.style.gridTemplateColumns = `56px repeat(${days.length},1fr)`;
  const scroll = h("div", { class: "grid-scroll" }, body);
  queueMicrotask(() => { scroll.scrollTop = 7 * HOUR; });
  return h("div", { class: "weekgrid" }, head, strip, scroll);
}

function month(anchor: Day, events: CalEvent[], pick: (o: Occurrence) => void, today: Day): HTMLElement {
  const first = { year: anchor.year, month: anchor.month, day: 1 };
  const start = startOfWeek(first);
  const grid = h("div", { class: "monthgrid" }, ...WEEKDAYS.map((w) => h("div", { class: "sub mhead" }, w)));
  for (let i = 0; i < 42; i++) {
    const d = addDays(start, i);
    if (i >= 35 && d.month !== anchor.month) break;
    const { timed, allDay } = on(events, d);
    const all = [...allDay, ...timed];
    const cell = h("div", { class: "mcell" + (d.month !== anchor.month ? " out" : "") + (sameDay(d, today) ? " today" : "") }, h("div", { class: "mnum" }, String(d.day)),
      ...all.slice(0, 3).map((o) => chip(o, pick, "ev pill")), all.length > 3 ? h("div", { class: "sub" }, `+${all.length - 3} more`) : null);
    grid.append(cell);
  }
  return grid;
}

export async function showCalendar(into: HTMLElement, ctx: Ctx): Promise<void> {
  const mine = ++run;
  let mode: Mode = "week";
  const t = dayOf(Date.now(), local);
  let anchor: Day = t;
  let events: CalEvent[] = [];
  const bodyHost = h("div", {}), title = h("h1", {}), detail = h("section", { class: "panel detail" }, h("p", { class: "status" }, "Pick an event to see it here."));
  const note = h("p", { class: "status", role: "status" }, "Opening your calendar…");

  const pick = (o: Occurrence) => {
    const e = o.event;
    const when = e.allDay ? "All day" : `${new Date(o.start).toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", timeZone: local })}, ${clock(o.start)} to ${clock(o.end)}`;
    detail.replaceChildren(h("h2", { class: "doc-title small" }, e.title.trim() || "Untitled event"), h("p", { class: "sub" }, when),
      ...[e.location ? h("p", {}, e.location) : null, e.repeat ? h("p", { class: "sub" }, `Repeats ${e.repeat.freq === "daily" ? "every day" : e.repeat.freq === "weekly" ? "every week" : e.repeat.freq === "monthly" ? "every month" : "every year"}`) : null,
      e.notes ? h("p", { class: "plain-notes" }, e.notes) : null].filter((x): x is HTMLParagraphElement => !!x));
  };

  const draw = () => {
    const days = mode === "day" ? [anchor] : Array.from({ length: 7 }, (_, i) => addDays(startOfWeek(anchor), i));
    title.textContent = mode === "month" ? `${MONTHS[anchor.month - 1]} ${anchor.year}` : mode === "day"
      ? new Date(Date.UTC(anchor.year, anchor.month - 1, anchor.day)).toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "UTC" })
      : `${MONTHS[days[0]!.month - 1]} ${days[0]!.day} – ${days[6]!.month !== days[0]!.month ? MONTHS[days[6]!.month - 1] + " " : ""}${days[6]!.day}, ${days[6]!.year}`;
    bodyHost.replaceChildren(mode === "month" ? month(anchor, events, pick, t) : weekLike(days, events, pick, t));
  };
  const step = (dir: number) => { anchor = mode === "month" ? addDays({ year: anchor.year, month: anchor.month + dir, day: 1 }, 0) : addDays(anchor, dir * (mode === "week" ? 7 : 1)); if (mode === "month") anchor = { year: new Date(Date.UTC(anchor.year, anchor.month - 1, 1)).getUTCFullYear(), month: new Date(Date.UTC(anchor.year, anchor.month - 1, 1)).getUTCMonth() + 1, day: 1 }; draw(); };
  const seg = (m: Mode, label: string) => h("button", { type: "button", class: "seg", onclick: () => { mode = m; for (const b of Array.from(segs.children)) b.classList.toggle("on", b.textContent === label); draw(); } }, label);
  const segs = h("div", { class: "segs", role: "group", "aria-label": "View" }, seg("day", "Day"), seg("week", "Week"), seg("month", "Month"));
  segs.children[1]!.classList.add("on");

  into.replaceChildren(
    h("div", { class: "page-head cal-head" }, title, h("button", { type: "button", class: "quiet small-btn", "aria-label": "Previous", onclick: () => step(-1) }, "‹"),
      h("button", { type: "button", class: "quiet small-btn", onclick: () => { anchor = t; draw(); } }, "Today"),
      h("button", { type: "button", class: "quiet small-btn", "aria-label": "Next", onclick: () => step(1) }, "›"), segs),
    note, h("div", { class: "reader" }, h("section", { class: "panel calpanel" }, bodyHost), detail));
  draw();
  try {
    const { items, unreadable } = await loadAll(await ctx.token(), "event", "event");
    if (mine !== run) return;
    events = items.map((i) => parseEvent(i.id, i.json)).filter((e): e is CalEvent => !!e);
    note.textContent = events.length ? (unreadable ? `${unreadable} event${unreadable === 1 ? "" : "s"} didn't open with your key and ${unreadable === 1 ? "is" : "are"} hidden.` : "") : "No events yet. Add them on your iPhone and they appear here.";
    draw();
  } catch (e) {
    if (mine === run) note.textContent = e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your calendar. Check your connection.";
  }
}
