import { test } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";

await build({ entryPoints: ["src/clock/model.ts"], bundle: true, format: "esm", outfile: "dist-test/clock.mjs", platform: "node", logLevel: "silent" });
const C = await import("../dist-test/clock.mjs");

// ClockItems as Swift's JSONEncoder writes it: dates in seconds since 2001, `removed` as [id, date, …].
const swift = {
  cities: [
    { id: "6F1C5A52-1D8C-4C5E-9D59-2D3F3E1B0001", name: "Tokyo", timeZoneID: "Asia/Tokyo", order: 2, updatedAt: 785_000_000 },
    { id: "6F1C5A52-1D8C-4C5E-9D59-2D3F3E1B0002", name: "London", timeZoneID: "Europe/London", order: 1, updatedAt: 785_000_000 },
    { id: "6F1C5A52-1D8C-4C5E-9D59-2D3F3E1B0003", name: "Lagos", timeZoneID: "Africa/Lagos", order: 3, updatedAt: 785_000_000 },
  ],
  presets: [{ id: "6F1C5A52-1D8C-4C5E-9D59-2D3F3E1B0010", name: "Tea", seconds: 180, order: 1, updatedAt: 785_000_000 }],
  stopwatch: { banked: 12.5, laps: [10, 2.5], updatedAt: 785_000_000 },
  removed: ["6F1C5A52-1D8C-4C5E-9D59-2D3F3E1B0003", 785_000_100],
};

test("the browser reads the iPhone's clock record, removals and order included", () => {
  const items = C.parseItems(swift);
  assert.deepEqual(C.shownCities(items).map((c) => c.name), ["London", "Tokyo"]);
  assert.deepEqual(C.shownPresets(items).map((p) => [p.name, C.lengthText(p.seconds)]), [["Tea", "3 min"]]);
  assert.equal(items.stopwatch.startedAt, null);
  assert.equal(C.stopwatchText(C.elapsed(items.stopwatch, Date.now())), "00:12.50");
  assert.equal(C.appleDate(0), Date.UTC(2001, 0, 1));
});

test("two copies merge to the later of each, as on the iPhone", () => {
  const a = C.parseItems(swift);
  const b = C.parseItems({ ...swift, cities: [{ ...swift.cities[0], name: "Tōkyō", updatedAt: 785_000_500 }], removed: [] });
  assert.deepEqual(C.shownCities(C.merge(a, b)).map((c) => c.name).sort(), ["London", "Tōkyō"]);
});

test("offsets follow each zone's own daylight saving", () => {
  const november = Date.UTC(2026, 10, 20, 21, 35);
  assert.equal(C.offsetText("America/New_York", "America/Denver", november), "2 h ahead");
  assert.equal(C.offsetText("Asia/Kolkata", "America/Denver", november), "12 h 30 min ahead");
  assert.equal(C.offsetText("America/Phoenix", "America/Denver", november), "Same time");
  assert.equal(C.offsetText("America/Phoenix", "America/Denver", Date.UTC(2026, 6, 1, 18)), "1 h behind");
});
