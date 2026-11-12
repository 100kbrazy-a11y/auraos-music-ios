// EXPERIMENTAL — "Add from link": a YouTube / YouTube Music song, album or playlist link, resolved inside the app
// with YouTube.js (youtubei.js). The audio (m4a) is downloaded natively and added to the library like any other song;
// a playlist / album link also makes a playlist in the same order.
//
// YouTube actively blocks downloaders, so this tries several of YouTube's own app identities (the ones that usually
// don't need a "proof of origin" token first) and logs every step to Settings › Diagnostics.
// Only add music you have the right to.
import { Capacitor, CapacitorHttp } from "@capacitor/core";
import { diag, timed } from "./diag.js";
import { getBlob } from "./http.js";

const native = Capacitor.isNativePlatform();
// YouTube's app identities to try, in order (the first ones normally need no proof-of-origin token)
const CLIENTS = ["ANDROID_VR", "VISIONOS", "IOS", "TV_SIMPLY", "WEB_EMBEDDED", "MWEB", "WEB"];

/** fetch for YouTube.js, through the app's native networking (no browser cross-site blocking) */
async function nativeFetch(input, init = {}) {
  const req = input instanceof Request ? input : new Request(input, init);
  if (!native) return fetch(req);
  const method = (init.method || req.method || "GET").toUpperCase();
  const headers = {};
  new Headers(init.headers || req.headers).forEach((v, k) => { headers[k] = v; });
  let data;
  if (method !== "GET" && method !== "HEAD") {
    const text = typeof init.body === "string" ? init.body : init.body != null ? await new Response(init.body).text() : await req.clone().text();
    try { data = JSON.parse(text); } catch { data = text; }
  }
  const r = await CapacitorHttp.request({ url: req.url, method, headers, data, responseType: "text", connectTimeout: 20000, readTimeout: 40000 });
  let body = r.data;
  if (body != null && typeof body !== "string") body = JSON.stringify(body);
  const status = r.status >= 200 && r.status <= 599 ? r.status : 500;
  const h = new Headers();
  for (const [k, v] of Object.entries(r.headers || {})) { try { h.set(k, String(v)); } catch {} }
  return new Response([204, 205, 304].includes(status) ? null : body ?? "", { status, headers: h });
}

let ytp = null;
async function client() {
  if (!ytp) {
    ytp = (async () => {
      diag.set("YouTube: loading…");
      const mod = await import("youtubei.js/web");
      const { Innertube, Platform, UniversalCache } = mod;
      // YouTube.js has no JavaScript interpreter of its own for YouTube's scrambled player code: the web view is one
      Platform.shim.eval = (data) => new Function(data.output)();
      const yt = await timed(Innertube.create({ fetch: nativeFetch, cache: new UniversalCache(false), retrieve_player: true }), 45000, "Connecting to YouTube");
      diag.log("YouTube: connected");
      return { mod, yt };
    })();
  }
  try { return await ytp; } catch (e) { ytp = null; throw e; }
}

/** What a pasted link points at: { video } and/or { list } */
export function parseLink(text) {
  const m = String(text || "").match(/https?:\/\/[^\s]+/);
  let u;
  try { u = new URL(m ? m[0] : String(text).trim()); } catch { return null; }
  const host = u.hostname.replace(/^www\.|^m\./, "");
  if (!/(^|\.)youtube\.com$|^youtu\.be$|^music\.youtube\.com$/.test(host)) return null;
  let video = u.searchParams.get("v") || "";
  if (host === "youtu.be") video = u.pathname.slice(1).split("/")[0];
  const shorts = u.pathname.match(/^\/(shorts|embed|live)\/([\w-]{6,})/);
  if (shorts) video = shorts[2];
  let list = u.searchParams.get("list") || "";
  if (/^RD/.test(list)) list = "";                 // an automatic "mix": just the one song
  return video || list ? { video, list, music: host === "music.youtube.com" } : null;
}

