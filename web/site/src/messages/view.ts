// Messages on the website (mockup: claude.ai/artifact/TQMroVuDCR6uJZ79GvZ6Bu). Everything is built with
// textContent through h(); message text is never parsed as markup. The SDK loads only when this opens.
import { h, svg } from "../dom";
import type { Ctx } from "../reader/view";
import type { Engine, ChatSummary, KeysState } from "./engine";
import { blobUrl, revoke, revokeAll, preparePhoto, prepareVideo, prepareGroupPhoto } from "./media";
import { cancelConnecting } from "./session";
import {
  DISAPPEARING, GroupLabels, LockedMessage, QUICK_REACTIONS, SHARE_READ_KEY, cleanGroupName, disappearingExplanation, disappearingLabel,
  displayName, dueMessages, parseGroupMembers, visibleMessages, type ChatMessage,
} from "./rules";

type MessagesCtx = Ctx & { ownComputer?: boolean };
let engine: Engine | null = null;
let connecting: Promise<Engine> | null = null;
let run = 0;
let unsubscribe: (() => void) | null = null;
let clock: ReturnType<typeof setInterval> | null = null;
let leaveChat: (() => void) | null = null;

/** Leaves the screen; the connection stays up while this browser is unlocked. */
export function stopMessages(): void {
  run++;
  leaveChat?.(); leaveChat = null;
  unsubscribe?.(); unsubscribe = null;
  if (clock) clearInterval(clock);
  clock = null;
  revokeAll();
  thumbs.clear(); groupPhotos.clear();
}
/** Locking or signing out: ends the connection too. Chats leave memory with it. */
export async function endMessages(): Promise<void> {
  stopMessages();
  cancelConnecting();
  const e = engine;
  engine = null; connecting = null;
  await e?.stop();
}

// ---- small pieces ----

const ICONS = {
  shield: ["M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6z", "m9 12 2 2 4-4"],
  pen: ["M4 20h4L19 9l-4-4L4 16z"], plus: ["M12 5v14M5 12h14"], send: ["M22 2 11 13M22 2l-7 20-4-9-9-4z"],
  lock: ["M5 11h14v10H5z", "M8 11V7a4 4 0 0 1 8 0v4"], more: ["M5 12h.01M12 12h.01M19 12h.01"], phone: ["M7 2h10v20H7z", "M11 18h2"],
  back: ["M15 18l-6-6 6-6"], check: ["m5 12 5 5 9-10"], play: ["M8 5v14l11-7z"],
};
const icon = (paths: string[], size = 18) =>
  svg("svg", { width: String(size), height: String(size), viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "2.2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" }, ...paths.map((d) => svg("path", { d })));
const status = (text: string) => h("p", { class: "status", role: "status", "aria-live": "polite" }, text);
const when = (ms: number | null): string => {
  if (!ms) return "";
  const d = new Date(ms), now = new Date();
  const mins = Math.round((now.getTime() - ms) / 60000);
  if (mins < 1) return "now";
  if (mins < 60) return `${mins} min`;
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return "Yest.";
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
};
const errorText = (e: unknown): string => (e instanceof Error && e.message ? e.message : "Something went wrong. Try again.");
const avatar = (name: string, cls = "avatar") => h("span", { class: cls, "aria-hidden": "true" }, (name.replace(/^@/, "")[0] ?? "?").toUpperCase());

function store(key: string, value?: string): string | null {
  try { if (value === undefined) return localStorage.getItem(key); localStorage.setItem(key, value); } catch { /* storage can be blocked */ }
  return null;
}
const shareRead = (): boolean => store(SHARE_READ_KEY) !== "false";
const viewedKey = (room: string) => `totality.messages.viewedUpTo.${room}`;

function dialog(title: string, ...body: (Node | null)[]): HTMLDialogElement {
  const d = h("dialog", { class: "msg-dialog", "aria-label": title });
  d.append(h("h2", {}, title), ...body.filter((n): n is Node => !!n));
  d.addEventListener("close", () => d.remove());
  document.body.append(d);
  d.showModal();
  return d;
}
function confirmDialog(title: string, text: string, action: string, danger = true): Promise<boolean> {
  return new Promise((resolve) => {
    let answered = false;
    const yes = h("button", { type: "button", class: danger ? "danger" : "", onclick: () => { answered = true; resolve(true); d.close(); } }, action);
    const no = h("button", { type: "button", class: "quiet", onclick: () => d.close() }, "Cancel");
    const d = dialog(title, h("p", { class: "lede small" }, text), h("div", { class: "row end" }, no, yes));
    d.addEventListener("close", () => { if (!answered) resolve(false); });
  });
}

