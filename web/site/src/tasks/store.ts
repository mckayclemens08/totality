// Tasks as this browser holds them, and every change to them: what TasksModel.swift does, with the server
// in place of the phone's vault. Every write names the version it was made from. If another device got
// there first, the change is put onto the server's newer copy part by part (TaskItem.applying), so nothing
// it changed is undone; a task deleted elsewhere comes back with the edit, as SyncEngine has it.
import * as net from "../net";
import { fetchHeld, loadSealed, writeSealed, type Held } from "../sealedjson";
import { parseList, parseTask, type Task, type TaskList } from "./model";
import { appleNow, applying, canon, change, following, isDone, isFollowingOf, newID, newTask, skippingNext, tidy, type Raw } from "./edit";
import { parseLines, taskFields, monthFirst, type Ctx as QuickCtx } from "./quickadd";
import { addDays, type Cal, type Day } from "./repeat";

export interface Ctx { token: () => Promise<string>; userId: string }
export type Bucket = "inbox" | "today" | "upcoming" | "anytime" | "someday" | "logbook";
export type Destination = { bucket: Bucket } | { list: string; heading: string | null };
export type ScheduleChoice = { day: Day; evening: boolean } | "anytime" | "someday";
export interface PendingDelete { tasks: Held[]; lists: Held[]; title: string; timer: ReturnType<typeof setTimeout> }

const TASK = { kind: "task", purpose: "task" } as const;
const LIST = { kind: "task_list", purpose: "task-list" } as const;
export const UNDO_MS = 5000;
export const LINGER_MS = 700;

export function weekStartDay(): number {
  try {
    const info = (new Intl.Locale(navigator.language) as unknown as { weekInfo?: { firstDay: number }; getWeekInfo?: () => { firstDay: number } });
    const first = info.getWeekInfo?.().firstDay ?? info.weekInfo?.firstDay;
    return first ? (first % 7) + 1 : 1; // ISO 1 = Monday … 7 = Sunday → Calendar's 1 = Sunday
  } catch { return 1; }
}
export const localToday = (): Day => { const d = new Date(); return { year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate() }; };

export class TasksStore {
  tasks = new Map<string, Held>();
  lists = new Map<string, Held>();
  unreadable = 0;
  pending: PendingDelete | null = null;
  /** "Saving…", "Saved", or what went wrong, for the status line. */
  onStatus: (text: string, ok: boolean) => void = () => {};
  onChange: () => void = () => {};
  readonly cal: Cal = { firstWeekday: weekStartDay() };
  private busy = 0;

  constructor(private ctx: Ctx) {}

  async load(): Promise<void> {
    const token = await this.ctx.token();
    const [t, l] = [await loadSealed(token, TASK.kind, TASK.purpose), await loadSealed(token, LIST.kind, LIST.purpose)];
    this.tasks = new Map(t.items.map((h) => [h.id, h]));
    this.lists = new Map(l.items.map((h) => [h.id, h]));
    this.unreadable = t.unreadable + l.unreadable;
  }

  get allTasks(): Task[] { return [...this.tasks.values()].flatMap((h) => parseTask(h.id, h.json) ?? []); }
  get allLists(): TaskList[] { return [...this.lists.values()].flatMap((h) => parseList(h.id, h.json) ?? []); }
  raw(id: string): Raw | null { return this.tasks.get(id)?.json ?? null; }
  rawList(id: string): Raw | null { return this.lists.get(id)?.json ?? null; }
  quickCtx(): QuickCtx { return { today: localToday(), firstWeekday: this.cal.firstWeekday, monthFirst: monthFirst() }; }

  private async run<T>(work: () => Promise<T>): Promise<T | null> {
    this.busy++;
    this.onStatus("Saving…", true);
    try {
      const out = await work();
      if (--this.busy === 0) this.onStatus("Saved", true);
      return out;
    } catch (e) {
      this.busy--;
      this.onStatus(e instanceof net.NetError && e.kind === "offline" ? "Couldn't save: you're offline. Your change is still here; try again." : "Couldn't save. Your change is still here; try again.", false);
      return null;
    } finally { this.onChange(); }
  }

