// Photos and videos for Messages: preparing what's sent, and showing what arrives.
// Every blob: URL here is made from bytes this page has (picked by the user, or decrypted), kept in one set,
// and revoked when Messages closes, so nothing decrypted outlives the screen that showed it.
import type { PreparedImage, PreparedVideo } from "./engine";

const urls = new Set<string>();
export function blobUrl(bytes: Uint8Array, type: string): string {
  const url = URL.createObjectURL(new Blob([bytes as Uint8Array<ArrayBuffer>], { type }));
  urls.add(url);
  return url;
}
export function revoke(url: string): void { if (urls.delete(url)) URL.revokeObjectURL(url); }
export function revokeAll(): void { for (const u of urls) URL.revokeObjectURL(u); urls.clear(); }

/** The iPhone's sizes (MessagesPhotos.swift, MessagesVideo.swift). */
export const PHOTO_SIDE = 2048, THUMB_SIDE = 480, GROUP_SIDE = 512, VIDEO_SECONDS = 60, VIDEO_BYTES = 100 * 1024 * 1024;
const PICKED_LIMIT = 50 * 1024 * 1024;

async function encode(source: CanvasImageSource, w: number, h: number, side: number, quality: number): Promise<PreparedImage> {
  const scale = Math.min(1, side / Math.max(w, h));
  const width = Math.max(1, Math.round(w * scale)), height = Math.max(1, Math.round(h * scale));
  const canvas = document.createElement("canvas");
  canvas.width = width; canvas.height = height;
  const g = canvas.getContext("2d");
  if (!g) throw new Error("That photo couldn't be opened.");
  g.drawImage(source, 0, 0, width, height);
  const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, "image/jpeg", quality));
  if (!blob) throw new Error("That photo couldn't be opened.");
  return { data: new Uint8Array(await blob.arrayBuffer()), width, height };
}

/** Redrawn as a JPEG, which leaves location and camera details behind, as the iPhone does. */
export async function preparePhoto(file: File): Promise<PreparedImage & { thumb: PreparedImage }> {
  if (!file.type.startsWith("image/") || file.size > PICKED_LIMIT) throw new Error("That photo couldn't be opened.");
  let bitmap: ImageBitmap;
  try { bitmap = await createImageBitmap(file, { imageOrientation: "from-image" }); } catch { throw new Error("That photo couldn't be opened."); }
  try {
    const full = await encode(bitmap, bitmap.width, bitmap.height, PHOTO_SIDE, 0.85);
    const thumb = await encode(bitmap, bitmap.width, bitmap.height, THUMB_SIDE, 0.8);
    return { ...full, thumb };
  } finally { bitmap.close(); }
}

export async function prepareGroupPhoto(file: File): Promise<PreparedImage> {
  if (!file.type.startsWith("image/") || file.size > PICKED_LIMIT) throw new Error("That photo couldn't be opened.");
  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" }).catch(() => { throw new Error("That photo couldn't be opened."); });
  try { return await encode(bitmap, bitmap.width, bitmap.height, GROUP_SIDE, 0.85); } finally { bitmap.close(); }
}

/** An MP4 up to a minute long, sent as picked, with a frame from its start as the thumbnail. */
export async function prepareVideo(file: File): Promise<PreparedVideo> {
  if (file.type !== "video/mp4") throw new Error("Videos need to be MP4 files.");
  if (file.size > VIDEO_BYTES) throw new Error("That video is too big to send. Videos can be up to 100 MB.");
  const data = new Uint8Array(await file.arrayBuffer());
  const url = blobUrl(data, "video/mp4");
  try {
    const video = document.createElement("video");
    video.muted = true; video.preload = "auto"; video.src = url;
    await new Promise<void>((ok, bad) => { video.onloadeddata = () => ok(); video.onerror = () => bad(new Error("That video couldn't be opened.")); });
    const seconds = video.duration;
    if (!Number.isFinite(seconds) || seconds <= 0) throw new Error("That video couldn't be opened.");
    if (seconds > VIDEO_SECONDS + 0.5) throw new Error("Videos can be up to a minute long.");
    video.currentTime = Math.min(0.1, seconds / 2);
    await new Promise<void>((ok) => { video.onseeked = () => ok(); setTimeout(ok, 1500); });
    const thumb = await encode(video, video.videoWidth || 640, video.videoHeight || 360, THUMB_SIDE, 0.8);
    return { data, width: video.videoWidth, height: video.videoHeight, seconds, thumb };
  } finally { revoke(url); }
}