// ---- entry ----

export async function showMessages(into: HTMLElement, ctx: MessagesCtx, chatId: string | null): Promise<void> {
  stopMessages();
  const mine = run;
  const head = h("div", { class: "page-head msg-head" }, h("h1", {}, "Messages"));
  const body = h("div", { class: "msg-body" });
  into.replaceChildren(head, body);

  // Shared computers don't get Messages (owner, 2026-11-18): nothing is left signed in after you walk away.
  if (ctx.ownComputer === false) { body.replaceChildren(sharedScreen()); return; }

  body.replaceChildren(status("Opening Messages…"));
  try {
    if (!engine) {
      connecting ??= import("./engine").then(({ Engine: E }) => E.connect(ctx.token, ctx.userId));
      engine = await connecting;
    }
  } catch (e) {
    connecting = null;
    if (mine !== run) return;
    const kind = (e as { kind?: string }).kind;
    body.replaceChildren(h("section", { class: "panel msg-card setup" }, h("h2", {}, "Messages couldn't open"),
      h("p", { class: "lede small" }, kind === "offline" ? "Couldn't reach Totality. Check your connection." : errorText(e)),
      h("button", { type: "button", onclick: () => void showMessages(into, ctx, chatId) }, "Try again")));
    return;
  }
  if (mine !== run) return;
  const e = engine;
  if (e.keys.kind !== "ready") {
    const setup = setupScreen();
    body.replaceChildren(setup.node);
    const result = await e.settleKeys((s) => { if (mine === run) setup.update(s); });
    if (mine !== run) return;
    if (result.kind === "noBackup" || result.kind === "doesntOpen" || result.kind === "failed") {
      body.replaceChildren(problemScreen(result, () => void showMessages(into, ctx, chatId)));
      return;
    }
    if (result.kind === "ready" && result.restoredJustNow) {
      await new Promise<void>((done) => setup.finish(done));
      if (mine !== run) return;
    }
  }
  head.append(
    h("a", { class: "chip-link", href: "#/messages", onclick: (ev: Event) => { ev.preventDefault(); verifiedInfo(); } }, icon(ICONS.shield, 16), "This browser is verified"),
    h("button", { type: "button", class: "quiet icon-btn", "aria-label": "More", onclick: () => moreMenu(e) }, icon(ICONS.more)),
    h("button", { type: "button", onclick: () => newChat(e) }, icon(ICONS.pen, 16), "New chat"));
  mainScreen(body, e, chatId, mine);
}

// ---- setup and problems ----

function setupScreen(): { node: HTMLElement; update: (s: KeysState) => void; finish: (done: () => void) => void } {
  const step = (title: string, sub: string) => {
    const mark = h("span", { class: "step-mark" });
    const text = h("span", { class: "step-sub" }, sub);
    const li = h("li", { class: "setup-step" }, mark, h("span", { class: "grow" }, h("b", {}, title), text));
    return { li, mark, text };
  };
  const a = step("Signed in to Messages", "On this browser as “Totality web”");
  const b = step("Verifying with your account's keys", "So your iPhone and the people you talk to see it as yours");
  const c = step("Restoring your message history", "Waiting");
  const bar = h("progress", { class: "restore-bar", max: "1", value: "0" });
  c.li.querySelector(".grow")!.append(bar);
  const done = (s: ReturnType<typeof step>) => { s.li.classList.add("done"); s.mark.replaceChildren(icon(ICONS.check, 16)); };
  done(a);
  const open = h("button", { type: "button", disabled: true }, "Open Messages");
  const node = h("section", { class: "panel msg-card setup" },
    h("span", { class: "badge" }, icon(ICONS.shield, 30)),
    h("h2", {}, "Setting up Messages on this browser"),
    h("p", { class: "lede small" }, "This happens once. Your iPhone already trusted this browser when you paired it, so there's nothing to type."),
    h("ol", { class: "setup-steps", "aria-label": "Progress" }, a.li, b.li, c.li),
    h("p", { class: "sub" }, "New messages already work. Older ones open as their keys arrive. You'll find this browser in Devices on your iPhone, where you can remove it."),
    open);
  return {
    node,
    update: (s) => {
      if (s.kind === "restoring" || s.kind === "ready") done(b);
      if (s.kind === "restoring") {
        c.li.classList.add("on");
        c.text.textContent = s.total ? `${s.done.toLocaleString()} of ${s.total.toLocaleString()} chat keys` : "Starting";
        bar.setAttribute("max", String(Math.max(1, s.total))); bar.setAttribute("value", String(s.done));
      }
      if (s.kind === "ready") { done(c); c.text.textContent = "Done"; bar.remove(); }
    },
    finish: (go) => { open.disabled = false; open.onclick = () => go(); open.focus(); },
  };
}

