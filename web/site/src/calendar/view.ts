// The Calendar on the website, with the iPhone's editing: new events (from the button or a click on an hour or
// a day), every part of the form, "this event only" or "all of them" for repeats, and delete with the same
// question. Everything is sealed in this browser before it's saved (store.ts); this file only draws and asks.
import "./calendar.css";
import { h } from "../dom";
import type { Ctx } from "../reader/view";
import { attachable, type ContentRef } from "../registry";
import { field, input, select, sheet } from "../ui";
import { addDays, cmpDay, dayOf, dayStart, fromWall, occurrences, sameDay, wall, type CalEvent, type Day, type Occurrence } from "./model";
import { draftFor, DraftProblem, freqName, newDraft, REMINDER_CHOICES, reminderName, type Draft, type Freq, type Raw, type Scope } from "./edit";
import { CalendarStore } from "./store";

type Mode = "day" | "week" | "month" | "schedule";
const HOUR = 48; // px per hour
const local = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const SCHEDULE_DAYS = 90;
const dow = (d: Day) => new Date(Date.UTC(d.year, d.month - 1, d.day)).getUTCDay();
const startOfWeek = (d: Day) => addDays(d, -dow(d));
const clock = (ms: number) => new Date(ms).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit", timeZone: local });
const longDay = (d: Day) => new Date(Date.UTC(d.year, d.month - 1, d.day)).toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", timeZone: "UTC" });
const title = (e: CalEvent) => e.title.trim() || "Untitled event";

let run = 0;
let cache: { ctx: Ctx; store: CalendarStore } | null = null;
/** Leaving the Calendar for good (another module, the lock, signing out) drops the opened events from memory. */
export const stopCalendar = (): void => {
  const mine = ++run;
  setTimeout(() => { if (mine === run) cache = null; }, 0);
};

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

// ---- the form's date and time fields, in this browser's zone ----
const pad = (n: number) => String(n).padStart(2, "0");
const dayInput = (ms: number) => { const w = wall(ms, local); return `${w.y}-${pad(w.mo)}-${pad(w.d)}`; };
const timeInput = (ms: number) => { const w = wall(ms, local); return `${dayInput(ms)}T${pad(w.h)}:${pad(w.mi)}`; };
function fromInput(v: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?$/.exec(v);
  return m ? fromWall({ y: +m[1]!, mo: +m[2]!, d: +m[3]!, h: m[4] ? +m[4] : 0, mi: m[5] ? +m[5] : 0, s: 0 }, local) : null;
}
const parseDay = (v: string): Day | null => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v); return m ? { year: +m[1]!, month: +m[2]!, day: +m[3]! } : null; };
const dayText = (d: Day) => `${d.year}-${pad(d.month)}-${pad(d.day)}`;

