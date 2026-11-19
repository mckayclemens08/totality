import { test } from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";

await build({ entryPoints: ["src/idle.ts"], bundle: true, format: "esm", outfile: "dist-test/idle.mjs", platform: "node", logLevel: "silent" });
const { IdleLock, IDLE_LOCK_MS } = await import("../dist-test/idle.mjs");

function fakeClock() {
  let now = 0, next = 1; const jobs = new Map();
  return {
    timers: { set: (fn, ms) => { jobs.set(next, { fn, at: now + ms }); return next++; }, clear: (id) => jobs.delete(id) },
    advance(ms) { now += ms; for (const [id, j] of [...jobs]) if (j.at <= now) { jobs.delete(id); j.fn(); } },
  };
}

test("locks after exactly 30 idle minutes", () => {
  assert.equal(IDLE_LOCK_MS, 30 * 60 * 1000);
  const c = fakeClock(); let locked = 0;
  const lock = new IdleLock(() => locked++, IDLE_LOCK_MS, c.timers);
  lock.start();
  c.advance(IDLE_LOCK_MS - 1); assert.equal(locked, 0);
  c.advance(1); assert.equal(locked, 1);
});

test("activity pushes the lock back, and stop() cancels it", () => {
  const c = fakeClock(); let locked = 0;
  const lock = new IdleLock(() => locked++, 1000, c.timers);
  lock.start(); c.advance(900); lock.touch(); c.advance(900); assert.equal(locked, 0);
  c.advance(100); assert.equal(locked, 1);
  lock.touch(); lock.stop(); c.advance(5000); assert.equal(locked, 1);
});