function problemScreen(s: KeysState, retry: () => void): HTMLElement {
  if (s.kind === "noBackup") {
    return h("section", { class: "panel msg-card setup" }, h("span", { class: "badge" }, icon(ICONS.phone, 30)),
      h("h2", {}, "Open Messages on your iPhone once"),
      h("p", { class: "lede small" }, "Your message history isn't backed up with your recovery key yet, so this browser can't verify itself or show your chats. Open Messages on your iPhone and it sets this up on its own."),
      h("p", { class: "sub" }, "This browser never makes new message keys for your account. That would lock your iPhone out of your chats."),
      h("button", { type: "button", onclick: retry }, "Check again"));
  }
  const text = s.kind === "doesntOpen"
    ? "Your history backup didn't open with your recovery key. Messages on this browser needs it, so it stays off here for now. Your iPhone keeps working."
    : s.kind === "failed" ? s.message : "Something went wrong.";
  return h("section", { class: "panel msg-card setup" }, h("h2", {}, "Messages can't start here yet"), h("p", { class: "lede small" }, text),
    h("button", { type: "button", onclick: retry }, "Check again"));
}

function sharedScreen(): HTMLElement {
  return h("section", { class: "panel msg-card setup" }, h("span", { class: "badge" }, icon(ICONS.lock, 30)),
    h("h2", {}, "Messages stays on your own devices"),
    h("p", { class: "lede small" }, "On a shared computer, Messages is off. Signing in to chats here would leave this computer listed as one of your devices after you walk away."),
    h("p", { class: "lede small" }, "Reader, Mail, Calendar, Tasks and Photos still work here."),
    h("a", { class: "button-link quiet", href: "#/home" }, "Back to Home"),
    h("p", { class: "sub" }, "If this is your computer, sign out and pair again as “My computer”."));
}

function verifiedInfo(): void {
  const d = dialog("This browser is verified",
    h("p", { class: "lede small" }, "It's signed with your account's own keys, the same way your iPhone is, so your contacts see it as yours. Messages are end-to-end encrypted here too."),
    h("p", { class: "sub" }, "To remove it, open Devices on your iPhone, or sign out here. Signing out deletes this browser's message keys."));
  d.append(h("div", { class: "row end" }, h("button", { type: "button", onclick: () => d.close() }, "Done")));
}

// ---- the list and the chat ----

const thumbs = new Map<string, string>(); // message id → blob URL, "" while loading, FAILED when it can't load
const FAILED = "failed";
const groupPhotos = new Map<string, string>(); // mxc → blob URL

