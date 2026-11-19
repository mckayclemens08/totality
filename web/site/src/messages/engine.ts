// Messages' Matrix engine: matrix-js-sdk with the Rust crypto WASM. Loaded only when Messages opens (its own
// chunk). Spec: docs/website-messages-spec.md. It mirrors App/Totality/MatrixMessagesService.swift.
//  - Sign-in: a one-minute pass from matrix-login, then a new device named "Totality web".
//  - The crypto store is IndexedDB, encrypted by the SDK under a key derived from the non-extractable root key.
//  - Chats, names and messages stay in memory. Nothing is logged.
//  - The browser verifies itself from the root key and NEVER resets cross-signing, secret storage or backup.
import { createClient, ClientEvent, RoomEvent, RoomMemberEvent, MatrixEventEvent, RoomStateEvent, EventStatus, ReceiptType, Preset, Visibility, NotificationCountType, PendingEventOrdering, SyncState, KnownMembership, EventType, type MatrixClient, type MatrixEvent, type Room } from "matrix-js-sdk";
import { deriveRecoveryKeyFromPassphrase } from "matrix-js-sdk/lib/crypto-api/key-passphrase.js";
import { logger as sdkLogger } from "matrix-js-sdk/lib/logger.js";
import { initAsync } from "@matrix-org/matrix-sdk-crypto-wasm";
// @ts-ignore -- esbuild's file loader turns this import into the hashed file's URL
import wasmUrl from "../../node_modules/@matrix-org/matrix-sdk-crypto-wasm/pkg/matrix_sdk_crypto_wasm_bg.wasm";
import * as net from "../net";
import * as vault from "../keystore";
import { cryptoPrefix, deleteCryptoStore, forgetMatrixSession, generationNow, keepMatrixSession, loadMatrixSession, onEngineStop, type MatrixSession } from "./session";
import { encryptAttachment, decryptAttachment } from "./attach";
import {
  DEVICE_NAME, MessagesErrors, RETENTION_EVENT, SHARED_ROOM, disappearingContent, disappearingFrom, displayName, isJustTheTwoOfYou, extraPeople,
  isOwnMedia, isSharedRoom, LockedMessage, markingSeen, normalizedUsername, previewText, userId as toUserId,
  type ChatMessage, type Disappearing, type DisappearingState, type Kind, type Reaction,
} from "./rules";

// ---- quiet: the SDK logs room and event details by default, and this page logs nothing ----
const silent = { trace() {}, debug() {}, info() {}, warn() {}, error() {}, getChild() { return silent; } };
{
  const root = sdkLogger as unknown as { methodFactory: unknown; rebuild?: () => void };
  root.methodFactory = () => () => {};
  root.rebuild?.();
}

export type KeysState =
  | { kind: "checking" }
  | { kind: "verifying" }
  | { kind: "restoring"; done: number; total: number }
  | { kind: "ready"; restoredJustNow: boolean }
  | { kind: "noBackup" }
  | { kind: "doesntOpen" }
  | { kind: "failed"; message: string };

export interface ChatSummary {
  id: string; title: string; isRequest: boolean; from: string | null; lastMessage: string | null; lastActivity: number | null;
  unread: number; isGroup: boolean; photo: string | null; otherPerson: string | null; lastSender: string | null;
}

export class MessagesError extends Error {}
const fail = (m: string): never => { throw new MessagesError(m); };
function translate(e: unknown): Error {
  if (e instanceof MessagesError) return e;
  if (e instanceof net.NetError) return new MessagesError(e.kind === "offline" ? MessagesErrors.offline : MessagesErrors.unreachable);
  const code = (e as { errcode?: string } | null)?.errcode;
  if (code === "M_FORBIDDEN") return new MessagesError(MessagesErrors.refused);
  if (code) return new MessagesError(MessagesErrors.unreachable);
  if (e instanceof TypeError) return new MessagesError(MessagesErrors.offline);
  return new MessagesError(MessagesErrors.generic);
}
async function guard<T>(work: () => Promise<T>): Promise<T> { try { return await work(); } catch (e) { throw translate(e); } }

// Received sizes: photos up to 10 MB, videos up to 100 MB (the iPhone sends up to that), thumbnails 2 MB.
const PHOTO_MAX = 10 * 1024 * 1024, VIDEO_MAX = 100 * 1024 * 1024, THUMB_MAX = 2 * 1024 * 1024;

export class Engine {
  private listeners = new Set<() => void>();
  private pending: ReturnType<typeof setTimeout> | null = null;
  private replyCache = new Map<string, { sender: string; text: string } | "missing">();
  keys: KeysState = { kind: "checking" };
  online = false;

  private constructor(readonly client: MatrixClient, readonly session: MatrixSession) {}
  get me(): string { return this.session.userId; }

  // ---------- connecting ----------

