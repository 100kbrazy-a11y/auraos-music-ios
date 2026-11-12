// Where the song files themselves live.
//  - iPhone app: real files in the app's Library folder, played straight from disk (the web view on iPhone
//    can't reliably keep big audio files in its database or play them from there).
//  - everywhere else: in IndexedDB, as before.
import { Capacitor } from "@capacitor/core";
import { idb } from "./store.js";
import { diag, timed } from "./diag.js";

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
  const fsx = await timed(fs(), 20000, "Loading the file module"), path = ROOT + file;
  const name = file.replace(/^.*\//, "");
  const CH = 1536 * 1024;                         // written in pieces so a big file never sits in memory twice
  const n = Math.max(1, Math.ceil(blob.size / CH));
  for (let i = 0, off = 0; i < n; i++, off += CH) {
    diag.step = `Saving ${name} · ${i + 1}/${n}`;
    const data = await timed(toBase64(blob.slice(off, off + CH)), 45000, `Reading ${name} (part ${i + 1})`);
    if (i === 0) await timed(fsx.writeFile({ directory: DIR, path, data, recursive: true }), 45000, `Saving ${name} (part 1)`);
    else await timed(fsx.appendFile({ directory: DIR, path, data }), 45000, `Saving ${name} (part ${i + 1})`);
  }
  diag.log(`saved ${file} (${Math.round(blob.size / 1024)} KB, ${n} parts)`);
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

/** A file on the phone read in pieces through the app's file server (byte ranges), so a big music pack never has
 *  to be loaded into memory. Has just what the zip reader needs: size, name, slice(), arrayBuffer(), stream(). */
export class DiskFile {
  constructor(url, size, name, start = 0, end = size) { this.url = url; this.total = size; this.name = name; this.start = start; this.end = end; }
  get size() { return Math.max(0, this.end - this.start); }
  slice(a = 0, b = this.size) {
    const n = this.size;
    const s = a < 0 ? Math.max(0, n + a) : Math.min(n, a), e = b < 0 ? Math.max(0, n + b) : Math.min(n, b);
    return new DiskFile(this.url, this.total, this.name, this.start + s, this.start + Math.max(s, e));
  }
  async arrayBuffer() {
    if (!this.size) return new ArrayBuffer(0);
    const r = await timed(fetch(this.url, { headers: { Range: `bytes=${this.start}-${this.end - 1}` } }), 120000, `Reading ${this.name}`);
    if (!r.ok && r.status !== 0) throw new Error(`Couldn't read ${this.name} (${r.status})`);
    const buf = await r.arrayBuffer();
    if (buf.byteLength !== this.size) throw new Error(`Couldn't read ${this.name} (got ${buf.byteLength} of ${this.size} bytes)`);
    return buf;
  }
  /** a real Blob of these bytes */
  async realize(type = "") { return new Blob([await this.arrayBuffer()], { type }); }
  async text() { return new TextDecoder().decode(await this.arrayBuffer()); }
  stream() { const self = this; return new ReadableStream({ async start(c) { c.enqueue(new Uint8Array(await self.arrayBuffer())); c.close(); } }); }
}