function mainScreen(body: HTMLElement, e: Engine, startChat: string | null, mine: number): void {
  const list = h("section", { class: "panel msg-list", "aria-label": "Chats" });
  const chatPane = h("section", { class: "panel msg-chat" });
  const offline = h("p", { class: "status msg-offline", role: "status" });
  body.replaceChildren(offline, h("div", { class: "msg-split" }, list, chatPane));
  let current: string | null = startChat && e.room(startChat) ? startChat : null;
  let chat: ReturnType<typeof chatView> | null = null;

  const open = (id: string | null) => {
    leaveChat?.(); leaveChat = null; chat = null;
    current = id;
    history.replaceState(null, "", id ? `#/messages/${encodeURIComponent(id)}` : "#/messages");
    body.classList.toggle("in-chat", !!id);
    if (!id) { chatPane.replaceChildren(h("p", { class: "status" }, e.chats().some((c) => !c.isRequest) ? "Pick a chat." : "No chats yet. Start one with New chat.")); }
    else { chat = chatView(chatPane, e, id, () => open(null)); leaveChat = chat.leave; }
    draw();
  };

  const row = (c: ChatSummary) => {
    const photo = c.photo ? groupPhotos.get(c.photo) : undefined;
    if (c.photo && photo === undefined) {
      groupPhotos.set(c.photo, "");
      void e.groupPhoto(c.photo).then((b) => { if (mine === run && c.photo) { groupPhotos.set(c.photo, blobUrl(b, "image/jpeg")); draw(); } }).catch(() => {});
    }
    const pic = photo ? h("img", { class: "avatar", src: photo, alt: "" }) : avatar(c.title);
    const sub = c.lastMessage ?? (c.isGroup ? "New group" : "New chat");
    return h("button", { type: "button", class: "chat-row" + (c.id === current ? " on" : "") + (c.unread ? " unread" : ""), onclick: () => open(c.id), ...(c.id === current ? { "aria-current": "true" } : {}) },
      pic, h("span", { class: "grow" }, h("span", { class: "chat-title" }, c.title), h("span", { class: "chat-sub" }, c.unread ? `${c.unread} new message${c.unread === 1 ? "" : "s"}` : sub)),
      h("span", { class: "chat-time" }, when(c.lastActivity)));
  };
  const request = (c: ChatSummary) => {
    const busy = (b: HTMLButtonElement, work: () => Promise<void>, after?: () => void) => async () => {
      b.disabled = true;
      try { await work(); after?.(); } catch (err) { b.disabled = false; note.textContent = errorText(err); }
    };
    const note = h("span", { class: "chat-sub", role: "status" }, c.isGroup ? "Invited you to a group" : "Wants to chat");
    const accept = h("button", { type: "button", class: "small-btn" }, "Accept");
    const decline = h("button", { type: "button", class: "quiet small-btn" }, "Decline");
    const block = h("button", { type: "button", class: "quiet small-btn" }, "Block");
    accept.onclick = busy(accept, () => e.accept(c.id), () => open(c.id));
    decline.onclick = busy(decline, () => e.decline(c.id));
    block.onclick = async () => { if (await confirmDialog(`Block ${c.from ? displayName(c.from) : "them"}?`, "They won't be able to message you, and this request goes away. You can unblock people later.", "Block")) await busy(block, () => e.blockRequest(c.id))(); };
    return h("div", { class: "request" }, h("div", { class: "chat-row static" }, avatar(c.title), h("span", { class: "grow" }, h("span", { class: "chat-title" }, c.title), note)),
      h("div", { class: "row" }, accept, decline, block));
  };

  const draw = () => {
    if (mine !== run) return;
    offline.textContent = e.online ? "" : "You're offline. Messages will send when you're back.";
    if (e.keys.kind === "failed") { body.replaceChildren(problemScreen(e.keys, () => location.reload())); return; }
    const all = e.chats();
    const requests = all.filter((c) => c.isRequest), chats = all.filter((c) => !c.isRequest);
    list.replaceChildren(
      ...(requests.length ? [h("div", { class: "panel-title" }, "Requests"), ...requests.map(request), h("div", { class: "panel-title" }, "Chats")] : []),
      ...(chats.length ? chats.map(row) : [h("p", { class: "status" }, "No chats yet.")]));
    if (current && !e.room(current)) { open(null); return; }
    chat?.draw();
  };
  unsubscribe = e.subscribe(draw);
  clock = setInterval(draw, 30_000);
  open(current);
}

