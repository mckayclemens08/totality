// The rules Messages follows on the iPhone (Sources/TotalityMessages/Messages.swift), ported as they are,
// so a chat behaves the same in both places. No SDK and no DOM here: these are unit tested on their own.

export const SERVER = "usetotality.com";
export const HOMESERVER = "https://matrix.usetotality.com";
export const DEVICE_NAME = "Totality web"; // owner, 2026-11-18

export const QUICK_REACTIONS = ["❤️", "😂", "👍", "😢"];

/** A typed username as the server knows it, or null. Same rule handles are claimed under. */
export function normalizedUsername(typed: string): string | null {
  const name = typed.trim().replace(/^@+/, "").toLowerCase();
  return /^[a-z0-9_]{3,24}$/.test(name) ? name : null;
}

/** `@name:usetotality.com` shown as `name`. Anything else is shown as it is. */
export function displayName(matrixId: string): string {
  const colon = matrixId.indexOf(":");
  return matrixId.startsWith("@") && colon > 0 ? matrixId.slice(1, colon) : matrixId;
}

export const userId = (username: string): string => `@${username}:${SERVER}`;

export const MessagesErrors = {
  notAUsername: "That isn't a Totality username.",
  ownUsername: "That's your own username.",
  noSuchPerson: "There's no one with that username.",
  notEncrypted: "That chat isn't end-to-end encrypted, so nothing was sent.",
  offline: "You're offline. Try again when you're connected.",
  refused: "The Matrix server refused that.",
  unreachable: "Messages couldn't reach the server. Check your connection and try again.",
  generic: "Something went wrong. Try again.",
};

/** Shared task-list rooms belong to Tasks, never to chats or requests (SharedRoomMarker). */
export const SHARED_ROOM = { name: "Totality shared list", topic: "app.totality.tasks.v1" };
export const isSharedRoom = (name?: string | null, topic?: string | null): boolean => name === SHARED_ROOM.name || topic === SHARED_ROOM.topic;

/** What a message that won't open says. */
export const LockedMessage = {
  placeholder: (isOwn: boolean) => (isOwn ? "Can't be opened on this device" : "Waiting for this message's key"),
  note: (isOwn: boolean) =>
    isOwn
      ? "Sent from an earlier install of Totality. Its key stayed on that install, so this device can't open it."
      : "It will open once the sender's device shares the key, usually when they're next online.",
};

export const GroupLabels = {
  notEncrypted: "Group name and photo aren't end-to-end encrypted. Messages are.",
  photoOnServer: "The photo is kept on Totality's server without end-to-end encryption, so the server can see it.",
};

export const GROUP_NAME_LONGEST = 60;
export function cleanGroupName(typed: string): string | null {
  const name = typed.trim().split(/\r?\n/).join(" ");
  return name ? [...name].slice(0, GROUP_NAME_LONGEST).join("") : null;
}

/** Up to 20 people, you included. */
export const GROUP_LIMIT = 20;
export function parseGroupMembers(typed: string, own: string): string[] {
  const parts = typed.split(/[\s,]+/).filter(Boolean);
  const names: string[] = [];
  for (const part of parts) {
    const name = normalizedUsername(part);
    if (!name) throw new Error(`“${part}” isn't a Totality username.`);
    if (name !== own && !names.includes(name)) names.push(name);
  }
  if (names.length < 2) throw new Error("A group needs at least two other people. For one person, start a chat.");
  if (names.length >= GROUP_LIMIT) throw new Error(`A group can have up to ${GROUP_LIMIT} people, you included.`);
  return names;
}

/** A one-to-one chat is only reused while it holds exactly the two of you, joined or invited. */
export const isJustTheTwoOfYou = (members: string[], own: string, other: string): boolean =>
  members.length === 2 && new Set(members).size === 2 && members.includes(own) && members.includes(other);
export const extraPeople = (members: string[], own: string, other: string | null): string[] => members.filter((m) => m !== own && m !== other);

// ---- disappearing messages (owner, 2026-11-05) ----

export type Disappearing = "off" | "afterViewing" | "day" | "week";
export const DISAPPEARING: Disappearing[] = ["off", "afterViewing", "day", "week"];
export const AFTER_VIEWING_KEY = "app.totality.after_viewing";
export const RETENTION_EVENT = "m.room.retention";