  /** Writes a task, settling with whatever the server has if another device changed it first. */
  private async putTask(next: Raw, base: Raw | null, baseHash: string | null): Promise<Held> {
    const token = await this.ctx.token();
    const id = String(next.id).toLowerCase();
    let expected: string | null | "deleted" = baseHash;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const held = await writeSealed(token, this.ctx.userId, TASK.kind, TASK.purpose, tidy(next), expected);
        this.tasks.set(id, held);
        return held;
      } catch (e) {
        if (!(e instanceof net.ChangedOnServer)) throw e;
        const server = await fetchHeld(token, id, TASK.kind, TASK.purpose);
        if (server === "deleted") { expected = "deleted"; continue; } // an edit beats a delete
        if (server === null) { expected = null; continue; }
        if (!base) { this.tasks.set(id, server); return server; } // the same new copy, made by another device
        next = applying(server.json, next, base, appleNow());
        base = server.json; expected = server.hash;
      }
    }
    throw new net.NetError("failed");
  }

  /** Lists keep the newer whole (TaskVault.resolveConflict); this edit is the newer, made onto the server's copy. */
  private async putList(next: Raw, base: Raw | null, baseHash: string | null): Promise<Held> {
    const token = await this.ctx.token();
    const id = String(next.id).toLowerCase();
    let expected: string | null | "deleted" = baseHash;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const held = await writeSealed(token, this.ctx.userId, LIST.kind, LIST.purpose, next, expected);
        this.lists.set(id, held);
        return held;
      } catch (e) {
        if (!(e instanceof net.ChangedOnServer)) throw e;
        const server = await fetchHeld(token, id, LIST.kind, LIST.purpose);
        if (server === "deleted") { expected = "deleted"; continue; }
        if (server === null) { expected = null; continue; }
        if (!base) { this.lists.set(id, server); return server; }
        const merged: Raw = structuredClone(server.json);
        for (const k of new Set([...Object.keys(next), ...Object.keys(base)])) {
          if (JSON.stringify(next[k]) !== JSON.stringify(base[k])) { if (next[k] === undefined) delete merged[k]; else merged[k] = next[k]; }
        }
        merged.updatedAt = Math.max(appleNow(), Number(server.json.updatedAt ?? 0));
        next = merged; base = server.json; expected = server.hash;
      }
    }
    throw new net.NetError("failed");
  }

  // ---- tasks ----

  /** TasksModel.change: one edit to one task, stamped and saved. */
  async changeTask(id: string, edit: (t: Raw) => void): Promise<boolean> {
    const held = this.tasks.get(id);
    if (!held) return false;
    const next = change(held.json, appleNow(), edit);
    if (canon(next) === canon(tidy(held.json))) return true;
    this.tasks.set(id, { ...held, json: next }); // shown at once; the server's answer replaces it
    this.onChange();
    const ok = await this.run(() => this.putTask(next, held.json, held.hash));
    if (!ok) this.tasks.set(id, held);
    return !!ok;
  }

  /** TasksModel.add: one task per line typed, each read for dates, tags and priority. */
  async add(text: string, bucket: Bucket | null, list: string | null = null, heading: string | null = null): Promise<string[]> {
    const parsed = parseLines(text, this.quickCtx());
    let order = Math.max(0, ...this.allTasks.map((t) => t.order)) + 1;
    const placeFor = (b: Bucket | null): "inbox" | "anytime" | "someday" => (b === "anytime" || b === "today" || b === "upcoming" ? "anytime" : b === "someday" ? "someday" : "inbox");
    const added: string[] = [];
    for (const p of parsed) {
      const fields = taskFields(p, list ? "anytime" : placeFor(bucket), bucket === "today" ? localToday() : null);
      const t = newTask({ ...fields, order: order++, ...(list ? { listID: list.toUpperCase(), ...(heading ? { headingID: heading.toUpperCase() } : {}) } : {}) }, appleNow());
      const ok = await this.run(() => this.putTask(t, null, null));
      if (!ok) break;
      added.push(String(t.id).toLowerCase());
    }
    return added;
  }

  /** TasksModel.finish: ticks a task off; a repeating one leaves its next copy behind. */
  async finish(id: string, atMs = Date.now()): Promise<boolean> {
    const t = this.raw(id);
    if (!t || isDone(t)) return false;
    const next = following(t, atMs, this.cal);
    const at = appleNow(atMs);
    const done = await this.changeTask(id, (x) => { x.completedAt = at; delete x.snoozedUntil; if (next) delete x.repeatRule; });
    if (done && next && !this.tasks.has(String(next.id).toLowerCase())) await this.run(() => this.putTask(next, null, null));
    return done;
  }

  /** TasksModel.unfinish: brings it back, and takes back the copy it left if that's still waiting. */
  async unfinish(id: string): Promise<void> {
    if (!this.tasks.has(id)) return;
    const copy = [...this.tasks.values()].find((h) => isFollowingOf(h.json, id));
    await this.changeTask(id, (x) => {
      delete x.completedAt;
      if (copy?.json.repeatRule) { const rule = structuredClone(copy.json.repeatRule) as Raw; rule.done = Math.max(0, Number(rule.done ?? 0) - 1); x.repeatRule = rule; }
    });
    if (copy) await this.run(async () => { await net.tombstoneSealed(await this.ctx.token(), copy.id, copy.hash).catch(() => {}); this.tasks.delete(copy.id); });
  }

  async schedule(id: string, choice: ScheduleChoice): Promise<void> {
    await this.changeTask(id, (t) => {
      if (choice === "anytime" || choice === "someday") { delete t.when; t.isEvening = false; delete t.time; t.place = choice; return; }
      t.when = choice.day; t.isEvening = choice.evening;
      if (t.place === "someday" || t.place === "inbox") t.place = "anytime";
    });
  }

  /** TasksModel.move. Today plans them for today; Inbox takes them out of any project. */
  async move(ids: string[], to: Destination): Promise<void> {
    const today = localToday();
    for (const id of ids) {
      await this.changeTask(id, (t) => {
        if ("list" in to) { t.listID = to.list.toUpperCase(); if (to.heading) t.headingID = to.heading.toUpperCase(); else delete t.headingID; if (t.place === "inbox") t.place = "anytime"; return; }
        switch (to.bucket) {
          case "inbox": t.place = "inbox"; delete t.listID; delete t.headingID; delete t.when; t.isEvening = false; break;
          case "today": t.when = today; if (t.place !== "anytime") t.place = "anytime"; break;
          case "someday": t.place = "someday"; delete t.when; t.isEvening = false; delete t.time; break;
          case "anytime": t.place = "anytime"; delete t.when; t.isEvening = false; delete t.time; break;
          default: break;
        }
      });
    }
  }

  /** TasksModel.place: a dragged task goes just above another, taking its heading when they share a project. */
  async placeBefore(id: string, target: string, shown: Task[]): Promise<void> {
    const index = shown.findIndex((t) => t.id === target);
    if (id === target || index < 0) return;
    const above = shown.slice(0, index).filter((t) => t.id !== id).pop();
    const order = above ? (above.order + shown[index]!.order) / 2 : shown[index]!.order - 1;
    const tt = shown[index]!;
    await this.changeTask(id, (t) => {
      t.order = order;
      const same = typeof t.listID === "string" && tt.listID !== null && t.listID.toLowerCase() === tt.listID;
      if (same) { if (tt.headingID) t.headingID = tt.headingID.toUpperCase(); else delete t.headingID; }
    });
  }

  async completeAll(ids: string[]): Promise<void> { const at = Date.now(); for (const id of ids) await this.finish(id, at); }

  async addTag(tag: string, ids: string[]): Promise<void> {
    const clean = tag.replace(/^[#\s]+|[#\s]+$/g, "");
    if (!clean) return;
    for (const id of ids) await this.changeTask(id, (t) => {
      const tags = (t.tags as string[] | undefined) ?? [];
      if (!tags.some((x) => x.localeCompare(clean, undefined, { sensitivity: "accent" }) === 0)) t.tags = [...tags, clean];
    });
  }

  async skipNext(id: string): Promise<void> {
    const t = this.raw(id);
    const moved = t && skippingNext(t, this.cal);
    if (!moved) return;
    await this.changeTask(id, (x) => {
      for (const k of ["when", "deadline", "reminders", "repeatRule"]) { if (moved[k] === undefined) delete x[k]; else x[k] = moved[k]; }
      delete x.snoozedUntil;
    });
  }

  /** ReminderAction.Snooze: 15 minutes, or tomorrow at 9. */
  async snooze(id: string, how: "15" | "tomorrow" | "clear"): Promise<void> {
    let until: number | null = null;
    if (how === "15") until = appleNow(Date.now() + 15 * 60_000);
    if (how === "tomorrow") { const d = addDays(localToday(), 1); until = appleNow(new Date(d.year, d.month - 1, d.day, 9, 0).getTime()); }
    await this.changeTask(id, (t) => { if (until === null) delete t.snoozedUntil; else t.snoozedUntil = until; });
  }

  // ---- lists ----

  async addList(name: string, kind: "area" | "project" | "smart", area: string | null = null): Promise<string | null> {
    const at = appleNow();
    const order = Math.max(0, ...this.allLists.filter((l) => l.kind === kind).map((l) => l.order)) + 1;
    const list: Raw = { id: newID(), name: name.trim(), kind, headings: [], status: "active", isPinned: false, order, createdAt: at, updatedAt: at };
    if (kind === "project" && area) list.areaID = area.toUpperCase();
    if (kind === "smart") list.rules = { match: "all", rules: [] };
    const ok = await this.run(() => this.putList(list, null, null));
    return ok ? String(list.id).toLowerCase() : null;
  }

  /** TasksModel.changeList: lists keep the newer whole, so the edit time moves on. */
  async changeList(id: string, edit: (l: Raw) => void): Promise<boolean> {
    const held = this.lists.get(id);
    if (!held) return false;
    const next = structuredClone(held.json);
    edit(next);
    if (JSON.stringify(next) === JSON.stringify(held.json)) return true;
    next.updatedAt = Math.max(appleNow(), Number(held.json.updatedAt ?? 0));
    this.lists.set(id, { ...held, json: next });
    this.onChange();
    const ok = await this.run(() => this.putList(next, held.json, held.hash));
    if (!ok) this.lists.set(id, held);
    return !!ok;
  }

  async addHeading(project: string, title: string): Promise<void> {
    const clean = title.trim();
    if (clean) await this.changeList(project, (l) => { l.headings = [...((l.headings as Raw[]) ?? []), { id: newID(), title: clean }]; });
  }

  /** Its tasks stay in the project, above the first heading. */
  async removeHeading(project: string, heading: string): Promise<void> {
    for (const t of this.allTasks.filter((x) => x.listID === project && x.headingID === heading)) await this.changeTask(t.id, (x) => { delete x.headingID; });
    await this.changeList(project, (l) => { l.headings = ((l.headings as Raw[]) ?? []).filter((h) => String(h.id).toLowerCase() !== heading); });
  }

  // ---- undoable delete (TasksModel.delete(tasks:lists:)) ----

  /** Gone at once with no question; Undo brings them back for five seconds; then they're gone for good. Deleting an area or project takes everything in it. */
  async delete(taskIds: string[], listIds: string[] = []): Promise<void> {
    await this.finishDelete();
    const goneLists = new Set(listIds);
    for (const l of this.allLists) if (l.areaID && goneLists.has(l.areaID) && this.allLists.find((a) => a.id === l.areaID)?.kind === "area") goneLists.add(l.id);
    const heldLists = [...goneLists].flatMap((id) => this.lists.get(id) ?? []);
    const heldTasks = this.allTasks.filter((t) => taskIds.includes(t.id) || (t.listID !== null && goneLists.has(t.listID))).flatMap((t) => this.tasks.get(t.id) ?? []);
    if (!heldLists.length && !heldTasks.length) return;
    for (const h of heldTasks) this.tasks.delete(h.id);
    for (const h of heldLists) this.lists.delete(h.id);
    const named = listIds.length === 1 ? heldLists.find((h) => h.id === listIds[0]) : undefined;
    const title = named ? `“${String(named.json.name ?? "").trim() || "List"}” deleted` : listIds.length ? `${listIds.length} lists deleted` : heldTasks.length === 1 ? "1 task deleted" : `${heldTasks.length} tasks deleted`;
    this.pending = { tasks: heldTasks, lists: heldLists, title, timer: setTimeout(() => void this.finishDelete(), UNDO_MS) };
    this.onChange();
  }

  undoDelete(): void {
    const p = this.pending;
    if (!p) return;
    clearTimeout(p.timer);
    this.pending = null;
    for (const h of p.tasks) this.tasks.set(h.id, h);
    for (const h of p.lists) this.lists.set(h.id, h);
    this.onChange();
  }

  /** Makes the delete permanent now. Something another device changed meanwhile is kept, as SyncEngine keeps it. */
  async finishDelete(): Promise<void> {
    const p = this.pending;
    if (!p) return;
    clearTimeout(p.timer);
    this.pending = null;
    let kept = 0;
    await this.run(async () => {
      const token = await this.ctx.token();
      for (const h of [...p.tasks, ...p.lists]) {
        try { await net.tombstoneSealed(token, h.id, h.hash); } catch (e) {
          if (!(e instanceof net.ChangedOnServer)) throw e;
          const isTask = p.tasks.includes(h);
          const server = await fetchHeld(token, h.id, isTask ? TASK.kind : LIST.kind, isTask ? TASK.purpose : LIST.purpose);
          if (server && server !== "deleted") { (isTask ? this.tasks : this.lists).set(h.id, server); kept++; }
        }
      }
    });
    if (kept) this.onStatus(`${kept === 1 ? "One item" : `${kept} items`} changed on another device, so ${kept === 1 ? "it was" : "they were"} kept.`, true);
  }
}
