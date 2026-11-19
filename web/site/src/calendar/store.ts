// Events as this browser holds them, and every change to them: what CalendarModel.swift does, with the server
// in place of the phone's vault. Every write names the version it was made from. If another device changed it
// first, CalendarVault's rule settles it: the newer stays and the older is kept as "(conflict copy)". An edit
// to an event deleted elsewhere brings it back, as SyncEngine has it; a delete never removes a newer edit.
import * as net from "../net";
import { fetchHeld, loadSealed, sealJson, writeSealed, type Held } from "../sealedjson";
import { parseEvent, type CalEvent, type Occurrence } from "./model";
import { create, remove, resolve, update, type Draft, type Raw, type Scope } from "./edit";

export interface Ctx { token: () => Promise<string>; userId: string }
const KIND = "event", PURPOSE = "event" as const;

export class CalendarStore {
  events = new Map<string, Held>();
  unreadable = 0;
  onStatus: (text: string, ok: boolean) => void = () => {};
  onChange: () => void = () => {};
  private busy = 0;

  constructor(readonly ctx: Ctx, readonly display: string) {}

  async load(): Promise<void> {
    const { items, unreadable } = await loadSealed(await this.ctx.token(), KIND, PURPOSE);
    this.events = new Map(items.map((h) => [h.id, h]));
    this.unreadable = unreadable;
  }

  get all(): CalEvent[] { return [...this.events.values()].flatMap((h) => parseEvent(h.id, h.json) ?? []); }
  raw(id: string): Raw | null { return this.events.get(id)?.json ?? null; }

  private async run(work: () => Promise<string | void>): Promise<boolean> {
    this.busy++;
    this.onStatus("Saving…", true);
    try {
      const said = await work();
      if (--this.busy === 0) this.onStatus(said || "Saved", true);
      return true;
    } catch (e) {
      this.busy--;
      this.onStatus(e instanceof net.NetError && e.kind === "offline" ? "Couldn't save: you're offline. Try again." : "That event wasn't saved. Try again.", false);
      return false;
    } finally { this.onChange(); }
  }

  /** Writes one event, settling with the server's copy if another device got there first. Returns a note for the status line. */
  private async put(next: Raw, expected: string | null | "deleted"): Promise<string | void> {
    const token = await this.ctx.token();
    const id = String(next.id).toLowerCase();
    let note: string | void = undefined;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        this.events.set(id, await writeSealed(token, this.ctx.userId, KIND, PURPOSE, next, expected));
        return note;
      } catch (e) {
        if (!(e instanceof net.ChangedOnServer)) throw e;
        const now = await fetchHeld(token, id, KIND, PURPOSE);
        if (now === "deleted") { expected = "deleted"; continue; } // an edit beats a delete
        if (now === null) { expected = null; continue; }
        // A new event whose ID is already there is this browser's own earlier try.
        if (expected === null) { this.events.set(id, now); return note; }
        const r = resolve(next, now.json, (await sealJson(PURPOSE, id, next)).hash, now.hash, Date.now());
        if (r.copy) await this.putCopy(r.copy);
        if (r.keep === "theirs") {
          this.events.set(id, now);
          return r.copy ? "This event changed on another device. That version is shown, and yours is kept as a conflict copy." : note;
        }
        if (r.copy) note = "This event changed on another device too. Yours is saved, and the other version is kept as a conflict copy.";
        expected = now.hash;
      }
    }
    throw new Error("busy");
  }

  /** A copy is named for the version it keeps, so writing it twice is the same copy. */
  private async putCopy(copy: Raw): Promise<void> {
    const token = await this.ctx.token();
    const id = String(copy.id).toLowerCase();
    try { this.events.set(id, await writeSealed(token, this.ctx.userId, KIND, PURPOSE, copy, null)); }
    catch (e) { if (!(e instanceof net.ChangedOnServer)) throw e; }
  }

  /** CalendarModel.create. Throws DraftProblem for what the form must say. */
  add(d: Draft): Promise<boolean> {
    const json = create(d, Date.now(), this.display);
    return this.run(() => this.put(json, null));
  }

  /** CalendarModel.update: the split-off occurrence first, then the series. */
  change(o: Occurrence, d: Draft, scope: Scope): Promise<boolean> {
    const held = this.events.get(o.event.id);
    if (!held) return Promise.resolve(false);
    const out = update(held.json, o.start, d, scope, Date.now(), this.display);
    return this.run(async () => {
      let note: string | void = undefined;
      for (const json of out) {
        const id = String(json.id).toLowerCase();
        note = (await this.put(json, id === held.id ? held.hash : null)) || note;
      }
      return note;
    });
  }

  /** CalendarModel.delete. A delete never removes what another device changed since: that stays, and the status says so. */
  delete(o: Occurrence, scope: Scope): Promise<boolean> {
    const held = this.events.get(o.event.id);
    if (!held) return Promise.resolve(false);
    const r = remove(held.json, o.start, scope, Date.now());
    if ("save" in r) return this.run(() => this.put(r.save, held.hash));
    return this.run(async () => {
      const token = await this.ctx.token();
      try {
        await net.tombstoneSealed(token, held.id, held.hash);
        this.events.delete(held.id);
      } catch (e) {
        if (!(e instanceof net.ChangedOnServer)) throw e;
        const now = await fetchHeld(token, held.id, KIND, PURPOSE);
        if (now === "deleted" || now === null) { this.events.delete(held.id); return; }
        this.events.set(held.id, now);
        return "This event changed on another device, so it wasn't deleted. The latest is shown.";
      }
    });
  }
}
