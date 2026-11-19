import "./tokens.css";
import "./styles.css";
import { h, svg } from "./dom";
import { isConfigured } from "./config";
import * as net from "./net";
import * as vault from "./keystore";
import { IdleLock } from "./idle";
import { qrElement } from "./qr";
import { renderShell, teardownShell } from "./shell";
import { newBrowserKeys, openSealed, pairingCode, qrText, unb64, fromHex, PairingFailure } from "./pairing/protocol";

// Signed out → (sign in) → pairing with the iPhone → unlocked. "Locked" is signed in with no key in memory.
// Passwords sign you in and do nothing else: this file hands the password to net.signIn and forgets it.

const THEMES = ["default", "blush", "sky", "sage", "lilac", "graphite"];
const app = document.getElementById("app")!;

let session: net.Session | null = null;
let ownComputer = true; // the canvas's default; the person can change it while pairing
let pairingRun = 0;
const idle = new IdleLock(() => { vault.lockMemory(); show(lockedScreen()); });

function applyStoredTheme(): void {
  try {
    const saved = localStorage.getItem("totality.theme");
    if (saved && THEMES.includes(saved)) document.documentElement.dataset.theme = saved;
  } catch { /* storage can be blocked */ }
}

function show(screen: Node): void { pairingRun++; teardownShell(); app.replaceChildren(screen); }

const lockIcon = (stroke = "currentColor") =>
  svg("svg", { width: "15", height: "15", viewBox: "0 0 24 24", "stroke-width": "2.2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", stroke, fill: "none" },
    svg("rect", { x: "5", y: "11", width: "14", height: "10", rx: "2" }), svg("path", { d: "M8 11V7a4 4 0 0 1 8 0v4" }));
const note = (text: string) => h("div", { class: "note" }, lockIcon(), h("span", {}, text));

function deviceLabel(): string {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "A browser";
  const os = /Windows/.test(ua) ? "Windows" : /Mac OS X|Macintosh/.test(ua) ? "a Mac" : /Linux|X11/.test(ua) ? "Linux" : "a computer";
  return `${browser} on ${os}`;
}

async function freshToken(): Promise<string> {
  if (!session) throw new net.NetError("wrongPassword");
  if (session.expiresAt - 60_000 < Date.now()) {
    session = await net.refresh(session.refreshToken);
    if (ownComputer) await vault.saveSession(session).catch(() => {});
  }
  return session.accessToken;
}

// ---- screens ----

function intro(): HTMLElement {
  return h("div", { class: "intro" },
    h("span", { class: "badge", role: "img", "aria-label": "Totality" },
      svg("svg", { width: "26", height: "26", viewBox: "0 0 24 24", "aria-hidden": "true" },
        ...[[12, 6], [6.5, 10], [17.5, 10], [8.5, 16.5], [15.5, 16.5], [12, 12]].map(([x, y]) => svg("circle", { cx: String(x), cy: String(y), r: x === 12 && y === 12 ? "3" : "3.2" })))),
    h("h1", {}, "Your Totality, on a bigger screen."),
    h("p", { class: "lede" }, "Reader, Mail, Calendar, Messages, Tasks and Photos, with the same account and the same keys as your iPhone."));
}

function signInScreen(message = ""): Node {
  const status = h("p", { class: "status", role: "status", "aria-live": "polite" }, message);
  const user = h("input", { name: "username", type: "text", autocomplete: "username", autocapitalize: "none", spellcheck: "false", required: true });
  const pass = h("input", { name: "password", type: "password", autocomplete: "current-password", required: true });
  const go = h("button", { type: "submit" }, "Sign in");
  const form = h("form", { class: "card", autocomplete: "on" },
    h("h2", {}, "Sign in"), h("label", {}, "Username", user), h("label", {}, "Password", pass), go, status,
    note("Your password only signs you in."));
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!isConfigured()) { status.textContent = "This site isn't connected to Totality's servers yet."; return; }
    go.disabled = true; status.textContent = "Signing in…";
    try {
      session = await net.signIn(user.value, pass.value);
            pass.value = "";
      startPairing();
    } catch (err) {
      pass.value = "";
      const kind = err instanceof net.NetError ? err.kind : "failed";
      status.textContent = kind === "wrongPassword" ? "That username and password don't match." : kind === "offline" ? "Couldn't reach Totality. Check your connection." : kind === "rateLimited" ? "Too many tries. Wait a minute and try again." : "Couldn't sign in. Try again.";
      go.disabled = false;
    }
  });
  return h("main", { class: "stage" }, intro(), form);
}

function modeChoice(): HTMLElement {
  const radio = (value: "own" | "shared", title: string, sub: string) => {
    const input = h("input", { type: "radio", name: "who", value, class: "switch", ...(ownComputer === (value === "own") ? { checked: true } : {}) });
    input.addEventListener("change", () => { ownComputer = value === "own"; });
    return h("label", { class: "choice" }, input, h("span", { class: "choice-text" }, h("b", {}, title), h("span", { class: "sub" }, sub)));
  };
  return h("div", { class: "card" },
    h("h2", {}, "Who uses this computer?"),
    radio("own", "This is my computer", "Stay unlocked, even after you close the browser, until you sign out or remove it under Devices."),
    radio("shared", "This is a shared computer", "Lock when you close the tab, or after 30 minutes with no activity. Nothing stays behind."),
    h("p", { class: "fineprint" }, "Anyone who can use a computer you marked as yours, while you are signed in, can read your Totality."),
    h("button", { type: "button", class: "quiet", onclick: () => signOutNow() }, "Sign out"));
}

