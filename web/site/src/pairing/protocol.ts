// Pairing a browser from the iPhone (website architecture proposal §3, security review #1).
// The iPhone's copy is Sources/TotalityCore/Crypto/BrowserPairing.swift. docs/pairing-vectors.json holds
// vectors that both test suites read, so the two can't drift apart.
import { x25519 } from "@noble/curves/ed25519.js";
import { xchacha20poly1305 } from "@noble/ciphers/chacha.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";

const enc = new TextEncoder();
export const VERSION = 1;
export const KEY_BYTES = 32;

export type PairingError = "badQR" | "wrongKey" | "badSeal" | "expired";
export class PairingFailure extends Error {
  constructor(readonly reason: PairingError) { super(reason); }
}

export const toHex = (b: Uint8Array): string => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
export function fromHex(s: string, bytes: number): Uint8Array {
  if (!new RegExp(`^[0-9a-f]{${bytes * 2}}$`).test(s)) throw new PairingFailure("badQR");
  return Uint8Array.from(s.match(/../g)!, (h) => parseInt(h, 16));
}
export const uuidBytes = (u: string): Uint8Array => {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(u)) throw new PairingFailure("badQR");
  return fromHex(u.replaceAll("-", ""), 16);
};
const cat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};
export const b64 = (b: Uint8Array): string => btoa(String.fromCharCode(...b));
export const unb64 = (s: string): Uint8Array => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

export interface BrowserKeys { priv: Uint8Array; pub: Uint8Array; slotSecret: Uint8Array }

/** A fresh one-time key pair and slot secret. They never leave this page's memory. */
export function newBrowserKeys(random: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): BrowserKeys {
  const priv = random(32);
  return { priv, pub: x25519.getPublicKey(priv), slotSecret: random(32) };
}

/** What the browser shows as a QR code. The hash lets the iPhone notice a swapped public key. */
export function qrText(slotId: string, keys: Pick<BrowserKeys, "pub" | "slotSecret">): string {
  return `totality-pair/1/${slotId}/${toHex(keys.slotSecret)}/${keyHash(keys.pub)}`;
}
export const keyHash = (browserPub: Uint8Array): string => toHex(sha256(cat(enc.encode("totality/pair-key/v1"), browserPub)));

export interface ParsedQR { slotId: string; slotSecret: Uint8Array; keyHash: string }
export function parseQR(text: string): ParsedQR {
  const parts = text.split("/");
  if (parts.length !== 5 || parts[0] !== "totality-pair" || parts[1] !== "1") throw new PairingFailure("badQR");
  const [, , slotId, secret, hash] = parts as [string, string, string, string, string];
  uuidBytes(slotId);
  return { slotId, slotSecret: fromHex(secret, 32), keyHash: (fromHex(hash, 32), hash) };
}

/** Six digits both screens show. It only tells the person the iPhone scanned this screen's code. */
export function pairingCode(slotId: string, browserPub: Uint8Array): string {
  const h = sha256(cat(enc.encode("totality/pair-code/v1"), uuidBytes(slotId), browserPub));
  const n = ((h[0]! << 24) | (h[1]! << 16) | (h[2]! << 8) | h[3]!) >>> 0;
  return String(n % 1_000_000).padStart(6, "0");
}

function sessionKey(shared: Uint8Array, slotId: string, slotSecret: Uint8Array, browserPub: Uint8Array, phonePub: Uint8Array): Uint8Array {
  const info = cat(enc.encode("totality/pair/v1"), uuidBytes(slotId), browserPub, phonePub);
  return hkdf(sha256, shared, slotSecret, info, 32);
}
const aad = (slotId: string): Uint8Array => cat(enc.encode("totality/pair/v1"), uuidBytes(slotId));

/** The iPhone's half, kept here so tests can run a whole pairing and the vectors can be made. */
export function sealForBrowser(opts: {
  qr: ParsedQR; browserPub: Uint8Array; phonePriv: Uint8Array; rootKey: Uint8Array; nonce?: Uint8Array;
}): { phonePub: Uint8Array; sealed: Uint8Array } {
  if (keyHash(opts.browserPub) !== opts.qr.keyHash) throw new PairingFailure("wrongKey");
  if (opts.rootKey.length !== KEY_BYTES) throw new PairingFailure("badSeal");
  const phonePub = x25519.getPublicKey(opts.phonePriv);
  const key = sessionKey(x25519.getSharedSecret(opts.phonePriv, opts.browserPub), opts.qr.slotId, opts.qr.slotSecret, opts.browserPub, phonePub);
  const nonce = opts.nonce ?? crypto.getRandomValues(new Uint8Array(24));
  const box = xchacha20poly1305(key, nonce, aad(opts.qr.slotId)).encrypt(opts.rootKey);
  return { phonePub, sealed: cat(Uint8Array.of(VERSION), nonce, box) };
}

/** The browser's half: opens what the iPhone sealed. Anything off, from anyone, throws. */
export function openSealed(opts: {
  slotId: string; keys: BrowserKeys; phonePub: Uint8Array; sealed: Uint8Array;
}): Uint8Array {
  const { sealed } = opts;
  if (sealed.length !== 1 + 24 + KEY_BYTES + 16 || sealed[0] !== VERSION) throw new PairingFailure("badSeal");
  const key = sessionKey(x25519.getSharedSecret(opts.keys.priv, opts.phonePub), opts.slotId, opts.keys.slotSecret, opts.keys.pub, opts.phonePub);
  try {
    return xchacha20poly1305(key, sealed.slice(1, 25), aad(opts.slotId)).decrypt(sealed.slice(25));
  } catch {
    throw new PairingFailure("badSeal");
  }
}