function chatView(pane: HTMLElement, e: Engine, roomId: string, back: () => void): { draw: () => void; leave: () => void } {
  let replyingTo: ChatMessage | null = null;
  let selected: string | null = null;
  let lastCount = 0;
  let typingSent = 0;
  const removing = new Set<string>();
  const viewed = Number(store(viewedKey(roomId)) ?? "") || null;
  let newest = 0;

  const title = h("div", { class: "chat-head-title" });
  const sub = h("div", { class: "chat-head-sub" });
  const head = h("div", { class: "chat-head" },
    h("button", { type: "button", class: "quiet icon-btn back-btn", "aria-label": "Back to chats", onclick: back }, icon(ICONS.back)),
    h("span", { class: "grow" }, title, sub),
    h("button", { type: "button", class: "quiet icon-btn", "aria-label": "Chat settings", onclick: () => settings(e, roomId) }, icon(ICONS.more)));
  const earlier = h("button", { type: "button", class: "quiet small-btn earlier" }, "Load earlier messages");
  earlier.onclick = async () => { earlier.disabled = true; await e.loadEarlier(roomId); earlier.disabled = false; };
  const stream = h("div", { class: "msg-stream", role: "log", "aria-live": "polite" });
  const scroller = h("div", { class: "msg-scroll" }, earlier, stream);
  const typing = h("p", { class: "typing", "aria-live": "polite" });
  const notice = h("p", { class: "status", role: "status" });
  const replyBar = h("div", { class: "reply-bar" });
  const field = h("input", { type: "text", class: "composer-field", autocomplete: "off", "aria-label": "Message" });
  const picker = h("input", { type: "file", accept: "image/jpeg,image/png,image/gif,image/webp,image/heic,video/mp4", class: "hidden-file", tabindex: "-1", "aria-hidden": "true" });
  const attach = h("button", { type: "button", class: "quiet icon-btn", "aria-label": "Add a photo or video", onclick: () => picker.click() }, icon(ICONS.plus));
  const sendBtn = h("button", { type: "submit", class: "icon-btn", "aria-label": "Send" }, icon(ICONS.send));
  const form = h("form", { class: "composer" }, attach, field, sendBtn, picker);
  pane.replaceChildren(head, notice, scroller, typing, replyBar, form);

  const share = shareRead();
  const markRead = () => { if (document.visibilityState === "visible") void e.markRead(roomId, share); };

  field.addEventListener("input", () => {
    if (!share) return;
    const now = Date.now();
    if (field.value && now - typingSent > 3000) { typingSent = now; void e.setTyping(roomId, true); }
    if (!field.value && typingSent) { typingSent = 0; void e.setTyping(roomId, false); }
  });
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const text = field.value.trim();
    if (!text) return;
    const reply = replyingTo?.id ?? null;
    field.value = ""; replyingTo = null; drawReply();
    if (typingSent) { typingSent = 0; void e.setTyping(roomId, false); }
    try { notice.textContent = ""; await e.send(roomId, text, reply); } catch (err) { notice.textContent = errorText(err); field.value = text; }
  });
  picker.addEventListener("change", async () => {
    const file = picker.files?.[0];
    picker.value = "";
    if (!file) return;
    // Only a file the person picked, shown first, and sent when they say so (review M12).
    const isVideo = file.type === "video/mp4";
    try {
      notice.textContent = isVideo ? "Preparing the video…" : "Preparing the photo…";
      const video = isVideo ? await prepareVideo(file) : null;
      const photo = video ? null : await preparePhoto(file);
      const prepared = (video ?? photo)!;
      notice.textContent = "";
      const preview = h("img", { class: "send-preview", src: blobUrl(prepared.thumb.data, "image/jpeg"), alt: isVideo ? "Video to send" : "Photo to send" });
      const go = h("button", { type: "button" }, "Send");
      const d = dialog(isVideo ? "Send this video?" : "Send this photo?", preview,
        h("p", { class: "sub" }, isVideo ? "It's encrypted in this browser before it's uploaded." : "Sent as a smaller copy without location or camera details, encrypted in this browser before it's uploaded."),
        h("div", { class: "row end" }, h("button", { type: "button", class: "quiet", onclick: () => d.close() }, "Cancel"), go));
      go.onclick = async () => {
        go.disabled = true; go.textContent = "Sending…";
        const reply = replyingTo?.id ?? null;
        try {
          if (video) await e.sendVideo(roomId, video, reply); else if (photo) await e.sendPhoto(roomId, photo, reply);
          replyingTo = null; drawReply(); d.close();
        } catch (err) { go.disabled = false; go.textContent = "Try again"; d.querySelector(".sub")!.textContent = errorText(err); }
      };
    } catch (err) { notice.textContent = errorText(err); }
  });

  const drawReply = () => {
    replyBar.replaceChildren(...(replyingTo ? [h("span", { class: "grow" }, `Replying to ${replyingTo.isOwn ? "yourself" : displayName(replyingTo.sender)}: ${replyingTo.body}`),
      h("button", { type: "button", class: "quiet small-btn", onclick: () => { replyingTo = null; drawReply(); } }, "Cancel")] : []));
    if (replyingTo) field.focus();
  };

  const media = (m: ChatMessage) => {
    const box = h("button", { type: "button", class: "msg-media", "aria-label": m.kind.type === "video" ? "Play video" : "Open photo" });
    const url = thumbs.get(m.id);
    if (url && url !== FAILED) box.append(h("img", { src: url, alt: m.kind.type === "video" ? "Video" : "Photo" }));
    else if (url === FAILED) box.append(h("span", { class: "media-none" }, m.kind.type === "video" ? "Video" : "Photo · tap to open"));
    else if (url === undefined && m.state === "sent") {
      thumbs.set(m.id, "");
      // Tried once per visit: a thumbnail that's missing, too big or tampered with isn't fetched again (review M1).
      void e.media(roomId, m.id, "thumbnail").then(({ bytes, type }) => { thumbs.set(m.id, blobUrl(bytes, type)); draw(); }).catch(() => { thumbs.set(m.id, FAILED); draw(); });
    }
    if (m.kind.type === "video") box.append(h("span", { class: "play" }, icon(ICONS.play, 22)));
    box.onclick = () => openMedia(e, roomId, m);
    return box;
  };

  const bubble = (m: ChatMessage, group: boolean, lastOwn: boolean) => {
    const isSel = selected === m.id;
    const wrap = h("div", { class: "msg" + (m.isOwn ? " own" : "") + (isSel ? " sel" : "") });
    if (group && !m.isOwn) wrap.append(h("span", { class: "msg-who" }, displayName(m.sender)));
    const content: (Node | string)[] = [];
    if (m.replyTo) content.push(h("span", { class: "msg-quote" }, `${m.replyTo.sender ? (m.replyTo.sender === e.me ? "You" : displayName(m.replyTo.sender)) + ": " : ""}${m.replyTo.text}`));
    if (m.kind.type === "photo" || m.kind.type === "video") content.push(media(m));
    else content.push(h("span", { class: "msg-text" + (m.kind.type === "deleted" || !m.decrypted ? " faded" : "") }, m.body));
    const b = h("button", { type: "button", class: "bubble", "aria-expanded": isSel ? "true" : "false", onclick: () => { selected = isSel ? null : m.id; draw(); } }, ...content);
    if (m.kind.type === "photo" || m.kind.type === "video") b.classList.add("media");
    wrap.append(b);
    if (!m.decrypted) wrap.append(h("span", { class: "msg-meta" }, LockedMessage.note(m.isOwn)));
    if (m.reactions.length) wrap.append(h("div", { class: "reactions" }, ...m.reactions.map((r) =>
      h("button", { type: "button", class: "reaction" + (r.mine ? " mine" : ""), "aria-label": `${r.key} ${r.count}${r.mine ? ", including you" : ""}`, onclick: () => void act(() => e.toggleReaction(roomId, r.key, m.id)) }, `${r.key} ${r.count}`))));
    if (m.state === "failed") wrap.append(h("div", { class: "row" }, h("span", { class: "msg-meta danger-text" }, "Not sent"),
      h("button", { type: "button", class: "quiet small-btn", onclick: () => void act(() => e.retry(roomId, m.id)) }, "Retry"),
      h("button", { type: "button", class: "quiet small-btn", onclick: () => void act(() => e.delete(roomId, m.id)) }, "Remove")));
    else if (m.state === "sending") wrap.append(h("span", { class: "msg-meta" }, "Sending…"));
    else if (lastOwn) wrap.append(h("span", { class: "msg-meta" }, m.seen ? "Read" : "Delivered"));
    if (isSel && m.kind.type !== "deleted") {
      const acts = h("div", { class: "msg-actions" });
      if (m.decrypted && m.state === "sent") for (const q of QUICK_REACTIONS) acts.append(h("button", { type: "button", class: "quiet small-btn", "aria-label": `React ${q}`, onclick: () => void act(() => e.toggleReaction(roomId, q, m.id)) }, q));
      if (m.canReply) acts.append(h("button", { type: "button", class: "quiet small-btn", onclick: () => { replyingTo = m; selected = null; drawReply(); draw(); } }, "Reply"));
      if (m.kind.type === "text" && m.decrypted) acts.append(h("button", { type: "button", class: "quiet small-btn", onclick: () => { void navigator.clipboard?.writeText(m.body); selected = null; draw(); } }, "Copy"));
      if (m.isOwn && m.state === "sent") acts.append(h("button", { type: "button", class: "quiet small-btn danger-text", onclick: async () => {
        if (await confirmDialog("Delete this message?", "It's removed for everyone in this chat.", "Delete")) await act(() => e.delete(roomId, m.id));
      } }, "Delete"));
      wrap.append(acts);
    }
    return wrap;
  };

  const act = async (work: () => Promise<void>) => {
    try { notice.textContent = ""; await work(); } catch (err) { notice.textContent = errorText(err); }
  };

  const draw = () => {
    const info = e.chatInfo(roomId);
    if (!info) { pane.replaceChildren(h("p", { class: "status" }, "This chat isn't here any more.")); return; }
    title.textContent = info.title;
    const dis = e.disappearing(roomId);
    sub.replaceChildren(icon(ICONS.lock, 12), info.isGroup ? `End-to-end encrypted · ${info.people} people` : "End-to-end encrypted",
      dis.setting !== "off" ? ` · Disappearing: ${disappearingLabel[dis.setting]}` : "");
    const all = e.messages(roomId);
    const now = Date.now();
    // Your own messages a disappearing setting says are due leave the server, once each.
    for (const m of dueMessages(all, dis, now)) if (!removing.has(m.id)) { removing.add(m.id); void e.delete(roomId, m.id).catch(() => {}); }
    const shown = visibleMessages(all, dis, now, viewed);
    const nearBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
    const lastOwnId = [...shown].reverse().find((m) => m.isOwn && m.state === "sent")?.id;
    const extra = info.extraPeople.length ? h("p", { class: "fineprint" }, `Also in this chat: ${info.extraPeople.map(displayName).join(", ")}. Anything you send reaches them too.`) : null;
    stream.replaceChildren(...(extra ? [extra] : []), ...(shown.length ? shown.map((m) => bubble(m, info.isGroup, m.id === lastOwnId)) : [h("p", { class: "status" }, "No messages yet. Say hello.")]));
    newest = Math.max(newest, ...all.filter((m) => !m.isOwn).map((m) => m.time), 0);
    if (all.length !== lastCount) { if (all.length > lastCount) markRead(); lastCount = all.length; if (nearBottom) scroller.scrollTop = scroller.scrollHeight; }
    const who = e.typing(roomId);
    typing.textContent = who.length ? `${who.join(", ")} ${who.length === 1 ? "is" : "are"} typing…` : "";
  };

  draw();
  scroller.scrollTop = scroller.scrollHeight;
  if (e.messages(roomId).length < 20) void e.loadEarlier(roomId);
  markRead();
  return {
    draw,
    leave: () => {
      if (typingSent) void e.setTyping(roomId, false);
      if (newest) store(viewedKey(roomId), String(newest));
      // Thumbnails belong to the chat that showed them.
      for (const u of thumbs.values()) if (u && u !== FAILED) revoke(u);
      thumbs.clear();
    },
  };
}

