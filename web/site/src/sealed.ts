// Opening what the iPhone sealed. Mirrors Sources/TotalityCore/Crypto/ContentCipher.swift:
//   blob   = version (1) · nonce (24) · XChaCha20-Poly1305 ciphertext and tag
//   AD     = "totality/blob/v1" + the object's 16 UUID bytes
//   key    = HKDF-SHA256(root, salt empty, info "totality/<purpose>/v1" + UUID bytes) → 32 bytes
// docs/reader-vectors.json is made by the real ReaderVault, and test/reader.test.mjs opens it with this.
import { xchacha20poly1305 } from "@noble/ciphers/chacha.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { fromHex, uuidBytes } from "./pairing/protocol";

const te = new TextEncoder();
export type Purpose = "content" | "metadata";

export class OpenFailure extends Error {}

/** For tests and tools that hold the raw key. The page itself never does: it derives through keystore.ts. */
export function objectKeyFromRoot(root: Uint8Array, purpose: Purpose, id: string): Uint8Array {
  const info = new Uint8Array([...te.encode(`totality/${purpose}/v1`), ...uuidBytes(id)]);
  return hkdf(sha256, root, new Uint8Array(0), info, 32);
}

export function openBlob(sealed: Uint8Array, key: Uint8Array, id: string): Uint8Array {
  if (sealed.length < 1 + 24 + 16 || sealed[0] !== 1) throw new OpenFailure("format");
  const ad = new Uint8Array([...te.encode("totality/blob/v1"), ...uuidBytes(id)]);
  try {
    return xchacha20poly1305(key, sealed.slice(1, 25), ad).decrypt(sealed.slice(25));
  } catch {
    throw new OpenFailure("authentication");
  }
}

/** Postgres hands bytea back as `\x…`. */
export function fromByteaLiteral(s: string): Uint8Array {
  if (!s.startsWith("\\x") || s.length % 2 !== 0) throw new OpenFailure("bytea");
  return fromHex(s.slice(2), (s.length - 2) / 2);
}