  static async connect(supabaseToken: () => Promise<string>, owner: string): Promise<Engine> {
    // Sign-out or lock while this runs bumps the generation; then nothing made here is kept (review M3).
    const gen = generationNow();
    const live = (): void => { if (generationNow() !== gen) throw new MessagesError(MessagesErrors.generic); };
    await initAsync(new URL(wasmUrl, location.href));
    live();
    let session = await loadMatrixSession();
    live();
    if (session && session.owner !== owner) {
      // Left by another account in this browser: never used, logged out and wiped.
      await net.matrixLogout(session.accessToken);
      await forgetMatrixSession();
      session = null;
    }
    for (let attempt = 0; ; attempt++) {
      if (!session) {
        const pass = await net.matrixPass(await supabaseToken());
        live();
        const fresh: MatrixSession = { ...(await net.matrixLogin(pass, DEVICE_NAME)), owner };
        if (generationNow() !== gen) { await net.matrixLogout(fresh.accessToken); live(); }
        await deleteCryptoStore(fresh.userId); // a new device starts with an empty store
        await keepMatrixSession(fresh);
        if (generationNow() !== gen) { await net.matrixLogout(fresh.accessToken); await forgetMatrixSession(); live(); }
        session = fresh;
      }
      const client = createClient({
        baseUrl: "https://matrix.usetotality.com", accessToken: session.accessToken, userId: session.userId, deviceId: session.deviceId,
        logger: silent, timelineSupport: true,
        cryptoCallbacks: { getSecretStorageKey: async ({ keys }) => Engine.unlockFor(keys) },
      });
      try {
        await client.whoami();
      } catch (e) {
        if ((e as { errcode?: string }).errcode === "M_UNKNOWN_TOKEN" && attempt === 0) { await forgetMatrixSession(); session = null; continue; }
        throw translate(e);
      }
      live();
      // So Remove on the iPhone can delete this browser's Matrix device too.
      const device = session.deviceId;
      void supabaseToken().then((t) => net.browserMatrixDevice(t, device)).catch(() => {});
      const storageKey = await vault.deriveSeed("totality/web-matrix-store/v1");
      try {
        await client.initRustCrypto({ cryptoDatabasePrefix: cryptoPrefix(session.userId), storageKey });
      } finally { storageKey.fill(0); }
      const engine = new Engine(client, session);
      try {
        live();
        engine.guardSecretStorage();
        engine.listen();
        onEngineStop(() => engine.stop());
        await client.startClient({ lazyLoadMembers: true, initialSyncLimit: 30, pendingEventOrdering: PendingEventOrdering.Detached });
        await engine.firstSync();
        live();
      } catch (e) { await engine.stop(); throw e; }
      return engine;
    }
  }

  /**
   * The account's keys live in secret storage and account data, written by the iPhone. This browser only ever
   * reads them, so every write to those names is refused here, whatever the SDK decides to do (review M4).
   */
  private guardSecretStorage(): void {
    const protectedType = (t: string): boolean => /^m\.(cross_signing\.|secret_storage\.|megolm_backup\.v1$)/.test(t);
    const ss = this.client.secretStorage as unknown as { store: (name: string, ...rest: unknown[]) => Promise<void>; addKey: (...a: unknown[]) => Promise<unknown>; setDefaultKeyId: (...a: unknown[]) => Promise<void> };
    ss.store = async () => { throw new Error("Totality web never writes secret storage"); };
    ss.addKey = async () => { throw new Error("Totality web never writes secret storage"); };
    ss.setDefaultKeyId = async () => { throw new Error("Totality web never writes secret storage"); };
    const c = this.client as unknown as { setAccountData: (type: string, ...rest: unknown[]) => Promise<unknown> };
    const original = c.setAccountData.bind(this.client);
    c.setAccountData = async (type: string, ...rest: unknown[]) => {
      if (protectedType(type)) throw new Error("Totality web never writes the account's keys");
      return original(type, ...rest);
    };
  }

  private firstSync(): Promise<void> {
    return new Promise((resolve) => {
      const done = (state: SyncState) => {
        if (state === SyncState.Prepared || state === SyncState.Syncing) { this.client.off(ClientEvent.Sync, done); resolve(); }
      };
      this.client.on(ClientEvent.Sync, done);
      setTimeout(() => { this.client.off(ClientEvent.Sync, done); resolve(); }, 20_000);
    });
  }

  async stop(): Promise<void> {
    this.listeners.clear();
    this.client.stopClient();
    this.client.removeAllListeners();
    onEngineStop(null);
  }

