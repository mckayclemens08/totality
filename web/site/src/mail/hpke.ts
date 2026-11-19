// Opening a message the mail server sealed to this account. RFC 9180 HPKE, base mode, DHKEM(X25519,
// HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305. The server's own seal() and the iPhone's CryptoKit open() are
// the two other halves; test/mail.test.mjs opens a message made by the server's real seal() code.
//   sealed = version (1) · encapsulated key (32) · ciphertext and tag
//   info   = "totality/mail/v1";  aad = info + mailbox ID bytes + message ID bytes
import { x25519 } from "@noble/curves/ed25519.js";
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { expand, extract } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { uuidBytes } from "../pairing/protocol";

const te = new TextEncoder();
const cat = (...p: Uint8Array[]): Uint8Array => { const o = new Uint8Array(p.reduce((n, x) => n + x.length, 0)); let a = 0; for (const x of p) { o.set(x, a); a += x.length; } return o; };
const KEM_SUITE = Uint8Array.of(...te.encode("KEM"), 0x00, 0x20);
const SUITE = Uint8Array.of(...te.encode("HPKE"), 0x00, 0x20, 0x00, 0x01, 0x00, 0x03);
const V1 = te.encode("HPKE-v1");
export const MAIL_INFO = te.encode("totality/mail/v1");

const labeledExtract = (suite: Uint8Array, salt: Uint8Array, label: string, ikm: Uint8Array) =>
  extract(sha256, cat(V1, suite, te.encode(label), ikm), salt.length ? salt : new Uint8Array(32));
const labeledExpand = (suite: Uint8Array, prk: Uint8Array, label: string, info: Uint8Array, len: number) =>
  expand(sha256, prk, cat(Uint8Array.of(len >> 8, len & 255), V1, suite, te.encode(label), info), len);

export class MailOpenFailure extends Error {}

/** The account's mail key pair, from the 32 bytes HKDF(root, info "totality/mail-key/v1") gives. */
export const mailPublicKey = (seed: Uint8Array): Uint8Array => x25519.getPublicKey(seed);

export function openMail(sealed: Uint8Array, seed: Uint8Array, mailbox: string, message: string): Uint8Array {
  if (sealed.length < 1 + 32 + 16 || sealed[0] !== 1) throw new MailOpenFailure("format");
  try {
    const enc = sealed.slice(1, 33), pkR = x25519.getPublicKey(seed);
    const dh = x25519.getSharedSecret(seed, enc);
    const eae = labeledExtract(KEM_SUITE, new Uint8Array(0), "eae_prk", dh);
    const shared = labeledExpand(KEM_SUITE, eae, "shared_secret", cat(enc, pkR), 32);
    const context = cat(Uint8Array.of(0), labeledExtract(SUITE, new Uint8Array(0), "psk_id_hash", new Uint8Array(0)), labeledExtract(SUITE, new Uint8Array(0), "info_hash", MAIL_INFO));
    const secret = labeledExtract(SUITE, shared, "secret", new Uint8Array(0));
    const key = labeledExpand(SUITE, secret, "key", context, 32), nonce = labeledExpand(SUITE, secret, "base_nonce", context, 12);
    return chacha20poly1305(key, nonce, cat(MAIL_INFO, uuidBytes(mailbox), uuidBytes(message))).decrypt(sealed.slice(33));
  } catch {
    throw new MailOpenFailure("authentication");
  }
}

export interface Opened { received: number | null; flagged: boolean; from: string | null; rest: Uint8Array }
/** One line of JSON with what the server knew, then the message as it arrived. */
export function splitEnvelope(opened: Uint8Array): Opened | null {
  const nl = opened.indexOf(0x0a);
  if (nl < 0) return null;
  try {
    const f = JSON.parse(new TextDecoder().decode(opened.slice(0, nl))) as { version?: number; received?: string; spam?: { flagged?: boolean }; from?: string };
    if (f.version !== 1) return null;
    const t = f.received ? Date.parse(f.received) : NaN;
    return { received: Number.isNaN(t) ? null : t, flagged: f.spam?.flagged === true, from: typeof f.from === "string" ? f.from : null, rest: opened.slice(nl + 1) };
  } catch { return null; }
}