function startPairing(): void {
  teardownShell();
  const run = ++pairingRun;
  const keys = newBrowserKeys();
  const body = h("div", { class: "card pair" }, h("div", { class: "step" }, "Step 2 of 2"), h("h2", {}, "Add this browser from your iPhone"),
    h("p", { class: "lede small" }, "On your iPhone, open Totality, go to Account, then Devices, tap Pair a browser, and scan this code."),
    h("p", { class: "status", role: "status" }, "Making a code…"));
  app.replaceChildren(h("main", { class: "stage" }, body, modeChoice()));
  const fail = (text: string) => body.replaceChildren(h("h2", {}, "Couldn't make a code"), h("p", { class: "status" }, text),
    h("button", { type: "button", onclick: () => startPairing() }, "Try again"));

  (async () => {
    let token: string, slot: net.Slot;
    try {
      token = await freshToken();
      slot = await net.createSlot(token, keys.pub, deviceLabel());
    } catch (e) {
      if (run !== pairingRun) return;
      if (e instanceof net.NetError && e.kind === "wrongPassword") { session = null; show(signInScreen("Please sign in again.")); return; }
      fail("Check your connection and try again."); return;
    }
    if (run !== pairingRun) return;
    const left = h("span", { class: "sub" });
    body.replaceChildren(
      h("div", { class: "step" }, "Step 2 of 2"), h("h2", {}, "Add this browser from your iPhone"),
      h("p", { class: "lede small" }, "On your iPhone, open Totality, go to Account, then Devices, tap Pair a browser, and scan this code."),
      h("div", { class: "qr-wrap" }, qrElement(qrText(slot.id, keys), "Code to scan with your iPhone")),
      h("div", { class: "code-row" }, h("span", { class: "sub" }, "Then check the same code shows on your iPhone"), h("span", { class: "code" }, pairingCode(slot.id, keys.pub))),
      note("This code works once and expires in 2 minutes. Your keys are sent sealed to this browser only."),
      h("div", { class: "row" }, left, h("button", { type: "button", class: "quiet", onclick: () => { void net.deleteSlot(token, slot.id); startPairing(); } }, "New code")));
    const tick = setInterval(async () => {
      if (run !== pairingRun) { clearInterval(tick); return; }
      const secs = Math.max(0, Math.round((slot.expiresAt - Date.now()) / 1000));
      left.textContent = `Expires in ${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`;
      if (secs === 0) { clearInterval(tick); startPairing(); return; }
      try {
        const answer = await net.pollSlot(await freshToken(), slot.id);
        if (!answer || run !== pairingRun) return;
        clearInterval(tick);
        const root = openSealed({ slotId: slot.id, keys, phonePub: fromHex(answer.phonePub, 32), sealed: unb64(answer.sealed) });
        await vault.adoptContentKey(root, ownComputer);
        if (ownComputer && session) await vault.saveSession(session);
        await net.deleteSlot(await freshToken(), slot.id);
        unlocked();
      } catch (e) {
        clearInterval(tick);
        if (run !== pairingRun) return;
        fail(e instanceof PairingFailure ? "What came back didn't check out, so it was thrown away. Make a new code." : "Check your connection and try again.");
      }
    }, 2000);
  })();
}

function unlocked(): void {
  if (!ownComputer) idle.start(); else idle.stop();
  pairingRun++;
  if (!session) { show(signInScreen()); return; }
  renderShell(app, { token: freshToken, userId: session.userId }, session.username, () => void signOutNow());
}

function lockedScreen(): Node {
  return h("main", { class: "stage" }, h("div", { class: "card locked" },
    h("span", { class: "badge" }, lockIcon("var(--accent)")),
    h("h2", {}, "Locked after 30 minutes"),
    h("p", { class: "lede small" }, "You were away, so Totality locked this browser. Nothing private is on screen. You are still signed in."),
    h("button", { type: "button", onclick: () => startPairing() }, "Approve from my iPhone"),
    h("button", { type: "button", class: "quiet", onclick: () => signOutNow() }, "Sign out"),
    h("p", { class: "fineprint" }, "Shared computer mode is on. Mark it as your own computer to stay unlocked.")));
}

async function signOutNow(): Promise<void> {
  idle.stop();
  const token = session?.accessToken;
  session = null;
  await vault.wipe();
  if (token) await net.signOut(token);
  show(signInScreen());
}

async function boot(): Promise<void> {
  applyStoredTheme();
  for (const ev of ["pointerdown", "keydown", "scroll"]) addEventListener(ev, () => idle.touch(), { passive: true });
  if (isConfigured()) {
    const saved = await vault.loadSessionToken();
    if (saved) {
      try {
        session = await net.refresh(saved);
        ownComputer = true;
        await vault.saveSession(session);
        if (await vault.loadContentKey()) { unlocked(); return; }
        startPairing(); return;
      } catch { await vault.wipe(); session = null; }
    }
  }
  show(signInScreen());
}

void boot();