export async function showCalendar(into: HTMLElement, ctx: Ctx): Promise<void> {
  const mine = ++run;
  let mode: Mode = "week";
  const today = dayOf(Date.now(), local);
  let anchor: Day = today;
  let picked: { id: string; start: number } | null = null;
  const bodyHost = h("div", {}), heading = h("h1", {});
  const detail = h("section", { class: "panel detail", "aria-label": "Event" }, h("p", { class: "status" }, "Pick an event to see it here."));
  const note = h("p", { class: "status", role: "status" }, "Opening your calendar…");
  const status = h("span", { class: "save-status", role: "status", "aria-live": "polite" });
  const refresh = h("button", { type: "button", class: "quiet small-btn" }, "Refresh");
  const add = h("button", { type: "button", class: "small-btn" }, "+ New event");

  const segs = h("div", { class: "segs", role: "group", "aria-label": "View" });
  const drawSegs = () => segs.replaceChildren(...(["day", "week", "month", "schedule"] as Mode[]).map((m) =>
    h("button", { type: "button", class: "seg" + (mode === m ? " on" : ""), "aria-pressed": mode === m ? "true" : "false", onclick: () => { mode = m; drawSegs(); draw(); } }, m[0]!.toUpperCase() + m.slice(1))));
  drawSegs();
  const step = (dir: number) => {
    if (mode === "month") { const t = new Date(Date.UTC(anchor.year, anchor.month - 1 + dir, 1)); anchor = { year: t.getUTCFullYear(), month: t.getUTCMonth() + 1, day: 1 }; }
    else anchor = addDays(anchor, dir * (mode === "week" ? 7 : mode === "schedule" ? SCHEDULE_DAYS : 1));
    draw();
  };
  into.replaceChildren(
    h("div", { class: "page-head cal-head" }, heading, status,
      h("button", { type: "button", class: "quiet small-btn", "aria-label": "Previous", onclick: () => step(-1) }, "‹"),
      h("button", { type: "button", class: "quiet small-btn", onclick: () => { anchor = today; draw(); } }, "Today"),
      h("button", { type: "button", class: "quiet small-btn", "aria-label": "Next", onclick: () => step(1) }, "›"), segs, refresh, add),
    note, h("div", { class: "reader" }, h("section", { class: "panel calpanel" }, bodyHost), detail));

  let store: CalendarStore;
  if (cache && cache.ctx === ctx) store = cache.store;
  else {
    store = new CalendarStore(ctx, local);
    try { await store.load(); } catch (e) {
      if (mine === run) note.textContent = e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your calendar. Check your connection.";
      return;
    }
    if (mine !== run) return;
    cache = { ctx, store };
  }
  store.onStatus = (text, ok) => { status.textContent = text; status.classList.toggle("bad", !ok); };
  store.onChange = () => { if (mine === run) draw(); };
  refresh.onclick = async () => { refresh.disabled = true; try { await store.load(); status.textContent = "Up to date"; } catch { status.textContent = "Couldn't refresh. Check your connection."; } refresh.disabled = false; draw(); };
  add.onclick = () => openEditor(store, null, newDraft(mode === "schedule" ? today : anchor, today, Date.now(), local));

  const pick = (o: Occurrence) => { picked = { id: o.event.id, start: o.start }; drawDetail(); };
  const chip = (o: Occurrence, cls = "ev") => h("button", { type: "button", class: cls + (picked?.id === o.event.id && picked.start === o.start ? " on" : ""), onclick: (e) => { e.stopPropagation(); pick(o); } }, title(o.event));

  function timedColumn(d: Day, events: CalEvent[]): HTMLElement {
    const col = h("div", { class: "daycol", title: "Click an hour to add an event" });
    // A click on an empty hour starts a new event there, as a tap on the iPhone's timeline does.
    col.addEventListener("click", (e) => {
      if (e.target !== col) return;
      const hour = Math.max(0, Math.min(23, Math.floor((e as MouseEvent).offsetY / HOUR)));
      openEditor(store, null, newDraft(d, today, Date.now(), local, hour));
    });
    const { timed } = on(events, d);
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
      const b = chip(o, "ev block");
      // Set through the style object, not a style attribute, which the page's CSP forbids.
      const n = Math.max(lanes.length, 1);
      Object.assign(b.style, { top: `${(mins / 60) * HOUR}px`, height: `${(Math.min(dur, 1440 - mins) / 60) * HOUR - 2}px`, left: `${(lane / n) * 100}%`, width: `${100 / n}%` });
      col.append(b);
    }
    return col;
  }

  function weekLike(days: Day[], events: CalEvent[]): HTMLElement {
    const head = h("div", { class: "grid-head" }, h("div", {}), ...days.map((d) => h("div", { class: "dayhead" + (sameDay(d, today) ? " today" : "") }, h("span", { class: "sub" }, WEEKDAYS[dow(d)]!), h("b", {}, String(d.day)))));
    const strip = h("div", { class: "grid-head allday" }, h("div", { class: "sub" }, "all day"), ...days.map((d) => h("div", { class: "alldaycell" }, ...on(events, d).allDay.map((o) => chip(o, "ev pill")))));
    const hours = h("div", { class: "hours" }, ...Array.from({ length: 24 }, (_, i) => h("div", { class: "hour sub" }, i === 0 ? "" : new Date(2000, 0, 1, i).toLocaleTimeString(undefined, { hour: "numeric" }))));
    const body = h("div", { class: "grid-body" }, hours, ...days.map((d) => timedColumn(d, events)));
    for (const r of [head, strip, body]) r.style.gridTemplateColumns = `56px repeat(${days.length},minmax(0,1fr))`;
    const scroll = h("div", { class: "grid-scroll" }, body);
    queueMicrotask(() => { scroll.scrollTop = 7 * HOUR; });
    return h("div", { class: "scroll-x" }, h("div", { class: "weekgrid" + (days.length > 1 ? " wide" : "") }, head, strip, scroll));
  }

  function month(events: CalEvent[]): HTMLElement {
    const start = startOfWeek({ year: anchor.year, month: anchor.month, day: 1 });
    const grid = h("div", { class: "monthgrid" }, ...WEEKDAYS.map((w) => h("div", { class: "sub mhead" }, w)));
    for (let i = 0; i < 42; i++) {
      const d = addDays(start, i);
      if (i >= 35 && d.month !== anchor.month) break;
      const { timed, allDay } = on(events, d);
      const all = [...allDay, ...timed];
      grid.append(h("div", { class: "mcell" + (d.month !== anchor.month ? " out" : "") + (sameDay(d, today) ? " today" : "") },
        h("button", { type: "button", class: "mnum", "aria-label": `New event on ${longDay(d)}`, onclick: () => openEditor(store, null, newDraft(d, today, Date.now(), local)) }, String(d.day)),
        ...all.slice(0, 3).map((o) => chip(o, "ev pill")),
        all.length > 3 ? h("button", { type: "button", class: "more", onclick: () => { anchor = d; mode = "day"; drawSegs(); draw(); } }, `+${all.length - 3} more`) : null));
    }
    return grid;
  }

  /** CalendarModel.schedule: from today on, a day at a time, only days that have something. */
  function schedule(events: CalEvent[]): HTMLElement {
    const from = anchor;
    const out = h("div", { class: "schedule" });
    for (let i = 0; i < SCHEDULE_DAYS; i++) {
      const d = addDays(from, i);
      const { timed, allDay } = on(events, d);
      if (!timed.length && !allDay.length) continue;
      out.append(h("div", { class: "panel-title spaced" }, longDay(d)), ...[...allDay, ...timed].map((o) =>
        h("button", { type: "button", class: "item sched-row" + (picked?.id === o.event.id && picked.start === o.start ? " on" : ""), onclick: () => pick(o) },
          h("span", { class: "item-title" }, title(o.event)), h("span", { class: "sub" }, o.event.allDay ? "All day" : `${clock(o.start)} – ${clock(o.end)}${o.event.location ? " · " + o.event.location : ""}`))));
    }
    if (!out.childElementCount) out.append(h("p", { class: "status empty" }, "Nothing in the next 90 days."));
    return out;
  }

  function draw(): void {
    const events = store.all;
    const days = mode === "day" ? [anchor] : Array.from({ length: 7 }, (_, i) => addDays(startOfWeek(anchor), i));
    heading.textContent = mode === "month" ? `${MONTHS[anchor.month - 1]} ${anchor.year}` : mode === "day" ? longDay(anchor) + `, ${anchor.year}` : mode === "schedule" ? "Schedule"
      : `${MONTHS[days[0]!.month - 1]} ${days[0]!.day} – ${days[6]!.month !== days[0]!.month ? MONTHS[days[6]!.month - 1] + " " : ""}${days[6]!.day}, ${days[6]!.year}`;
    bodyHost.replaceChildren(mode === "month" ? month(events) : mode === "schedule" ? schedule(events) : weekLike(days, events));
    note.textContent = store.unreadable ? `${store.unreadable} event${store.unreadable === 1 ? "" : "s"} didn't open with your key and ${store.unreadable === 1 ? "is" : "are"} hidden.` : events.length ? "" : "No events yet. Click an hour, a day, or New event to add one.";
    drawDetail();
  }

  function drawDetail(): void {
    const e = picked ? store.all.find((x) => x.id === picked!.id) : null;
    const raw = e ? store.raw(e.id) : null;
    const o = e && picked ? occurrences(e, picked.start - 1, picked.start + 1).find((x) => x.start === picked!.start) ?? null : null;
    if (!e || !raw || !o) { detail.replaceChildren(h("p", { class: "status" }, picked ? "That event isn't here any more." : "Pick an event to see it here.")); return; }
    const when = e.allDay
      ? (() => { const ds = allDayDays(o); return ds.length > 1 ? `${longDay(ds[0]!)} to ${longDay(ds[ds.length - 1]!)}` : `${longDay(ds[0]!)}, all day`; })()
      : `${longDay(dayOf(o.start, local))}, ${clock(o.start)} to ${clock(o.end)}`;
    const reminder = typeof raw.reminderMinutes === "number" ? raw.reminderMinutes : null;
    const refs = (Array.isArray(raw.attachments) ? raw.attachments : []) as ContentRef[];
    detail.replaceChildren(
      h("h2", { class: "doc-title small" }, title(e)), h("p", { class: "sub" }, when),
      ...(e.location ? [h("p", {}, e.location)] : []),
      ...(e.repeat ? [h("p", { class: "sub" }, freqName(e.repeat.freq) + (e.repeat.until ? `, until ${longDay(e.repeat.until)}` : ""))] : []),
      ...(reminder !== null ? [h("p", { class: "sub" }, `Reminder: ${reminderName(reminder)}`)] : []),
      ...(e.notes ? [h("p", { class: "plain-notes" }, e.notes)] : []),
      ...refs.map((r) => r.module === "reader" ? h("a", { class: "attach-link", href: `#/reader/${String(r.id).toLowerCase()}` }, "📎 " + (r.preview?.title || "Attachment")) : h("p", { class: "sub" }, "📎 " + (r.preview?.title || "Attachment"))),
      h("div", { class: "editor-foot" },
        h("button", { type: "button", class: "small-btn", onclick: () => openEditor(store, o, draftFor(o, raw, local)) }, "Edit"),
        h("button", { type: "button", class: "quiet small-btn danger", onclick: () => askDelete(store, o) }, "Delete"),
        h("span", { class: "sub" }, "Sealed in this browser before it saves.")));
  }

  draw();
}

