// Weather on the website: the places saved on the iPhone, opened in this browser, each with Open-Meteo's
// forecast fetched straight from here. Read-only: places are added on the iPhone. The browser's location is
// never asked for.
import { h } from "../dom";
import * as net from "../net";
import { openMeta } from "../sealedjson";
import type { Ctx } from "../reader/view";
import { conditionName, forecastUrl, parseForecast, parsePlaces, speed, temp, usesFahrenheit, type Forecast, type Place } from "./model";

let run = 0;
export const stopWeather = (): void => { run++; };

const dayName = (ms: number, zone: string, first: boolean): string =>
  first ? "Today" : new Date(ms).toLocaleDateString("en-US", { weekday: "short", timeZone: zone });

export async function showWeather(into: HTMLElement, ctx: Ctx): Promise<void> {
  const mine = ++run;
  const note = h("p", { class: "status", role: "status" }, "Opening your places…");
  const list = h("div", { class: "weather-places" });
  const f = usesFahrenheit(navigator.language);
  into.replaceChildren(
    h("div", { class: "page-head" }, h("h1", {}, "Weather")),
    h("p", { class: "sub" }, "Your saved places. Add and order them on your iPhone."),
    note, list,
    h("p", { class: "sub small" }, "Your places are end-to-end encrypted and opened in this browser. To get a forecast, a rough location is sent to Open-Meteo. Weather data by ",
      h("a", { href: "https://open-meteo.com/", rel: "noopener noreferrer", target: "_blank" }, "Open-Meteo"), " (CC BY 4.0)."));

  let places: Place[] = [];
  let unreadable = 0;
  try {
    const rows = await net.listSealed(await ctx.token(), ["weather_places"]);
    const records: unknown[] = [];
    for (const row of rows) {
      try {
        if (!row.meta) throw new Error("meta");
        records.push(JSON.parse(await openMeta("weather-places", row.meta, row.id)));
      } catch { unreadable++; }
    }
    places = parsePlaces(...records);
  } catch (e) {
    if (mine === run) note.textContent = e instanceof Error && e.message === "locked" ? "Locked." : "Couldn't load your places. Check your connection.";
    return;
  }
  if (mine !== run) return;
  if (!places.length) {
    note.textContent = unreadable ? "Your places didn't open with your key." : "No places yet. Add a city in Weather on your iPhone and it shows here.";
    return;
  }
  note.textContent = "";
  const cards = places.map((p) => {
    const card = h("section", { class: "panel weather-card", "aria-label": p.name },
      h("div", { class: "panel-title" }, p.region ? `${p.name} · ${p.region}` : p.name), h("p", { class: "status" }, "Getting the forecast…"));
    return { p, card };
  });
  list.replaceChildren(...cards.map((c) => c.card));
  // All places together, so the source can't tell which one is looked at.
  await Promise.all(cards.map(async ({ p, card }) => {
    const answer = await net.getForecast(forecastUrl(p));
    const forecast: Forecast | null = answer ? parseForecast(answer) : null;
    if (mine !== run) return;
    if (!forecast) {
      card.replaceChildren(h("div", { class: "panel-title" }, p.name), h("p", { class: "status" }, "Open-Meteo didn't answer. Try again in a minute."));
      return;
    }
    const today = forecast.days[0];
    card.replaceChildren(
      h("div", { class: "panel-title" }, p.region ? `${p.name} · ${p.region}` : p.name),
      h("div", { class: "weather-now" },
        h("span", { class: "weather-temp" }, temp(forecast.temperature, f)),
        h("span", {}, h("strong", {}, conditionName(forecast.code)), h("br", {}),
          h("span", { class: "sub" }, `${today ? `H ${temp(today.high, f)}  L ${temp(today.low, f)} · ` : ""}Feels like ${temp(forecast.feelsLike, f)} · Wind ${speed(forecast.wind, f)} · Humidity ${Math.round(forecast.humidity)}%`))),
      h("ul", { class: "weather-days" }, ...forecast.days.map((d, i) =>
        h("li", {}, h("span", { class: "weather-day" }, dayName(d.date, forecast.timezone, i === 0)), h("span", { class: "sub" }, conditionName(d.code)),
          h("span", { class: "weather-chance" }, d.chance >= 10 ? `${Math.round(d.chance)}%` : ""), h("span", { class: "weather-range" }, `${temp(d.high, f)} / ${temp(d.low, f)}`)))));
  }));
}