// ---- tidy names (the same rules as aura-musicpack on the computer)
const JUNK = /\s*[([{]\s*(official|lyrics?|lyric video|audio|video|music video|hd|hq|4k|visuali[sz]er|full album|remaster(ed)?|explicit|clean|mv|m\/v)[^)\]}]*[)\]}]/gi;
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
function cleanTitle(title, artist) {
  let t = String(title || "").replace(JUNK, "").trim();
  t = t.replace(/\s+(official\s+(music\s+)?(video|audio)|lyrics?)\s*$/i, "").trim();
  if (artist) { const m = t.match(new RegExp("^\\s*" + esc(artist) + "\\s*[-–—:]\\s*(.+)$", "i")); if (m) t = m[1].trim(); }
  return t || title || "Untitled";
}
function tidy({ title, artist, album }) {
  artist = String(artist || "").replace(/\s*-\s*Topic$/i, "").replace(/VEVO$/i, "").trim();
  let t = String(title || "");
  if (!artist) { const m = t.match(/^(.+?)\s+[-–—]\s+(.+)$/); if (m && m[1].length < 60) { artist = m[1].trim(); t = m[2]; } }
  return { title: cleanTitle(t, artist), artist: artist || "Unknown Artist", album: String(album || "").trim() };
}
const bigThumb = (url, id) => {
  if (url && /googleusercontent|ggpht/.test(url)) return url.replace(/=w\d+-h\d+.*$/, "=w800-h800-l90-rj");
  return id ? `https://i.ytimg.com/vi/${id}/maxresdefault.jpg` : url;
};
const lastThumb = (t) => { const arr = t?.contents || t || []; return Array.isArray(arr) && arr.length ? arr[arr.length - 1]?.url || arr[0]?.url : ""; };

/** The songs a link points at, with their names (no downloading yet). */
async function resolve(link) {
  const { yt } = await client();
  if (link.list) {
    diag.set("YouTube: reading the playlist…");
    const tracks = [];
    let title = "";
    try {                                          // YouTube Music's view first (it knows albums and artists)
      let pl = await timed(yt.music.getPlaylist(link.list), 45000, "Reading the playlist");
      title = pl.header?.title?.toString?.() || pl.header?.title?.text || "";
      for (let page = 0; page < 40; page++) {
        for (const it of pl.items || []) {
          if (!it?.id) continue;
          tracks.push({ id: it.id, title: it.title, artist: (it.artists || it.authors || []).map((a) => a.name).filter(Boolean).join(", "),
            album: it.album?.name || "", duration: it.duration?.seconds || 0, thumb: lastThumb(it.thumbnail) });
        }
        if (!pl.has_continuation) break;
        pl = await timed(pl.getContinuation(), 45000, "Reading more of the playlist");
      }
    } catch (e) { diag.log(`YouTube Music playlist view failed (${e.message}); trying YouTube's`); }
    if (!tracks.length) {
      let pl = await timed(yt.getPlaylist(link.list), 45000, "Reading the playlist");
      title = pl.info?.title || title;
      for (let page = 0; page < 40; page++) {
        for (const v of pl.videos || pl.items || []) {
          if (!v?.id) continue;
          tracks.push({ id: v.id, title: v.title?.toString?.() || v.title?.text || "", artist: v.author?.name || "", album: "",
            duration: v.duration?.seconds || 0, thumb: lastThumb(v.thumbnails) });
        }
        if (!pl.has_continuation) break;
        pl = await timed(pl.getContinuation(), 45000, "Reading more of the playlist");
      }
    }
    title = String(title || "YouTube Playlist").replace(/^(Album|Single|EP)\s*-\s*/i, "");
    const isAlbum = /^OLAK5uy_/.test(link.list);
    tracks.forEach((t, i) => { if (isAlbum) { t.album ||= title; t.track = i + 1; } });
    diag.log(`YouTube: “${title}” has ${tracks.length} songs`);
    return { title, playlist: true, tracks };
  }
  return { title: "", playlist: false, tracks: [{ id: link.video }] };
}

/** A working audio address for one song: tries YouTube's app identities until one gives a downloadable m4a. */
async function audioFor(id) {
  const { mod, yt } = await client();
  let last = "";
  for (const name of CLIENTS) {
    try {
      const info = await timed(yt.getBasicInfo(id, { client: name }), 30000, `Asking YouTube (${name})`);
      const ps = info.playability_status;
      if (ps && ps.status && ps.status !== "OK") { last = `${name}: ${ps.status} ${ps.reason || ""}`.trim(); diag.log("YouTube: " + last); continue; }
      let fmt;
      try { fmt = info.chooseFormat({ type: "audio", quality: "best", format: "mp4" }); }
      catch { last = `${name}: no m4a audio`; diag.log("YouTube: " + last); continue; }
      const url = await timed(fmt.decipher(yt.session.player), 30000, "Unscrambling the audio address");
      const ua = mod.Constants?.CLIENTS?.[name]?.USER_AGENT || navigator.userAgent;
      const probe = await CapacitorHttp.request({ url: url + "&range=0-1023", method: "GET", headers: { "User-Agent": ua }, responseType: "text", connectTimeout: 15000, readTimeout: 20000 });
      if (probe.status >= 400) { last = `${name}: download refused (${probe.status})`; diag.log("YouTube: " + last); continue; }
      diag.log(`YouTube: ${name} works for ${id}`);
      const b = info.basic_info || {};
      return { url, ua, size: +fmt.content_length || 0, client: name,
        meta: { title: b.title || "", artist: b.author || "", duration: b.duration || 0, thumb: lastThumb(b.thumbnail) } };
    } catch (e) { last = `${name}: ${e.message || e}`; diag.log("YouTube: " + last); }
  }
  throw new Error("YouTube wouldn't let the app download this one" + (last ? ` (${last})` : ""));
}