async function openMedia(e: Engine, roomId: string, m: ChatMessage): Promise<void> {
  const isVideo = m.kind.type === "video";
  const holder = h("div", { class: "media-view" }, status("Opening…"));
  const d = dialog(isVideo ? "Video" : "Photo", holder);
  d.classList.add("wide");
  d.append(h("div", { class: "row end" }, h("button", { type: "button", onclick: () => d.close() }, "Close")));
  try {
    const { bytes, type } = await e.media(roomId, m.id, "full");
    const url = blobUrl(bytes, type);
    if (!d.open) { revoke(url); return; }
    d.addEventListener("close", () => revoke(url));
    holder.replaceChildren(isVideo ? h("video", { src: url, controls: true, autoplay: true, playsinline: true }) : h("img", { src: url, alt: "Photo" }));
  } catch (err) { holder.replaceChildren(status(errorText(err))); }
}

// ---- dialogs ----

function newChat(e: Engine): void {
  const name = h("input", { type: "text", autocomplete: "off", autocapitalize: "none", spellcheck: "false", placeholder: "@username" });
  const msg = status("");
  const go = h("button", { type: "submit" }, "Start chat");
  const form = h("form", { class: "stack" }, h("label", {}, "Their Totality username", name), msg,
    h("div", { class: "row end" }, h("button", { type: "button", class: "quiet", onclick: () => d.close() }, "Cancel"), go));
  const d = dialog("New chat", form, h("button", { type: "button", class: "quiet link-btn", onclick: () => { d.close(); newGroup(e); } }, "Start a group instead"));
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault(); go.disabled = true; msg.textContent = "Starting…";
    try { const id = await e.startChat(name.value); d.close(); location.hash = `#/messages/${encodeURIComponent(id)}`; }
    catch (err) { msg.textContent = errorText(err); go.disabled = false; }
  });
  name.focus();
}

