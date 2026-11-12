// Where the song files themselves live.
//  - iPhone app: real files in the app's Library folder, played straight from disk (the web view on iPhone
//    can't reliably keep big audio files in its database or play them from there).
//  - everywhere else: in IndexedDB, as before.
import { Capacitor } from "@capacitor/core";
import { idb } from "./store.js";

export const onDisk = Capacitor.isNativePlatform() && Capacitor.getPlatform() === "ios";
const ROOT = "Songs/";
let F = null, DIR = null;
async function fs() {
  if (!F) { const m = await import("@capacitor/filesystem"); F = m.Filesystem; DIR = m.Directory.Library; }
  return F;
}
function toBase64(b) {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(",")[1] || ""); r.onerror = () => rej(r.error); r.readAsDataURL(b); });
}

/** Store a song's audio. Returns where it went ("disk" or "db"). */
export async function putSongFile(blob, file) {
  if (!onDisk) {
    await idb.put("files", blob instanceof File ? new Blob([blob], { type: blob.type }) : blob, file);
    return "db";
  }
  const fsx = await fs(), path = ROOT + file;
  const CH = 3 * 1024 * 1024;                     // written in pieces so a big file never sits in memory twice
  for (let off = 0; off < blob.size || off === 0; off += CH) {
    const data = await toBase64(blob.slice(off, off + CH));
    if (off === 0) await fsx.writeFile({ directory: DIR, path, data, recursive: true });
    else await fsx.appendFile({ directory: DIR, path, data });
    if (blob.size === 0) break;
  }
  return "disk";
}

/** A URL the <audio> element can play. revoke: whether the caller should URL.revokeObjectURL it later. */
export async function songURL(s) {
  if (s.store === "disk") {
    const fsx = await fs();
    const { uri } = await fsx.getUri({ directory: DIR, path: ROOT + s.file });
    return { url: Capacitor.convertFileSrc(uri), revoke: false };
  }
  const blob = await idb.get("files", s.file);
  return blob ? { url: URL.createObjectURL(blob), revoke: true } : null;
}

/** The audio as a Blob (for making music packs). */
export async function songBlob(s) {
  if (s.store === "disk") {
    const u = await songURL(s);
    const r = await fetch(u.url);
    if (!r.ok) return null;
    const b = await r.blob();
    return b.type ? b : new Blob([b], { type: s.type || "" });
  }
  return idb.get("files", s.file);
}

export async function delSongFile(s) {
  if (s.store === "disk") { try { const fsx = await fs(); await fsx.deleteFile({ directory: DIR, path: ROOT + s.file }); } catch {} }
  else await idb.del("files", s.file);
}

/** Does this song's audio exist? */
export async function hasSongFile(s) {
  if (s.store === "disk") { try { const fsx = await fs(); await fsx.stat({ directory: DIR, path: ROOT + s.file }); return true; } catch { return false; } }
  return !!(await idb.get("files", s.file));
}
