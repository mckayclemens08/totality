// Matrix encrypted attachments (spec "Sending encrypted attachments", v2): AES-256-CTR with a fresh key and
// IV per file, and a SHA-256 of the ciphertext. The file key travels only inside the encrypted message, so
// the server stores ciphertext it can't open. The same format the iPhone SDK writes and reads.

export interface EncryptedFile {
  v: "v2";
  url: string;
  key: { alg: "A256CTR"; ext: true; k: string; key_ops: ["encrypt", "decrypt"]; kty: "oct" };
  iv: string;
  hashes: { sha256: string };
}

const unpadded = (bytes: Uint8Array): string => btoa(String.fromCharCode(...bytes)).replace(/=+$/, "");
const fromB64 = (s: string): Uint8Array => {
  const std = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(std + "===".slice((std.length + 3) % 4)), (c) => c.charCodeAt(0));
};
const b64url = (bytes: Uint8Array): string => unpadded(bytes).replace(/\+/g, "-").replace(/\//g, "_");
const buf = (u: Uint8Array) => u as Uint8Array<ArrayBuffer>;

/** Seals bytes for upload. `url` is filled in once the ciphertext is uploaded. */
export async function encryptAttachment(plain: Uint8Array): Promise<{ data: Uint8Array; info: Omit<EncryptedFile, "url"> }> {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  // The spec keeps the counter half of the IV zero, so a file can't wrap the counter.
  const iv = new Uint8Array(16);
  crypto.getRandomValues(iv.subarray(0, 8));
  const key = await crypto.subtle.importKey("raw", buf(raw), { name: "AES-CTR" }, false, ["encrypt"]);
  const data = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-CTR", counter: buf(iv), length: 64 }, key, buf(plain)));
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", buf(data)));
  const info = {
    v: "v2" as const,
    key: { alg: "A256CTR" as const, ext: true as const, k: b64url(raw), key_ops: ["encrypt", "decrypt"] as ["encrypt", "decrypt"], kty: "oct" as const },
    iv: unpadded(iv),
    hashes: { sha256: unpadded(hash) },
  };
  raw.fill(0);
  return { data, info };
}

/** Opens downloaded ciphertext. Refuses anything whose hash or shape doesn't check out. */
export async function decryptAttachment(data: Uint8Array, file: unknown): Promise<Uint8Array> {
  const f = file as Partial<EncryptedFile> | null;
  if (!f || f.key?.alg !== "A256CTR" || f.key.kty !== "oct" || typeof f.key.k !== "string" || typeof f.iv !== "string" || typeof f.hashes?.sha256 !== "string") throw new Error("bad attachment");
  if (f.v !== undefined && f.v !== "v2") throw new Error("bad attachment");
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", buf(data)));
  const want = fromB64(f.hashes.sha256);
  if (want.length !== 32 || want.some((b, i) => b !== hash[i])) throw new Error("hash mismatch");
  const raw = fromB64(f.key.k), iv = fromB64(f.iv);
  if (raw.length !== 32 || iv.length !== 16) throw new Error("bad attachment");
  const key = await crypto.subtle.importKey("raw", buf(raw), { name: "AES-CTR" }, false, ["decrypt"]);
  raw.fill(0);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-CTR", counter: buf(iv), length: 64 }, key, buf(data)));
}