// ---- the form ----

/** EventEditorView: the same form for new and existing events. Saving a repeating event asks how far it goes. */
function openEditor(store: CalendarStore, occurrence: Occurrence | null, start: Draft): void {
  const d: Draft = structuredClone(start);
  const problem = h("p", { class: "status bad", role: "alert", hidden: true });
  const titleIn = input({ class: "title-field", "aria-label": "Title", placeholder: "Title", value: d.title });
  const where = input({ "aria-label": "Location", placeholder: "Location", value: d.location });
  const allDay = h("input", { type: "checkbox", class: "switch", "aria-label": "All day", ...(d.isAllDay ? { checked: true } : {}) });
  const startIn = input({ "aria-label": "Starts" }), endIn = input({ "aria-label": "Ends" });
  const setTimes = () => {
    startIn.type = endIn.type = d.isAllDay ? "date" : "datetime-local";
    startIn.value = d.isAllDay ? dayInput(d.start) : timeInput(d.start);
    endIn.value = d.isAllDay ? dayInput(d.end) : timeInput(d.end);
  };
  setTimes();
  allDay.addEventListener("change", () => { d.isAllDay = allDay.checked; setTimes(); });
  // Moving the start moves the end with it, as the iPhone's form does.
  startIn.addEventListener("change", () => { const v = fromInput(startIn.value); if (v === null) return; d.end += v - d.start; d.start = v; setTimes(); });
  endIn.addEventListener("change", () => { const v = fromInput(endIn.value); if (v !== null) d.end = v; });

  const freq = select([["", "Never"], ...(["daily", "weekly", "monthly", "yearly"] as Freq[]).map((f): [string, string] => [f, freqName(f)])], d.frequency ?? "", { "aria-label": "Repeat" });
  const ends = h("input", { type: "checkbox", class: "switch", "aria-label": "Repeat ends", ...(d.until ? { checked: true } : {}) });
  const until = input({ type: "date", "aria-label": "Last day", value: d.until ? dayText(d.until) : dayInput(d.start) });
  const endsRow = h("label", { class: "row-field" }, ends, h("span", {}, "Ends"));
  const untilField = field("Last day", until);
  const drawRepeat = () => { endsRow.hidden = !d.frequency; untilField.hidden = !d.frequency || !d.until; };
  freq.addEventListener("change", () => { d.frequency = (freq.value || null) as Freq | null; drawRepeat(); });
  ends.addEventListener("change", () => { d.until = ends.checked ? parseDay(until.value) ?? dayOf(d.start, local) : null; if (ends.checked) until.value = dayText(d.until!); drawRepeat(); });
  until.addEventListener("change", () => { const v = parseDay(until.value); if (v) d.until = v; });
  drawRepeat();

  const reminder = select(REMINDER_CHOICES.map((m): [string, string] => [m === null ? "" : String(m), reminderName(m)]), d.reminderMinutes === null ? "" : String(d.reminderMinutes), { "aria-label": "Reminder" });
  const reminderNote = h("p", { class: "sub" }, "Your iPhone shows the reminder. It shows the event's title and time, including on your lock screen; your device keeps those outside Totality's encryption until the reminder fires.");
  const drawReminder = () => { reminderNote.hidden = d.reminderMinutes === null; };
  reminder.addEventListener("change", () => { d.reminderMinutes = reminder.value === "" ? null : Number(reminder.value); drawReminder(); });
  drawReminder();

  const notes = h("textarea", { class: "notes-field", rows: "4", "aria-label": "Notes", placeholder: "Notes" });
  notes.value = d.notes;
  const attached = h("div", { class: "steps" });
  const drawAttached = () => attached.replaceChildren(...d.attachments.map((r, i) => h("div", { class: "step-edit" },
    h("span", { class: "grow" }, "📎 " + (((r as unknown as ContentRef).preview?.title) || "Attachment")),
    h("button", { type: "button", class: "icon-btn", "aria-label": `Remove ${((r as unknown as ContentRef).preview?.title) || "attachment"}`, onclick: () => { d.attachments.splice(i, 1); drawAttached(); } }, "×"))));
  drawAttached();
  const attach = h("button", { type: "button", class: "quiet small-btn", onclick: () => pickAttachment(store, d, drawAttached) }, "📎 Attach from Reader");

  const save = async (): Promise<boolean> => {
    d.title = titleIn.value; d.location = where.value; d.notes = notes.value;
    problem.hidden = true;
    const go = async (scope: Scope) => {
      try { return occurrence ? await store.change(occurrence, d, scope) : await store.add(d); }
      catch (e) { if (e instanceof DraftProblem) { problem.textContent = e.message; problem.hidden = false; return false; } throw e; }
    };
    if (occurrence?.event.repeat) {
      // Change which events?
      return new Promise((done) => {
        sheet("Change which events?", [h("p", { class: "sub" }, "This event repeats.")], [
          { label: "This event only", run: async () => { const ok = await go("this"); done(ok); return true; } },
          { label: "All of them", primary: true, run: async () => { const ok = await go("all"); done(ok); return true; } },
        ]).addEventListener("close", () => done(false));
      });
    }
    return go("all");
  };

  sheet(occurrence ? "Edit event" : "New event", [
    problem, titleIn, where,
    h("label", { class: "row-field" }, allDay, h("span", {}, "All day")),
    h("div", { class: "grid2" }, field("Starts", startIn), field("Ends", endIn)),
    field("Repeat", freq), endsRow, untilField,
    field("Reminder", reminder), reminderNote,
    field("Notes", notes), attached, attach,
    h("p", { class: "sub" }, "Kept in Totality, encrypted with your key."),
  ], [{ label: "Save", primary: true, run: save }]);
  if (!occurrence) titleIn.focus();
}

