// Small pieces the screens share: sheets, raised fields, day and time inputs. Everything is built with
// textContent through h(), so nothing typed is ever parsed as markup.
import { h } from "./dom";
import "./ui.css";

/** A date with no time or zone. */
export interface Day { year: number; month: number; day: number }

type Attrs = Record<string, string | boolean | ((e: Event) => void)>;

/** A sheet over the page: a native modal dialog, closed by Escape, Cancel or a click outside. */
export function sheet(title: string, body: Node[], actions: { label: string; primary?: boolean; run: () => unknown }[] = []): HTMLDialogElement {
  const dialog = h("dialog", { class: "sheet", "aria-label": title });
  const close = () => { dialog.close(); dialog.remove(); };
  const foot = h("div", { class: "sheet-foot" }, h("span", { class: "grow" }),
    h("button", { type: "button", class: "quiet", onclick: close }, actions.length ? "Cancel" : "Done"),
    ...actions.map((a) => h("button", { type: "button", class: a.primary ? "" : "quiet", onclick: async () => { if ((await a.run()) !== false) close(); } }, a.label)));
  dialog.append(h("h2", {}, title), ...body, foot);
  dialog.addEventListener("click", (e) => { if (e.target === dialog) close(); });
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
  return dialog;
}

export const field = (label: string, control: HTMLElement): HTMLElement => h("label", { class: "field" }, h("span", { class: "field-label" }, label), control);
export const input = (attrs: Attrs = {}): HTMLInputElement => h("input", { type: "text", ...attrs });
export function select(options: [string, string][], value: string, attrs: Attrs = {}): HTMLSelectElement {
  const s = h("select", attrs);
  for (const [v, label] of options) { const o = h("option", { value: v }, label); if (v === value) o.selected = true; s.append(o); }
  return s;
}
export const seg = (label: string, on: boolean, run: () => void): HTMLButtonElement =>
  h("button", { type: "button", class: "seg" + (on ? " on" : ""), "aria-pressed": on ? "true" : "false", onclick: run }, label);

export const dayValue = (d: Day | null): string => (d ? `${d.year}-${String(d.month).padStart(2, "0")}-${String(d.day).padStart(2, "0")}` : "");
export function dayFrom(v: string): Day | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
  return m ? { year: +m[1]!, month: +m[2]!, day: +m[3]! } : null;
}
export const timeValue = (t: { hour: number; minute: number } | null | undefined): string => (t ? `${String(t.hour).padStart(2, "0")}:${String(t.minute).padStart(2, "0")}` : "");
export function timeFrom(v: string): { hour: number; minute: number } | null {
  const m = /^(\d{2}):(\d{2})/.exec(v);
  return m && +m[1]! < 24 && +m[2]! < 60 ? { hour: +m[1]!, minute: +m[2]! } : null;
}

/** Runs `f` once typing stops for a moment, and at once when the field loses focus. */
export function onSettled(el: HTMLInputElement | HTMLTextAreaElement, f: (v: string) => void, ms = 700): void {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let last = el.value;
  const fire = () => { if (timer) clearTimeout(timer); timer = null; if (el.value !== last) { last = el.value; f(el.value); } };
  el.addEventListener("input", () => { if (timer) clearTimeout(timer); timer = setTimeout(fire, ms); });
  el.addEventListener("blur", fire);
}

export const plural = (n: number, one: string, many = one + "s"): string => `${n} ${n === 1 ? one : many}`;