function newGroup(e: Engine): void {
  const people = h("input", { type: "text", autocomplete: "off", autocapitalize: "none", spellcheck: "false", placeholder: "jonah.hikes, sam_r" });
  const name = h("input", { type: "text", maxlength: "60", autocomplete: "off" });
  const photo = h("input", { type: "file", accept: "image/*" });
  const msg = status("");
  const go = h("button", { type: "submit" }, "Start group");
  const form = h("form", { class: "stack" }, h("label", {}, "Usernames, separated by commas", people), h("label", {}, "Group name (optional)", name),
    h("label", {}, "Group photo (optional)", photo), h("p", { class: "sub" }, GroupLabels.notEncrypted), msg,
    h("div", { class: "row end" }, h("button", { type: "button", class: "quiet", onclick: () => d.close() }, "Cancel"), go));
  const d = dialog("New group", form);
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault(); go.disabled = true; msg.textContent = "Starting…";
    try {
      const own = displayName(e.me);
      const usernames = parseGroupMembers(people.value, own);
      const file = photo.files?.[0];
      const pic = file ? await prepareGroupPhoto(file) : null;
      const id = await e.startGroup(usernames, cleanGroupName(name.value), pic);
      d.close(); location.hash = `#/messages/${encodeURIComponent(id)}`;
    } catch (err) { msg.textContent = errorText(err); go.disabled = false; }
  });
  people.focus();
}

function moreMenu(e: Engine): void {
  const toggle = h("input", { type: "checkbox", class: "switch", ...(shareRead() ? { checked: true } : {}) });
  toggle.addEventListener("change", () => store(SHARE_READ_KEY, toggle.checked ? "true" : "false"));
  const d = dialog("Messages settings",
    h("label", { class: "choice" }, toggle, h("span", { class: "choice-text" }, h("b", {}, "Send read receipts and typing"), h("span", { class: "sub" }, "When this is off, people don't see when you've read their messages or are typing. Applies to this browser."))),
    h("button", { type: "button", class: "quiet", onclick: () => { d.close(); newGroup(e); } }, "New group"),
    h("button", { type: "button", class: "quiet", onclick: () => { d.close(); blockedPeople(e); } }, "Blocked people"),
    h("div", { class: "row end" }, h("button", { type: "button", onclick: () => d.close() }, "Done")));
}

