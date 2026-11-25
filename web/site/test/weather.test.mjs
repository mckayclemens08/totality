import { test } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";

await build({ entryPoints: ["src/weather/model.ts"], bundle: true, format: "esm", outfile: "dist-test/weather.mjs", platform: "node", logLevel: "silent" });
const W = await import("../dist-test/weather.mjs");

// Shaped exactly as WeatherPlaces.swift encodes it: entries keyed by place ID, dates as seconds since 2001.
const provo = "6b3f8a1e-2c4d-4e5f-8a9b-0c1d2e3f4a5b", lisbon = "1a2b3c4d-5e6f-4a1b-9c2d-3e4f5a6b7c8d";
const record = {
  entries: {
    [provo.toUpperCase()]: { place: { id: provo.toUpperCase(), name: "Provo", region: "Utah, United States", coordinate: { latitude: 40.2338, longitude: -111.6585 }, timeZone: "America/Denver" }, order: 2, changedAt: 815_000_000 },
    [lisbon.toUpperCase()]: { place: { id: lisbon.toUpperCase(), name: "Lisbon", region: "Portugal", coordinate: { latitude: 38.72, longitude: -9.13 } }, order: 1, changedAt: 815_000_000 },
    "00000000-0000-4000-8000-000000000000": { order: 3, changedAt: 815_000_001 },
  },
};

test("saved places open in the person's order, removed ones left out", () => {
  assert.deepEqual(W.parsePlaces(record).map((p) => p.name), ["Lisbon", "Provo"]);
});

test("a place filed under another place's ID is never shown", () => {
  const forged = { entries: { [lisbon]: { place: { id: provo, name: "Elsewhere", coordinate: { latitude: 1, longitude: 1 } }, order: 1, changedAt: 1 } } };
  assert.deepEqual(W.parsePlaces(forged), []);
});

test("two copies come together by the later change", () => {
  const removed = { entries: { [provo.toUpperCase()]: { order: 2, changedAt: 815_000_100 } } };
  assert.deepEqual(W.parsePlaces(record, removed).map((p) => p.name), ["Lisbon"]);
  assert.deepEqual(W.parsePlaces(removed, record).map((p) => p.name), ["Lisbon"]);
});

test("only the rough location is sent", () => {
  const url = new URL(W.forecastUrl({ latitude: 40.23384, longitude: -111.65853 }));
  assert.equal(url.origin, "https://api.open-meteo.com");
  assert.equal(url.searchParams.get("latitude"), "40.23");
  assert.equal(url.searchParams.get("longitude"), "-111.66");
});

test("Open-Meteo's answer is read, and a broken one refused", () => {
  const f = W.parseForecast({ timezone: "America/Denver", current: { temperature_2m: 5, apparent_temperature: 2, relative_humidity_2m: 52, weather_code: 2, wind_speed_10m: 13, is_day: 1 },
    daily: { time: [1795849200], weather_code: [73], temperature_2m_max: [8.3], temperature_2m_min: [-2.2], precipitation_probability_max: [60] } });
  assert.equal(W.conditionName(f.code), "Partly cloudy");
  assert.equal(W.temp(f.temperature, true), "41°");
  assert.equal(W.speed(f.wind, true), "8 mph");
  assert.equal(f.days[0].chance, 60);
  assert.equal(W.parseForecast({}), null);
  assert.equal(W.temp(-0.3, false), "0°");
  assert.ok(W.usesFahrenheit("en-US") && !W.usesFahrenheit("en-GB"));
});
