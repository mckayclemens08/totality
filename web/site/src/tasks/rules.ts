// ListRules.swift's smart lists: which open tasks a list's rules find. No rules finds nothing.
import { daysBetween, type Day } from "./repeat";
import type { Task, TaskList } from "./model";

export interface SmartRule { id: string; kind: string; isNegated: boolean; tag?: string; listID?: string; priority?: number; days?: number }
export interface SmartRules { match: "all" | "any"; rules: SmartRule[] }
export const RULE_KINDS: { id: string; name: string }[] = [
  { id: "tag", name: "Tag" }, { id: "area", name: "Area" }, { id: "project", name: "Project" }, { id: "priority", name: "Priority" },
  { id: "when", name: "When" }, { id: "deadline", name: "Deadline" }, { id: "hasNote", name: "Has a note" },
];

export function parseRules(v: unknown): SmartRules | null {
  const o = v as { match?: unknown; rules?: unknown } | null;
  if (!o || typeof o !== "object") return null;
  const rules = (Array.isArray(o.rules) ? o.rules : []).flatMap((r): SmartRule[] => {
    const x = r as Record<string, unknown>;
    if (typeof x.id !== "string") return [];
    const out: SmartRule = { id: x.id, kind: typeof x.kind === "string" && RULE_KINDS.some((k) => k.id === x.kind) ? x.kind : "unknown", isNegated: x.isNegated === true };
    if (typeof x.tag === "string") out.tag = x.tag;
    if (typeof x.listID === "string") out.listID = x.listID;
    if (Number.isInteger(x.priority)) out.priority = x.priority as number;
    if (Number.isInteger(x.days)) out.days = x.days as number;
    return [out];
  });
  return { match: o.match === "any" ? "any" : "all", rules };
}

const normalTag = (t: string): string => t.replace(/^[# ]+|[# ]+$/g, "").toLowerCase();

export function areaOf(t: Task, lists: TaskList[]): string | null {
  const list = t.listID ? lists.find((l) => l.id === t.listID) : undefined;
  if (!list) return null;
  return list.kind === "area" ? list.id : list.kind === "project" ? list.areaID : null;
}

function within(day: Day | null, days: number | undefined, today: Day): boolean {
  if (!day) return false;
  return days === undefined ? true : daysBetween(today, day) <= days;
}

export function matchesRule(t: Task, r: SmartRule, lists: TaskList[], today: Day): boolean {
  let found: boolean;
  switch (r.kind) {
    case "tag": {
      const wanted = r.tag !== undefined ? normalTag(r.tag) : "";
      if (!wanted) return false;
      found = t.tags.map(normalTag).some((x) => x === wanted || x.startsWith(wanted + "/"));
      break;
    }
    case "area": if (!r.listID) return false; found = areaOf(t, lists) === r.listID.toLowerCase(); break;
    case "project": if (!r.listID) return false; found = t.listID === r.listID.toLowerCase(); break;
    case "priority": if (r.priority === undefined) return false; found = t.priority === r.priority; break;
    case "when": found = within(t.when, r.days, today); break;
    case "deadline": found = within(t.deadline, r.days, today); break;
    case "hasNote": found = t.notes.trim().length > 0; break;
    default: return false;
  }
  return r.isNegated ? !found : found;
}

export function smartTasks(rules: SmartRules, tasks: Task[], lists: TaskList[], today: Day): Task[] {
  if (!rules.rules.length) return [];
  const check = (t: Task) => (rules.match === "all" ? rules.rules.every((r) => matchesRule(t, r, lists, today)) : rules.rules.some((r) => matchesRule(t, r, lists, today)));
  const cmp = (a: Day, b: Day) => a.year - b.year || a.month - b.month || a.day - b.day;
  return tasks.filter((t) => t.completedAt === null && check(t)).sort((a, b) => {
    if (a.deadline && b.deadline && cmp(a.deadline, b.deadline) !== 0) return cmp(a.deadline, b.deadline);
    if (a.deadline && !b.deadline) return -1;
    if (!a.deadline && b.deadline) return 1;
    return a.order === b.order ? a.createdAt - b.createdAt : a.order - b.order;
  });
}