function blockedPeople(e: Engine): void {
  const list = h("div", { class: "stack" });
  const draw = () => {
    const people = e.blocked();
    list.replaceChildren(...(people.length ? people.map((p) => h("div", { class: "row" }, h("span", { class: "grow" }, displayName(p)),
      h("button", { type: "button", class: "quiet small-btn", onclick: async () => { try { await e.unblock(p); } catch { /* shown by the list staying */ } draw(); } }, "Unblock"))) : [h("p", { class: "sub" }, "You haven't blocked anyone.")]));
  };
  draw();
  const d = dialog("Blocked people", list, h("div", { class: "row end" }, h("button", { type: "button", onclick: () => d.close() }, "Done")));
}

function settings(e: Engine, roomId: string): void {
  const info = e.chatInfo(roomId);
  if (!info) return;
  const dis = e.disappearing(roomId);
  const msg = status("");
  const explain = h("p", { class: "sub" }, disappearingExplanation(dis.setting));
  const choices = DISAPPEARING.map((value) => {
    const r = h("input", { type: "radio", name: "disappearing", value, class: "switch", ...(dis.setting === value ? { checked: true } : {}) });
    r.addEventListener("change", async () => {
      explain.textContent = disappearingExplanation(value);
      try { msg.textContent = ""; await e.setDisappearing(roomId, value); } catch (err) { msg.textContent = errorText(err); }
    });
    return h("label", { class: "choice" }, r, h("span", { class: "choice-text" }, h("b", {}, disappearingLabel[value])));
  });
  const parts: Node[] = [h("h3", {}, "Disappearing messages"), ...choices, explain];
  if (dis.changedBy) parts.push(h("p", { class: "sub" }, `Chosen by ${displayName(dis.changedBy)}.`));
  if (info.isGroup) {
    const name = h("input", { type: "text", maxlength: "60", value: info.title });
    const photo = h("input", { type: "file", accept: "image/*" });
    parts.push(h("h3", {}, "Group"), h("label", {}, "Name", name),
      h("button", { type: "button", class: "quiet", onclick: async () => { try { await e.rename(roomId, cleanGroupName(name.value)); msg.textContent = "Saved."; } catch (err) { msg.textContent = errorText(err); } } }, "Save name"),
      h("label", {}, "Photo", photo),
      h("button", { type: "button", class: "quiet", onclick: async () => { try { await e.setGroupPhoto(roomId, null); msg.textContent = "Photo removed."; } catch (err) { msg.textContent = errorText(err); } } }, "Remove photo"),
      h("p", { class: "sub" }, `${GroupLabels.notEncrypted} ${GroupLabels.photoOnServer}`));
    photo.addEventListener("change", async () => {
      const f = photo.files?.[0];
      if (!f) return;
      try { msg.textContent = "Uploading…"; await e.setGroupPhoto(roomId, await prepareGroupPhoto(f)); msg.textContent = "Photo changed."; } catch (err) { msg.textContent = errorText(err); }
    });
  }
  const leave = h("button", { type: "button", class: "quiet danger-text" }, info.isGroup ? "Leave group" : "Leave chat");
  leave.onclick = async () => {
    if (!(await confirmDialog(info.isGroup ? "Leave this group?" : "Leave this chat?", "You won't get new messages from it. Someone would have to invite you back.", "Leave"))) return;
    try { await e.leave(roomId); d.close(); location.hash = "#/messages"; } catch (err) { msg.textContent = errorText(err); }
  };
  parts.push(h("h3", {}, "Privacy"), leave);
  if (info.otherPerson) {
    const other = info.otherPerson;
    parts.push(h("button", { type: "button", class: "quiet danger-text", onclick: async () => {
      if (!(await confirmDialog(`Block ${displayName(other)}?`, "They won't be able to message you, and you'll leave this chat. You can unblock them later.", "Block"))) return;
      try { await e.blockPerson(other, roomId); d.close(); location.hash = "#/messages"; } catch (err) { msg.textContent = errorText(err); }
    } }, `Block ${displayName(other)}`));
  }
  const d = dialog(info.title, ...parts, msg, h("div", { class: "row end" }, h("button", { type: "button", onclick: () => d.close() }, "Done")));
}