async function pickAttachment(store: CalendarStore, d: Draft, after: () => void): Promise<void> {
  const list = h("div", { class: "steps" }, h("p", { class: "status" }, "Opening your Reader…"));
  const dialog = sheet("Attach from Reader", [list]);
  const refs = await attachable("calendar", store.ctx);
  const options = refs.filter((r) => !d.attachments.some((a) => String(a.id).toLowerCase() === r.id.toLowerCase()));
  list.replaceChildren(...(options.length ? options.map((r) => h("button", { type: "button", class: "item", onclick: () => { d.attachments.push(r as unknown as Raw); after(); dialog.close(); } },
    h("span", { class: "item-title" }, r.preview.title), h("span", { class: "sub" }, r.kind === "note" ? "Doc" : "File"))) : [h("p", { class: "status" }, "Nothing else in your Reader to attach.")]));
}

/** "Delete this event?" — and for a repeat, this one only or all of them. */
function askDelete(store: CalendarStore, o: Occurrence): void {
  const name = o.event.title.trim() || "Untitled event";
  const after = (ok: boolean) => ok;
  sheet("Delete this event?", [h("p", { class: "sub" }, `“${name}” is deleted on every device.`)], o.event.repeat
    ? [{ label: "This event only", run: async () => after(await store.delete(o, "this")) }, { label: "All of them", primary: true, run: async () => after(await store.delete(o, "all")) }]
    : [{ label: "Delete", primary: true, run: async () => after(await store.delete(o, "all")) }]);
}