export const disappearingLabel: Record<Disappearing, string> = { off: "Off", afterViewing: "After viewing", day: "After 24 hours", week: "After 7 days" };
export function disappearingExplanation(d: Disappearing): string {
  switch (d) {
    case "off": return "Messages stay until someone deletes them.";
    case "afterViewing": return "Messages sent from now on go once they've been read. In a group, the first person to read one removes it for everyone. Someone who doesn't share read receipts never marks one read, so it stays until they do. On your phone, messages you've read go when you leave the chat.";
    default: return `Messages sent from now on are hidden on everyone's phone ${d === "day" ? "after 24 hours" : "after 7 days"}. Each person's messages leave the server the next time their own app opens this chat. Earlier messages stay.`;
  }
}
export const lifetimeMs = (d: Disappearing): number | null => (d === "day" ? 86_400_000 : d === "week" ? 7 * 86_400_000 : null);

/** The room's retention state content for a setting, exactly as the iPhone writes it. */
export function disappearingContent(d: Disappearing): Record<string, unknown> {
  if (d === "afterViewing") return { [AFTER_VIEWING_KEY]: true };
  const ms = lifetimeMs(d);
  return ms ? { max_lifetime: ms } : {};
}
export function disappearingFrom(content: unknown): Disappearing {
  if (!content || typeof content !== "object") return "off";
  const o = content as Record<string, unknown>;
  if (o[AFTER_VIEWING_KEY] === true) return "afterViewing";
  const ms = typeof o.max_lifetime === "number" ? o.max_lifetime : NaN;
  return ms > 0 ? (ms <= 86_400_000 ? "day" : "week") : "off";
}

export interface DisappearingState { setting: Disappearing; since: number | null; changedBy: string | null }
export const DISAPPEARING_OFF: DisappearingState = { setting: "off", since: null, changedBy: null };

// ---- messages ----

export type Kind = { type: "text" } | { type: "photo"; width?: number; height?: number } | { type: "video"; seconds?: number } | { type: "deleted" };
export type SendState = "sending" | "failed" | "sent";
export interface Reaction { key: string; count: number; mine: boolean }
export interface ChatMessage {
  id: string; sender: string; body: string; isOwn: boolean; time: number; state: SendState; decrypted: boolean;
  seen: boolean; kind: Kind; reactions: Reaction[]; replyTo: { sender: string; text: string } | null; canReply: boolean;
}

const covers = (s: DisappearingState, m: ChatMessage): boolean => s.setting !== "off" && s.since !== null && m.time >= s.since;

/** Hides messages a disappearing setting has expired here, even before their sender removes them. */
export function visibleMessages(messages: ChatMessage[], s: DisappearingState, now: number, viewedUpTo: number | null): ChatMessage[] {
  return messages.filter((m) => {
    if (m.kind.type === "deleted" || !covers(s, m)) return true;
    const life = lifetimeMs(s.setting);
    if (life) return m.time + life > now;
    if (s.setting === "afterViewing" && !m.isOwn && viewedUpTo !== null) return m.time > viewedUpTo;
    return true;
  });
}

/** Your own messages due to leave the server: past their time, or seen by someone when it's after viewing. */
export function dueMessages(messages: ChatMessage[], s: DisappearingState, now: number): ChatMessage[] {
  return messages.filter((m) => {
    if (!m.isOwn || m.state !== "sent" || m.kind.type === "deleted" || !covers(s, m)) return false;
    const life = lifetimeMs(s.setting);
    if (life) return m.time + life <= now;
    return s.setting === "afterViewing" && m.seen;
  });
}

/** Marks everything up to the newest message someone else has read. */
export function markingSeen(messages: ChatMessage[], readUpTo: number | null): ChatMessage[] {
  return messages.map((m, i) => (readUpTo !== null && i <= readUpTo && m.isOwn ? { ...m, seen: true } : m));
}

/** A list preview for a message's content. Null for anything Messages doesn't show. */
export function previewText(msgtype: string | undefined, body: unknown): string | null {
  switch (msgtype) {
    case "m.image": return "Photo";
    case "m.video": return "Video";
    case "m.audio": return "Audio";
    case "m.file": return "File";
    case "m.location": return "Location";
    case "m.text": case "m.notice": case "m.emote": return typeof body === "string" ? body : null;
    default: return null;
  }
}

/** Only this server's own media: federation is off, and a link elsewhere is never fetched. */
export const isOwnMedia = (mxc: unknown): mxc is string => typeof mxc === "string" && /^mxc:\/\/usetotality\.com\/[A-Za-z0-9_-]+$/.test(mxc);

/** Read receipts and typing are on by default, with one switch to stop sending yours. */
export const SHARE_READ_KEY = "totality.messages.shareReadAndTyping";
