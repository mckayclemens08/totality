/** Locks a shared computer after this long with no activity (owner, 2026-11-18). */
export const IDLE_LOCK_MS = 30 * 60 * 1000;

/** Calls `onLock` once after `ms` with no `touch()`. The clock is passed in so tests don't wait. */
export class IdleLock {
  private timer: ReturnType<typeof setTimeout> | undefined;
  constructor(
    private readonly onLock: () => void,
    private readonly ms = IDLE_LOCK_MS,
    private readonly timers = { set: setTimeout, clear: clearTimeout },
  ) {}
  start(): void { this.touch(); }
  touch(): void {
    this.stop();
    this.timer = this.timers.set(() => { this.timer = undefined; this.onLock(); }, this.ms);
  }
  stop(): void {
    if (this.timer !== undefined) this.timers.clear(this.timer);
    this.timer = undefined;
  }
}