  /** Called on any change; the view re-reads what it shows. Batched to one call per frame or so. */
  subscribe(fn: () => void): () => void { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  private changed = (): void => {
    if (this.pending) return;
    this.pending = setTimeout(() => { this.pending = null; for (const fn of this.listeners) fn(); }, 60);
  };
  private listen(): void {
    const c = this.client;
    c.on(ClientEvent.Sync, (state) => {
      this.online = state === SyncState.Prepared || state === SyncState.Syncing || state === SyncState.Catchup;
      if (state === SyncState.Error) void this.checkSignedIn();
      this.changed();
    });
    for (const ev of [ClientEvent.Room, ClientEvent.DeleteRoom, ClientEvent.AccountData]) c.on(ev, this.changed);
    for (const ev of [RoomEvent.Timeline, RoomEvent.Name, RoomEvent.MyMembership, RoomEvent.Receipt, RoomEvent.LocalEchoUpdated, RoomEvent.Redaction, RoomEvent.TimelineReset, RoomEvent.UnreadNotifications]) c.on(ev as never, this.changed as never);
    c.on(RoomMemberEvent.Typing, this.changed);
    c.on(RoomStateEvent.Events, this.changed);
    c.on(MatrixEventEvent.Decrypted, this.changed);
  }

  /** Removed on the iPhone, or logged out elsewhere: forget this device here too. */
  private async checkSignedIn(): Promise<void> {
    try { await this.client.whoami(); } catch (e) {
      if ((e as { errcode?: string }).errcode === "M_UNKNOWN_TOKEN") { await this.stop(); await forgetMatrixSession(); this.keys = { kind: "failed", message: "This browser was removed from your devices. Reload to sign Messages in again." }; for (const fn of this.listeners) fn(); }
    }
  }

  // ---------- verifying this browser (spec section 4) ----------

  private static unlocked: { id: string; key: Uint8Array<ArrayBuffer> } | null = null;
  private static unlockFor(keys: Record<string, unknown>): [string, Uint8Array<ArrayBuffer>] | null {
    const u = Engine.unlocked;
    return u && u.id in keys ? [u.id, u.key] : null;
  }

  /** Verifies this browser with the account's own keys and restores history. Never resets anything. */
  async settleKeys(onProgress: (s: KeysState) => void): Promise<KeysState> {
    const set = (s: KeysState) => { this.keys = s; onProgress(s); return s; };
    const crypto = this.client.getCrypto();
    if (!crypto) return set({ kind: "failed", message: "Messages couldn't start its encryption in this browser." });
    try {
      const status = await crypto.getDeviceVerificationStatus(this.me, this.session.deviceId);
      if (status?.crossSigningVerified) {
        void crypto.checkKeyBackupAndEnable().catch(() => {});
        return set({ kind: "ready", restoredJustNow: false });
      }
      set({ kind: "verifying" });
      const ss = this.client.secretStorage;
      const keyId = await ss.getDefaultKeyId();
      const tuple = keyId ? await ss.getKey(keyId) : null;
      const needed = ["m.cross_signing.master", "m.cross_signing.self_signing", "m.cross_signing.user_signing"] as const;
      const stored = await Promise.all(needed.map((n) => ss.isStored(n)));
      if (!tuple || stored.some((s) => !s || !(tuple[0] in s))) return set({ kind: "noBackup" });
      const [id, info] = tuple;
      const pp = info.passphrase;
      if (!pp || pp.algorithm !== "m.pbkdf2" || typeof pp.salt !== "string" || !(pp.iterations > 0)) return set({ kind: "doesntOpen" });
      // The same secret the iPhone gives enableRecovery(passphrase:): HKDF of the root key, base64.
      const seed = await vault.deriveSeed("totality/matrix-recovery/v1");
      const secret = btoa(String.fromCharCode(...seed));
      seed.fill(0);
      const key = await deriveRecoveryKeyFromPassphrase(secret, pp.salt, pp.iterations, pp.bits ?? 256);
      if (!(await ss.checkKey(key, info))) { key.fill(0); return set({ kind: "doesntOpen" }); }
      Engine.unlocked = { id, key };
      try {
        // All three must open to real keys here, or the SDK could decide to make new ones (review M4).
        const opened = await Promise.all(needed.map((n) => ss.get(n).catch(() => undefined)));
        if (opened.some((v) => typeof v !== "string" || v.length < 32)) return set({ kind: "noBackup" });
        await crypto.bootstrapCrossSigning({
          // A reset would need this callback to upload new keys. It refuses, so nothing can ever be reset.
          authUploadDeviceSigningKeys: async () => { throw new Error("Totality web never resets cross-signing"); },
        });
        const after = await crypto.getDeviceVerificationStatus(this.me, this.session.deviceId);
        if (!after?.crossSigningVerified) return set({ kind: "failed", message: "This browser couldn't be verified. Try again later." });
        const backup = await ss.isStored("m.megolm_backup.v1");
        if (!backup) return set({ kind: "ready", restoredJustNow: false });
        await crypto.loadSessionBackupPrivateKeyFromSecretStorage();
        await crypto.checkKeyBackupAndEnable();
        set({ kind: "restoring", done: 0, total: 0 });
        await crypto.restoreKeyBackup({
          progressCallback: (p) => { if (p.stage === "load_keys") set({ kind: "restoring", done: p.successes + p.failures, total: p.total }); },
        });
        return set({ kind: "ready", restoredJustNow: true });
      } finally {
        Engine.unlocked = null;
        key.fill(0);
      }
    } catch {
      return set({ kind: "failed", message: "Messages couldn't check its key backup. It'll try again next time." });
    }
  }

  // ---------- the chat list ----------

  private directRooms(): Set<string> {
    const content = (this.client.getAccountData(EventType.Direct)?.getContent() ?? {}) as Record<string, string[]>;
    return new Set(Object.values(content).flat());
  }
  private isDirect(room: Room, direct = this.directRooms()): boolean {
    if (room.getMyMembership() === KnownMembership.Invite) return room.getMember(this.me)?.events.member?.getContent().is_direct === true;
    return direct.has(room.roomId);
  }
  private static topic(room: Room): string | null {
    return (room.currentState.getStateEvents("m.room.topic", "")?.getContent().topic as string | undefined) ?? null;
  }
  private static rawName(room: Room): string | null {
    return (room.currentState.getStateEvents("m.room.name", "")?.getContent().name as string | undefined) ?? null;
  }
  private static inviter(room: Room, me: string): string | null {
    return room.getMember(me)?.events.member?.getSender() ?? null;
  }
  private encrypted = (room: Room): boolean => room.hasEncryptionStateEvent();

  chats(): ChatSummary[] {
    const direct = this.directRooms();
    const out: ChatSummary[] = [];
    for (const room of this.client.getRooms()) {
      if (room.isSpaceRoom() || isSharedRoom(Engine.rawName(room), Engine.topic(room))) continue;
      const membership = room.getMyMembership();
      const isDirect = this.isDirect(room, direct);
      if (membership === KnownMembership.Invite) {
        const from = Engine.inviter(room, this.me);
        const name = from ? displayName(from) : "Someone";
        out.push({ id: room.roomId, title: isDirect ? name : `Group from ${name}`, isRequest: true, from, lastMessage: null, lastActivity: null, unread: 0, isGroup: !isDirect, photo: null, otherPerson: null, lastSender: null });
      } else if (membership === KnownMembership.Join) {
        // Messages only shows end-to-end encrypted chats, so its label stays true.
        if (!this.encrypted(room)) continue;
        const last = this.lastMessage(room);
        const other = isDirect ? this.otherMember(room) : null;
        out.push({
          id: room.roomId, title: room.name || (other ? displayName(other) : "Chat"), isRequest: false, from: null,
          lastMessage: last?.text ?? null, lastActivity: last?.time ?? (room.getLastActiveTimestamp() > 0 ? room.getLastActiveTimestamp() : null),
          unread: room.getUnreadNotificationCount(NotificationCountType.Total), isGroup: !isDirect,
          photo: isDirect ? null : room.getMxcAvatarUrl(), otherPerson: other, lastSender: last && !last.own ? last.sender : null,
        });
      }
    }
    return out.sort((a, b) => (a.lastActivity === b.lastActivity ? a.id.localeCompare(b.id) : a.lastActivity === null ? 1 : b.lastActivity === null ? -1 : b.lastActivity - a.lastActivity));
  }

  private otherMember(room: Room): string | null {
    const ids = room.getMembers().filter((m) => m.membership === KnownMembership.Join || m.membership === KnownMembership.Invite).map((m) => m.userId);
    return ids.find((id) => id !== this.me) ?? (room.getDMInviter?.() || null);
  }
  private activeMembers(room: Room): string[] {
    return room.getMembers().filter((m) => m.membership === KnownMembership.Join || m.membership === KnownMembership.Invite).map((m) => m.userId);
  }

  private lastMessage(room: Room): { text: string; time: number; sender: string; own: boolean } | null {
    const events = room.getLiveTimeline().getEvents();
    for (let i = events.length - 1; i >= 0; i--) {
      const ev = events[i]!;
      const text = this.previewOf(ev);
      if (text === null) continue;
      const own = ev.getSender() === this.me;
      return { text: own ? `You: ${text}` : text, time: ev.getTs(), sender: ev.getSender() ?? "", own };
    }
    return null;
  }

  private previewOf(ev: MatrixEvent): string | null {
    const type = ev.getType();
    if (type !== "m.room.message" && type !== "m.room.encrypted") return null;
    if (ev.isRedacted()) return "Message deleted";
    if (ev.isDecryptionFailure()) return LockedMessage.placeholder(ev.getSender() === this.me);
    if (type !== "m.room.message") return null; // still being opened
    const c = ev.getContent();
    if (c["m.relates_to"]?.rel_type === "m.replace") return null;
    return previewText(c.msgtype, c.body);
  }

  // ---------- requests and people ----------

  async accept(roomId: string): Promise<void> {
    await guard(async () => {
      const room = this.client.getRoom(roomId);
      const wasDirect = room ? this.isDirect(room) : false;
      const inviter = room ? Engine.inviter(room, this.me) : null;
      await this.client.joinRoom(roomId);
      const joined = await this.waitForRoom(roomId, (r) => r.getMyMembership() === KnownMembership.Join);
      if (!joined.hasEncryptionStateEvent()) {
        await this.client.leave(roomId).catch(() => {});
        fail("That chat isn't end-to-end encrypted, so Messages left it.");
      }
      if (wasDirect && inviter) await this.markDirect(inviter, roomId);
    });
  }
  async decline(roomId: string): Promise<void> { await guard(() => this.client.leave(roomId)); }
  async blockRequest(roomId: string): Promise<void> {
    await guard(async () => {
      const room = this.client.getRoom(roomId);
      const inviter = room ? Engine.inviter(room, this.me) : null;
      if (inviter) await this.client.setIgnoredUsers([...new Set([...this.client.getIgnoredUsers(), inviter])]);
      await this.client.leave(roomId);
    });
  }
  async blockPerson(person: string, leaving: string | null): Promise<void> {
    await guard(async () => {
      await this.client.setIgnoredUsers([...new Set([...this.client.getIgnoredUsers(), person])]);
      if (leaving) await this.client.leave(leaving);
    });
  }
  blocked(): string[] { return this.client.getIgnoredUsers(); }
  async unblock(person: string): Promise<void> { await guard(() => this.client.setIgnoredUsers(this.client.getIgnoredUsers().filter((p) => p !== person))); }
  async leave(roomId: string): Promise<void> { await guard(() => this.client.leave(roomId)); }

  private async markDirect(other: string, roomId: string): Promise<void> {
    const content = { ...((this.client.getAccountData(EventType.Direct)?.getContent() ?? {}) as Record<string, string[]>) };
    const list = content[other] ?? [];
    if (list.includes(roomId)) return;
    content[other] = [...list, roomId];
    await this.client.setAccountData(EventType.Direct, content as never);
  }

  private waitForRoom(roomId: string, ok: (r: Room) => boolean = () => true): Promise<Room> {
    return new Promise((resolve, reject) => {
      let tries = 0;
      const tick = () => {
        const r = this.client.getRoom(roomId);
        if (r && ok(r)) { resolve(r); return; }
        if (++tries > 50) { reject(new MessagesError("The new chat didn't arrive from the server. Try again.")); return; }
        setTimeout(tick, 200);
      };
      tick();
    });
  }

  private async exists(person: string): Promise<boolean> {
    try { await this.client.getProfileInfo(person); return true; } catch (e) {
      if ((e as { errcode?: string }).errcode === "M_NOT_FOUND") return false;
      throw e;
    }
  }

  async startChat(typed: string): Promise<string> {
    const name = normalizedUsername(typed);
    if (!name) fail(MessagesErrors.notAUsername);
    const other = toUserId(name!);
    if (other === this.me) fail(MessagesErrors.ownUsername);
    return guard(async () => {
      // Reused only while it's still just the two of you: anyone in a chat can invite a third person.
      const content = (this.client.getAccountData(EventType.Direct)?.getContent() ?? {}) as Record<string, string[]>;
      for (const id of content[other] ?? []) {
        const r = this.client.getRoom(id);
        if (r && r.getMyMembership() === KnownMembership.Join && r.hasEncryptionStateEvent() && isJustTheTwoOfYou(this.activeMembers(r), this.me, other)) return id;
      }
      if (!(await this.exists(other))) fail(MessagesErrors.noSuchPerson);
      const { room_id } = await this.client.createRoom({
        is_direct: true, preset: Preset.TrustedPrivateChat, visibility: Visibility.Private, invite: [other],
        initial_state: [{ type: "m.room.encryption", state_key: "", content: { algorithm: "m.megolm.v1.aes-sha2" } }],
      });
      await this.waitForRoom(room_id);
      await this.markDirect(other, room_id);
      return room_id;
    });
  }

  async startGroup(usernames: string[], name: string | null, photo: PreparedImage | null): Promise<string> {
    const people = usernames.map(toUserId).filter((p) => p !== this.me);
    return guard(async () => {
      for (const p of people) if (!(await this.exists(p))) fail(`There's no one called ${displayName(p)}.`);
      // A group can't take the shared-list marker as its name, or it would vanish from Messages.
      const clean = name === SHARED_ROOM.name ? null : name;
      const { room_id } = await this.client.createRoom({
        ...(clean ? { name: clean } : {}), preset: Preset.PrivateChat, visibility: Visibility.Private, invite: people,
        initial_state: [{ type: "m.room.encryption", state_key: "", content: { algorithm: "m.megolm.v1.aes-sha2" } }],
      });
      await this.waitForRoom(room_id);
      if (photo) await this.setGroupPhoto(room_id, photo).catch(() => {}); // can be added from the chat
      return room_id;
    });
  }

  /** A group photo, which Matrix keeps without end-to-end encryption. Only this server's own media. */
  async groupPhoto(mxc: string): Promise<Uint8Array> {
    if (!isOwnMedia(mxc)) fail("That group photo isn't on Totality's server.");
    return guard(() => net.matrixMedia(this.session.accessToken, mxc, THUMB_MAX));
  }

  // ---------- one chat ----------

  room(roomId: string): Room | null {
    const r = this.client.getRoom(roomId);
    return r && r.getMyMembership() === KnownMembership.Join && r.hasEncryptionStateEvent() ? r : null;
  }

  chatInfo(roomId: string): { title: string; isGroup: boolean; otherPerson: string | null; extraPeople: string[]; photo: string | null; people: number } | null {
    const r = this.room(roomId);
    if (!r) return null;
    const isGroup = !this.isDirect(r);
    const other = isGroup ? null : this.otherMember(r);
    const members = this.activeMembers(r);
    return { title: r.name || (other ? displayName(other) : "Chat"), isGroup, otherPerson: other, extraPeople: isGroup ? [] : extraPeople(members, this.me, other), photo: isGroup ? r.getMxcAvatarUrl() : null, people: members.length };
  }

  messages(roomId: string): ChatMessage[] {
    const r = this.room(roomId);
    if (!r) return [];
    const events = [...r.getLiveTimeline().getEvents(), ...r.getPendingEvents()];
    // Reactions: who reacted with what, and your own reaction event so it can be taken back.
    const reactions = new Map<string, Map<string, Set<string>>>();
    for (const ev of events) {
      if (ev.getType() !== "m.reaction" || ev.isRedacted() || ev.status === EventStatus.NOT_SENT) continue;
      const rel = ev.getContent()["m.relates_to"];
      if (rel?.rel_type !== "m.annotation" || typeof rel.event_id !== "string" || typeof rel.key !== "string") continue;
      // Reactions are short emoji; anything long, or past 20 kinds on one message, isn't shown (review L5).
      if (rel.key.length === 0 || rel.key.length > 16) continue;
      const byKey = reactions.get(rel.event_id) ?? new Map<string, Set<string>>();
      if (!byKey.has(rel.key) && byKey.size >= 20) continue;
      byKey.set(rel.key, (byKey.get(rel.key) ?? new Set()).add(ev.getSender() ?? ""));
      reactions.set(rel.event_id, byKey);
    }
    const out: ChatMessage[] = [];
    const ids: string[] = [];
    for (const ev of events) {
      const m = this.message(r, ev, reactions);
      if (m) { out.push(m); ids.push(ev.getId() ?? ""); }
    }
    // Seen: the newest message someone else has read.
    let readUpTo: number | null = null;
    for (const member of this.activeMembers(r)) {
      if (member === this.me) continue;
      const upTo = r.getEventReadUpTo(member);
      const at = upTo ? ids.lastIndexOf(upTo) : -1;
      if (at >= 0 && (readUpTo === null || at > readUpTo)) readUpTo = at;
    }
    return markingSeen(out, readUpTo);
  }

  private message(room: Room, ev: MatrixEvent, reactions: Map<string, Map<string, Set<string>>>): ChatMessage | null {
    const type = ev.getType();
    if (type !== "m.room.message" && type !== "m.room.encrypted") return null;
    const isOwn = ev.getSender() === this.me;
    const id = ev.getId() ?? ev.getTxnId() ?? "";
    const state = ev.status === EventStatus.NOT_SENT ? "failed" : ev.status && ev.status !== EventStatus.SENT ? "sending" : "sent";
    const base = { id, sender: ev.getSender() ?? "", isOwn, time: ev.getTs(), state, seen: false, replyTo: null, reactions: [] as Reaction[] } as const;
    if (ev.isRedacted()) return { ...base, body: "Message deleted", decrypted: true, kind: { type: "deleted" }, canReply: false };
    if (ev.isDecryptionFailure()) return { ...base, body: LockedMessage.placeholder(isOwn), decrypted: false, kind: { type: "text" }, canReply: false };
    if (type !== "m.room.message") return null; // still opening; it shows once decrypted
    const c = ev.getContent();
    if (c["m.relates_to"]?.rel_type === "m.replace") return null; // edits aren't sent by Totality
    let kind: Kind;
    let body: string;
    if (c.msgtype === "m.image") { kind = { type: "photo", width: num(c.info?.w), height: num(c.info?.h) }; body = "Photo"; }
    else if (c.msgtype === "m.video") { const ms = num(c.info?.duration); kind = { type: "video", seconds: ms === undefined ? undefined : ms / 1000 }; body = "Video"; }
    else { const t = previewText(c.msgtype, c.body); if (t === null) return null; kind = { type: "text" }; body = t; }
    const mine = reactions.get(ev.getId() ?? "");
    const list: Reaction[] = mine ? [...mine].map(([key, who]) => ({ key, count: who.size, mine: who.has(this.me) })) : [];
    const replyId = c["m.relates_to"]?.["m.in_reply_to"]?.event_id;
    return { ...base, body, decrypted: true, kind, reactions: list, replyTo: typeof replyId === "string" ? this.replyPreview(room, replyId) : null, canReply: state === "sent" };
  }

  private replyPreview(room: Room, eventId: string): { sender: string; text: string } {
    const found = room.findEventById(eventId);
    if (found) return { sender: found.getSender() ?? "", text: this.previewOf(found) ?? "Message" };
    const cached = this.replyCache.get(eventId);
    if (cached === "missing") return { sender: "", text: "The message this replies to isn't available" };
    if (cached) return cached;
    this.replyCache.set(eventId, { sender: "", text: "Loading the message this replies to" });
    void (async () => {
      try {
        const raw = await this.client.fetchRoomEvent(room.roomId, eventId);
        const { MatrixEvent: Ev } = await import("matrix-js-sdk");
        const ev = new Ev(raw);
        await this.client.decryptEventIfNeeded(ev);
        this.replyCache.set(eventId, { sender: ev.getSender() ?? "", text: this.previewOf(ev) ?? "Message" });
      } catch { this.replyCache.set(eventId, "missing"); }
      this.changed();
    })();
    return { sender: "", text: "Loading the message this replies to" };
  }

  typing(roomId: string): string[] {
    const r = this.room(roomId);
    return r ? r.getMembers().filter((m) => m.typing && m.userId !== this.me).map((m) => displayName(m.userId)) : [];
  }

  private findEvent(room: Room, id: string): MatrixEvent | null {
    return room.findEventById(id) ?? room.getPendingEvents().find((e) => e.getId() === id || e.getTxnId() === id) ?? null;
  }

  private sendable(roomId: string): Room {
    const r = this.room(roomId);
    if (!r) fail(MessagesErrors.notEncrypted);
    return r!;
  }
  private replyTo(roomId: string, replyingTo: string | null): Record<string, unknown> {
    if (!replyingTo) return {};
    const ev = this.findEvent(this.sendable(roomId), replyingTo);
    const eventId = ev?.getId();
    return eventId && !eventId.startsWith("~") ? { "m.relates_to": { "m.in_reply_to": { event_id: eventId } } } : {};
  }

  async send(roomId: string, text: string, replyingTo: string | null): Promise<void> {
    this.sendable(roomId);
    await guard(() => this.client.sendEvent(roomId, EventType.RoomMessage, { msgtype: "m.text", body: text, ...this.replyTo(roomId, replyingTo) } as never));
  }

  private async uploadSealed(bytes: Uint8Array): Promise<Record<string, unknown>> {
    const { data, info } = await encryptAttachment(bytes);
    const up = await this.client.uploadContent(new Blob([data as Uint8Array<ArrayBuffer>], { type: "application/octet-stream" }), { type: "application/octet-stream", includeFilename: false });
    return { ...info, url: up.content_uri };
  }

  /** The SDK has no attachment sealing, so the page seals here (attach.ts) and uploads only ciphertext. */
  async sendPhoto(roomId: string, photo: PreparedImage & { thumb: PreparedImage }, replyingTo: string | null): Promise<void> {
    this.sendable(roomId);
    await guard(async () => {
      const file = await this.uploadSealed(photo.data);
      const thumb = await this.uploadSealed(photo.thumb.data);
      await this.client.sendEvent(roomId, EventType.RoomMessage, {
        msgtype: "m.image", body: "photo.jpg", file,
        info: { mimetype: "image/jpeg", size: photo.data.length, w: photo.width, h: photo.height, thumbnail_file: thumb, thumbnail_info: { mimetype: "image/jpeg", size: photo.thumb.data.length, w: photo.thumb.width, h: photo.thumb.height } },
        ...this.replyTo(roomId, replyingTo),
      } as never);
    });
  }

  async sendVideo(roomId: string, video: PreparedVideo, replyingTo: string | null): Promise<void> {
    this.sendable(roomId);
    await guard(async () => {
      const file = await this.uploadSealed(video.data);
      const thumb = await this.uploadSealed(video.thumb.data);
      await this.client.sendEvent(roomId, EventType.RoomMessage, {
        msgtype: "m.video", body: "video.mp4", file,
        info: { mimetype: "video/mp4", size: video.data.length, w: video.width, h: video.height, duration: Math.round(video.seconds * 1000), thumbnail_file: thumb, thumbnail_info: { mimetype: "image/jpeg", size: video.thumb.data.length, w: video.thumb.width, h: video.thumb.height } },
        ...this.replyTo(roomId, replyingTo),
      } as never);
    });
  }

  /** A photo's or video's bytes, downloaded as ciphertext and opened here with the key from the message. */
  async media(roomId: string, messageId: string, which: "thumbnail" | "full"): Promise<{ bytes: Uint8Array; type: string }> {
    const r = this.room(roomId);
    const ev = r ? this.findEvent(r, messageId) : null;
    if (!ev || ev.isRedacted()) fail("That photo isn't here any more.");
    const c = ev!.getContent();
    const isVideo = c.msgtype === "m.video";
    const thumbFile = c.info?.thumbnail_file;
    // The list only ever loads a real thumbnail; a photo sent without one waits for a tap (review M2).
    const file = which === "thumbnail" ? thumbFile : c.file;
    if (!file || !isOwnMedia(file.url)) fail("That photo isn't here any more.");
    const type = file === thumbFile ? "image/jpeg" : isVideo ? "video/mp4" : String(c.info?.mimetype ?? "image/jpeg");
    if (!/^(image\/(jpeg|png|gif|webp)|video\/mp4)$/.test(type)) fail("This kind of file opens on your iPhone.");
    return guard(async () => {
      const sealed = await net.matrixMedia(this.session.accessToken, file.url, file === thumbFile ? THUMB_MAX : isVideo ? VIDEO_MAX + 1024 : PHOTO_MAX + 1024);
      return { bytes: await decryptAttachment(sealed, file), type };
    });
  }

  async toggleReaction(roomId: string, key: string, messageId: string): Promise<void> {
    const r = this.sendable(roomId);
    await guard(async () => {
      const own = r.getLiveTimeline().getEvents().find((e) => e.getType() === "m.reaction" && !e.isRedacted() && e.getSender() === this.me && e.getContent()["m.relates_to"]?.event_id === messageId && e.getContent()["m.relates_to"]?.key === key);
      if (own?.getId()) await this.client.redactEvent(roomId, own.getId()!);
      else await this.client.sendEvent(roomId, EventType.Reaction, { "m.relates_to": { rel_type: "m.annotation", event_id: messageId, key } } as never);
    });
  }

  async delete(roomId: string, messageId: string): Promise<void> {
    const r = this.sendable(roomId);
    const ev = this.findEvent(r, messageId);
    if (!ev) fail("That message isn't here any more.");
    if (ev!.status === EventStatus.NOT_SENT) { this.client.cancelPendingEvent(ev!); return; }
    await guard(() => this.client.redactEvent(roomId, messageId));
  }

  async retry(roomId: string, messageId: string): Promise<void> {
    const r = this.sendable(roomId);
    const ev = this.findEvent(r, messageId);
    if (ev && ev.status === EventStatus.NOT_SENT) await guard(() => this.client.resendEvent(ev, r));
  }

  async loadEarlier(roomId: string): Promise<void> {
    const r = this.room(roomId);
    if (r) await this.client.scrollback(r, 40).catch(() => {});
  }

  async markRead(roomId: string, share: boolean): Promise<void> {
    const r = this.room(roomId);
    const events = r?.getLiveTimeline().getEvents() ?? [];
    const last = [...events].reverse().find((e) => e.getId() && !e.getId()!.startsWith("~"));
    if (last) await this.client.sendReadReceipt(last, share ? ReceiptType.Read : ReceiptType.ReadPrivate).catch(() => {});
  }

  async setTyping(roomId: string, typing: boolean): Promise<void> {
    await this.client.sendTyping(roomId, typing, 4000).catch(() => {});
  }

  disappearing(roomId: string): DisappearingState {
    const ev = this.room(roomId)?.currentState.getStateEvents(RETENTION_EVENT, "");
    if (!ev) return { setting: "off", since: null, changedBy: null };
    return { setting: disappearingFrom(ev.getContent()), since: ev.getTs() || null, changedBy: ev.getSender() === this.me ? null : ev.getSender() ?? null };
  }
  async setDisappearing(roomId: string, d: Disappearing): Promise<void> {
    this.sendable(roomId);
    await guard(() => this.client.sendStateEvent(roomId, RETENTION_EVENT as never, disappearingContent(d) as never, ""));
  }

  async rename(roomId: string, name: string | null): Promise<void> {
    if (!this.chatInfo(roomId)?.isGroup) return;
    await guard(() => this.client.setRoomName(roomId, name ?? ""));
  }
  async setGroupPhoto(roomId: string, photo: PreparedImage | null): Promise<void> {
    await guard(async () => {
      if (!photo) { await this.client.sendStateEvent(roomId, "m.room.avatar" as never, {} as never, ""); return; }
      // Group photos aren't end-to-end encrypted in Matrix, which the screens say.
      const up = await this.client.uploadContent(new Blob([photo.data as Uint8Array<ArrayBuffer>], { type: "image/jpeg" }), { type: "image/jpeg", includeFilename: false });
      await this.client.sendStateEvent(roomId, "m.room.avatar" as never, { url: up.content_uri, info: { mimetype: "image/jpeg", w: photo.width, h: photo.height, size: photo.data.length } } as never, "");
    });
  }
}

export interface PreparedImage { data: Uint8Array; width: number; height: number }
export interface PreparedVideo { data: Uint8Array; width: number; height: number; seconds: number; thumb: PreparedImage }
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
