// IDs the iPhone and the website must work out the same way.
import { sha256 } from "@noble/hashes/sha2.js";

/** UUID(derivedFrom:) in SyncEngine.swift: the same text always names the same thing, so a retry can't make two. */
export function derivedID(text: string): string {
  const b = sha256(new TextEncoder().encode(text)).slice(0, 16);
  b[6] = (b[6]! & 0x0f) | 0x40;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const x = Array.from(b, (n) => n.toString(16).padStart(2, "0")).join("");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`.toUpperCase();
}
