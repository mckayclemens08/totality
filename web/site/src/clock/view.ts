// The Clock on the website (issue 204): your world cities with their times, your timer presets, and the
// stopwatch as your iPhone last left it. It's opened in this browser from the sealed clock_items record.
// Alarms and timers ring on the iPhone that set them, so they aren't here. Changes are made on the iPhone.
import "./clock.css";
import { h } from "../dom";
import type { Ctx } from "../reader/view";
import * as net from "../net";
import { objectKeyBytes } from "../keystore";
import { fromByteaLiteral, openBlob } from "../sealed";
import { uuidBytes } from "../pairing/protocol";
import { elapsed, lengthText, merge, offsetText, parseItems, shownCities, shownPresets, stopwatchText, type ClockItems } from "./model";

let run = 0;
let timer: ReturnType<typeof setInterval> | null = null;
export const stopClock = (): void => {
  run++;
  if (timer) clearInterval(timer);
  timer = null;
};

async function load(ctx: Ctx): Promise<ClockItems | null> {
  const rows = await net.listSealed(await ctx.token(), ["clock_items"]);
  let items: ClockItems | null = null;
  for (const row of rows) {
    if (row.kind !== "clock_items" || !row.meta) continue;
    const key = await objectKeyBytes("clock-items", uuidBytes(row.id));
    try {
      const one = parseItems(JSON.parse(new TextDecoder().decode(openBlob(fromByteaLiteral(row.meta), key, row.id))));
      items = items ? merge(items, one) : one;
    } catch { /* a copy this key can't open belongs to no one here */ } finally { key.fill(0); }
  }
  return items;
}

export async function showClock(into: HTMLElement, ctx: Ctx): Promise<void> {
  stopClock();
  const mine = run;
  const body = h("div", { class: "clock" }, h("p", { class: "status" }, "Opening your clock…"));
  into.replaceChildren(h("div", { class: "page-head" }, h("h1", {}, "Clock")), body);
  let items: ClockItems | null;
  try { items = await load(ctx); } catch (e) {
    if (mine === run) body.replaceChildren(h("p", { class: "status" }, e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your clock. Check your connection and try again."));
    return;
  }
  if (mine !== run) return;
  const local = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const cities = items ? shownCities(items) : [];
  const presets = items ? shownPresets(items) : [];
  const watch = items?.stopwatch ?? null;

  const cityTimes = cities.map((c) => ({ c, time: h("span", { class: "clock-time" }), sub: h("span", { class: "sub" }) }));
  const watchTime = h("span", { class: "clock-watch" });
  const tick = () => {
    const now = Date.now();
    for (const { c, time, sub } of cityTimes) {
      try {
        time.textContent = new Intl.DateTimeFormat(undefined, { timeZone: c.timeZoneID, hour: "numeric", minute: "2-digit" }).format(now);
        const day = new Intl.DateTimeFormat("en-CA", { timeZone: c.timeZoneID, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
        const today = new Intl.DateTimeFormat("en-CA", { timeZone: local, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
        sub.textContent = `${day === today ? "Today" : day > today ? "Tomorrow" : "Yesterday"} · ${offsetText(c.timeZoneID, local, now)}`;
      } catch { time.textContent = "—"; }
    }
    if (watch) watchTime.textContent = stopwatchText(elapsed(watch, now));
  };

  body.replaceChildren(
    h("section", { class: "panel" }, h("div", { class: "panel-title" }, "World clock"),
      cities.length ? h("ul", { class: "clock-list" }, ...cityTimes.map(({ c, time, sub }) => h("li", {}, h("span", { class: "clock-city" }, h("span", { class: "clock-name" }, c.name), sub), time)))
        : h("p", { class: "status" }, "Add a city on your iPhone to see its time here.")),
    h("section", { class: "panel" }, h("div", { class: "panel-title" }, "Stopwatch"),
      watch ? watchTime : h("span", { class: "clock-watch" }, "00:00.00"),
      watch && watch.laps.length ? h("ol", { class: "clock-laps" }, ...watch.laps.map((l, i) => h("li", {}, h("span", {}, `Lap ${i + 1}`), h("span", { class: "clock-num" }, stopwatchText(l))))) : null,
      h("p", { class: "status" }, watch?.startedAt ? "Running on your iPhone." : "As your iPhone last left it.")),
    h("section", { class: "panel" }, h("div", { class: "panel-title" }, "Timer presets"),
      presets.length ? h("ul", { class: "clock-list" }, ...presets.map((p) => h("li", {}, h("span", { class: "clock-name" }, p.name), h("span", { class: "clock-num" }, lengthText(p.seconds)))))
        : h("p", { class: "status" }, "No presets yet.")),
    h("p", { class: "status" }, "Alarms and timers ring on the iPhone that set them, so they stay there. Change your cities and presets on your iPhone."),
  );
  tick();
  timer = setInterval(() => { if (mine === run) tick(); }, watch?.startedAt ? 50 : 1000);
}