/** Download to Library/Incoming natively (straight to a file; never through the web view). */
async function download(a, id, onFrac) {
  const { Filesystem, Directory } = await import("@capacitor/filesystem");
  const rel = `Incoming/yt-${id}-${Date.now().toString(36)}.m4a`;
  let sub = null;
  try {
    sub = await Filesystem.addListener("progress", (p) => { if (p.contentLength > 0) onFrac?.(p.bytes / p.contentLength); });
  } catch {}
  try {
    const url = a.size ? `${a.url}&range=0-${a.size - 1}` : a.url;
    await timed(Filesystem.downloadFile({ url, path: rel, directory: Directory.Library, headers: { "User-Agent": a.ua }, recursive: true, progress: true }), 300000, "Downloading");
    const st = await Filesystem.stat({ path: rel, directory: Directory.Library });
    if (!st || st.size < 10000) throw new Error(`the download came back empty (${st?.size || 0} bytes)`);
    diag.log(`YouTube: downloaded ${Math.round(st.size / 1024)} KB`);
    return { rel, size: st.size };
  } finally { try { await sub?.remove(); } catch {} }
}

/**
 * Add everything a link points at. lib: the library; onProgress(fraction, text).
 * Returns { added, skipped, failed, firstError, title, playlist, songs }.
 */
export async function importLink(text, lib, onProgress) {
  if (!native) throw new Error("Adding from links works in the phone app");
  const link = parseLink(text);
  if (!link) throw new Error("That isn't a YouTube or YouTube Music link");
  diag.log(`YouTube: link → ${JSON.stringify(link)}`);
  onProgress?.(0, "Connecting to YouTube…");
  const { title, playlist, tracks } = await resolve(link);
  let added = 0, skipped = 0, failed = 0, firstError = "";
  const songs = [], order = [];
  for (let i = 0; i < tracks.length; i++) {
    const t = tracks[i];
    const base = i / tracks.length, span = 1 / tracks.length;
    onProgress?.(base, `${i + 1} of ${tracks.length}${t.title ? ` · ${t.title}` : ""}`);
    try {
      diag.step = `Finding the audio · ${t.title || t.id}`;
      const a = await audioFor(t.id);
      const tags = tidy({ title: t.title || a.meta.title, artist: t.artist || a.meta.artist, album: t.album });
      if (lib.existing({ ...tags })) { skipped++; order.push(lib.existing({ ...tags }).id); continue; }
      diag.step = `Downloading · ${tags.title}`;
      const file = await download(a, t.id, (f) => onProgress?.(base + span * 0.9 * f, `${i + 1} of ${tracks.length} · ${tags.title}`));
      let cover = null;
      try { cover = await getBlob(bigThumb(t.thumb || a.meta.thumb, t.id)); } catch {}
      if (!cover || cover.size < 2000) { try { cover = await getBlob(`https://i.ytimg.com/vi/${t.id}/hqdefault.jpg`); } catch {} }
      const r = await lib.addLocalFile(file.rel, file.size, "m4a", {
        ...tags, albumartist: "", track: t.track || 0, disc: 0, year: "", genre: "", composer: "", label: "", copyright: "", isrc: "", bpm: "",
        duration: t.duration || a.meta.duration || 0, codec: "AAC · from YouTube", source: `https://music.youtube.com/watch?v=${t.id}`,
      }, cover);
      r.skipped ? skipped++ : (added++, songs.push(r.song));
      order.push(r.song.id);
    } catch (e) {
      failed++;
      firstError ||= e.message || String(e);
      diag.log(`YouTube: couldn't add ${t.title || t.id}: ${e.message || e}`);
    }
  }
  onProgress?.(1, "Done");
  let plName = null;
  if (playlist && order.length) {
    plName = lib.uniquePlaylist(title, title);
    lib.meta.playlists[plName] = order;
    lib.saveMeta();
  }
  lib.rebuild();
  return { added, skipped, failed, firstError, title, playlist: plName, songs };
}
