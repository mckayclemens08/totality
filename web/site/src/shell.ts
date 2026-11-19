// The signed-in frame: a sidebar of modules and the module beside it (website canvas, Home and Reader boards).
// Only modules that exist are links. The rest wait, as the owner's order says: Reader, Mail, Calendar,
// Messages, Tasks, Photos.
import { h, svg } from "./dom";
import { showReader, stopReader, type Ctx } from "./reader/view";
import { showCalendar, stopCalendar } from "./calendar/view";
import { showTasks, stopTasks } from "./tasks/view";
import { showPhotos, stopPhotos } from "./photos/view";

interface Module { id: string; name: string; icon: string[]; ready: boolean; blurb: string }
const MODULES: Module[] = [
  { id: "reader", name: "Reader", icon: ["M4 4h7v16H4zM13 4h7v16h-7z"], ready: true, blurb: "Your docs and notes, opened in this browser." },
  { id: "mail", name: "Mail", icon: ["M3 5h18v14H3z", "m3 7 9 6 9-6"], ready: false, blurb: "" },
  { id: "calendar", name: "Calendar", icon: ["M3 5h18v16H3z", "M3 10h18M8 3v4M16 3v4"], ready: true, blurb: "Your events by day, week and month." },
  { id: "messages", name: "Messages", icon: ["M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"], ready: false, blurb: "" },
  { id: "tasks", name: "Tasks", icon: ["M4 4h16v16H4z", "m8 12 3 3 5-6"], ready: true, blurb: "Today, Upcoming, lists and steps." },
  { id: "photos", name: "Photos", icon: ["M3 5h18v15H3z", "m21 17-5-5-9 8"], ready: true, blurb: "Your library, newest first." },
];
const HOME_ICON = ["M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z"];

const icon = (paths: string[]) =>
  svg("svg", { width: "20", height: "20", viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "2.2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" },
    ...paths.map((d) => svg("path", { d })));

let listener: (() => void) | null = null;
export function teardownShell(): void {
  if (listener) removeEventListener("hashchange", listener);
  listener = null;
  stopReader();
  stopCalendar();
  stopTasks();
  stopPhotos();
}

export function renderShell(into: HTMLElement, ctx: Ctx, username: string, onSignOut: () => void): void {
  teardownShell();
  const main = h("main", { class: "module", id: "module" });
  const nav = h("nav", { class: "side", "aria-label": "Modules" });

  const route = () => {
    const [, mod = "home", id = null] = location.hash.split("/");
    const current = mod === "reader" || mod === "calendar" || mod === "tasks" || mod === "photos" ? mod : "home";
    nav.replaceChildren(
      h("div", { class: "brand" }, h("span", { class: "badge small" }, svg("svg", { width: "18", height: "18", viewBox: "0 0 24 24", "aria-hidden": "true" },
        ...[[12, 6], [6.5, 10], [17.5, 10], [8.5, 16.5], [15.5, 16.5]].map(([x, y]) => svg("circle", { cx: String(x), cy: String(y), r: "3.2" })), svg("circle", { cx: "12", cy: "12", r: "3" }))), h("span", { class: "brand-name" }, "Totality")),
      h("a", { href: "#/home", class: "nav-item" + (current === "home" ? " on" : ""), ...(current === "home" ? { "aria-current": "page" } : {}) }, icon(HOME_ICON), h("span", {}, "Home")),
      ...MODULES.map((m) => m.ready
        ? h("a", { href: `#/${m.id}`, class: "nav-item" + (current === m.id ? " on" : ""), ...(current === m.id ? { "aria-current": "page" } : {}) }, icon(m.icon), h("span", {}, m.name))
        : h("span", { class: "nav-item soon", "aria-disabled": "true" }, icon(m.icon), h("span", {}, m.name), h("span", { class: "soon-tag" }, "Soon"))),
      h("div", { class: "who" }, h("div", { class: "who-name" }, `@${username}`),
        h("button", { type: "button", class: "quiet small-btn", onclick: onSignOut }, "Sign out")));
    stopCalendar(); stopReader(); stopTasks(); stopPhotos();
    if (current === "reader") { void showReader(main, ctx, id && /^[0-9a-f-]{36}$/.test(id) ? id : null); return; }
    if (current === "calendar") { void showCalendar(main, ctx); return; }
    if (current === "photos") { void showPhotos(main, ctx); return; }
    if (current === "tasks") { const [, , v = null, t = null] = location.hash.split("/"); void showTasks(main, ctx, v && /^[a-z0-9-]+$/.test(v) ? v : null, t && /^[0-9a-f-]{36}$/.test(t) ? t : null); return; }
    main.replaceChildren(
      h("div", { class: "page-head" }, h("h1", {}, "Home")),
      h("div", { class: "tiles" }, ...MODULES.map((m) => m.ready
        ? h("a", { href: `#/${m.id}`, class: "tile" }, icon(m.icon), h("div", { class: "tile-name" }, m.name), h("div", { class: "sub" }, m.blurb))
        : h("div", { class: "tile soon", "aria-disabled": "true" }, icon(m.icon), h("div", { class: "tile-name" }, m.name), h("div", { class: "sub" }, "Coming to the website soon")))));
  };
  listener = route;
  addEventListener("hashchange", route);
  into.replaceChildren(h("div", { class: "shell" }, nav, main));
  route();
}
