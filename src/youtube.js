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
// With a proof-of-origin token (made below) YouTube Music's own web player identity works best; the others are fallbacks.
const CLIENTS = ["YTMUSIC", "MWEB", "WEB_EMBEDDED", "IOS", "ANDROID_VR", "VISIONOS", "TV_SIMPLY"];
const WEBBY = new Set(["YTMUSIC", "MWEB", "WEB_EMBEDDED", "WEB"]);

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
      Platform.load({ ...Platform.shim, eval: (data) => new Function(data.output)() });
      const yt = await timed(Innertube.create({ fetch: nativeFetch, cache: new UniversalCache(false), retrieve_player: true }), 45000, "Connecting to YouTube");
      diag.log("YouTube: connected");
      yt.session.on("auth", ({ credentials }) => saveCreds(credentials));
      yt.session.on("update-credentials", ({ credentials }) => saveCreds(credentials));
      const saved = savedCreds();
      if (saved) {
        try { await timed(yt.session.signIn(saved), 30000, "Signing in to YouTube"); yt.session.logged_in = false; diag.log("YouTube: signed in"); }
        catch (e) { diag.log(`YouTube: saved sign-in didn't work (${e.message || e})`); if (/invalid|revoked|denied|expired/i.test(String(e.message))) saveCreds(null); }
      }
      return { mod, yt };
    })();
  }
  try { return await ytp; } catch (e) { ytp = null; throw e; }
}

// ---- signing in (only if YouTube asks): the "enter a code at google.com/device" sign-in that TVs use.
// The app keeps the sign-in (not your password) on the phone; Sign Out in Settings removes it.
const AUTH_KEY = "auraos-yt-oauth";
function savedCreds() { try { return JSON.parse(localStorage.getItem(AUTH_KEY) || "null"); } catch { return null; } }
function saveCreds(c) { try { c ? localStorage.setItem(AUTH_KEY, JSON.stringify(c)) : localStorage.removeItem(AUTH_KEY); } catch {} }
export function ytSignedIn() { return !!savedCreds(); }
/** onCode({ user_code, verification_url }) is called with the code to enter; resolves once you've signed in. */
export async function ytSignIn(onCode) {
  const { yt } = await client();
  if (yt.session.oauth?.oauth2_tokens && ytSignedIn()) return;
  const pending = (d) => { diag.log("YouTube: sign-in code ready"); onCode?.(d); };
  yt.session.on("auth-pending", pending);
  try { await yt.session.signIn(); }
  finally { yt.session.off("auth-pending", pending); }
  saveCreds(yt.session.oauth?.oauth2_tokens);
  yt.session.logged_in = false;                          // (switched on only for the TV identity, see fetchAudio)
  diag.log("YouTube: signed in");
}
export async function ytSignOut() {
  try { const { yt } = await client(); if (yt.session.oauth?.oauth2_tokens) { yt.session.logged_in = true; await yt.session.signOut(); } } catch (e) { diag.log(`YouTube: sign-out: ${e.message || e}`); }
  saveCreds(null);
  ytp = null;                                            // start fresh, signed out
}

// ---- proof of origin: YouTube now only hands out audio to players that pass its "BotGuard" check. The app's web view
// is a real browser engine, so it runs YouTube's own check script and gets a token, then makes a token for each song.
let minterP = null;
async function poMinter() {
  if (!minterP) {
    minterP = (async () => {
      const { yt } = await client();
      const { BotGuardClient } = await import("bgutils-js/botguard");
      const { WebPoMinter } = await import("bgutils-js/webpo");
      const { buildURL, getHeaders } = await import("bgutils-js/utils");
      const { getChallenge } = await import("bgutils-js/botguard");
      diag.set("YouTube: running YouTube's player check…");
      // the check (a small program + the script that runs it): from YouTube itself, or else from Google's anti-abuse service
      let program = "", globalName = "", js = "", src = "";
      try {        // Google's anti-abuse service: the check YouTube's web player uses for these tokens (it must match the key sent below)
        const c = await timed(getChallenge({ requestKey: "O43z0dpjhgX20SCx4KAo", fetchFunction: nativeFetch }), 30000, "Getting Google's check");
        program = c.program; globalName = c.globalName;
        js = c.interpreterJavascript?.privateDoNotAccessOrElseSafeScriptWrappedValue || "";
        src = c.interpreterUrl?.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue || "";
        diag.log(`YouTube: check from Google (${globalName}, script ${js ? "inline" : src ? "url" : "missing"})`);
        if (!program || !globalName) throw new Error("incomplete");
      } catch (e) {
        diag.log(`YouTube: Google's check unavailable (${e.message || e}); asking YouTube`);
        const ch = await timed(yt.getAttestationChallenge("ENGAGEMENT_TYPE_UNBOUND"), 30000, "Getting YouTube's check");
        const bg = ch?.bg_challenge;
        if (!bg) throw new Error("no check in YouTube's answer");
        program = bg.program; globalName = bg.global_name; js = "";
        src = bg.interpreter_url?.private_do_not_access_or_else_trusted_resource_url_wrapped_value || "";
        diag.log(`YouTube: check from YouTube (${globalName}, script ${src ? "url" : "missing"})`);
      }
      if (!js && src) {
        if (src.startsWith("//")) src = "https:" + src;
        const r = await nativeFetch(src);
        js = await r.text();
        diag.log(`YouTube: check script ${Math.round(js.length / 1024)} KB (HTTP ${r.status})`);
      }
      if (!js || !program || !globalName) throw new Error("couldn't load YouTube's check");
      new Function(js)();
      if (!globalThis[globalName]) throw new Error("YouTube's check script didn't start");
      const bgc = await timed(BotGuardClient.create({ program, globalName, globalObject: globalThis }), 30000, "Starting YouTube's check");
      const signal = [];
      const answer = await timed(bgc.snapshot({ webPoSignalOutput: signal }), 30000, "Running YouTube's check");
      diag.log(`YouTube: check answered (${answer?.length || 0} chars)`);
      const r = await nativeFetch(buildURL("GenerateIT", true), { method: "POST", headers: getHeaders(), body: JSON.stringify(["O43z0dpjhgX20SCx4KAo", answer]) });
      const txt = await r.text();
      let arr = null;
      try { arr = JSON.parse(txt); } catch {}
      if (!Array.isArray(arr)) diag.log(`YouTube: unexpected check result (HTTP ${r.status}): ${txt.slice(0, 160)}`);
      const [integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken] = Array.isArray(arr) ? arr : [];
      if (!integrityToken) { diag.log(`YouTube: check result (HTTP ${r.status}): ${txt.slice(0, 300)}`); throw new Error(`YouTube didn't accept the check (${r.status})`); }
      const m = await WebPoMinter.create({ integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken }, signal);
      diag.log("YouTube: player check passed");
      setTimeout(() => { minterP = null; }, Math.max(300, (estimatedTtlSecs || 3600) - 300) * 1000);   // renew before it runs out
      return m;
    })();
  }
  try { return await minterP; } catch (e) { minterP = null; throw e; }
}
let tokenWhy = "";
async function tokenFor(id) {
  try { const t = await timed((await poMinter()).mintAsWebsafeString(id), 20000, "Making the song's token"); tokenWhy = ""; return t; }
  catch (e) { tokenWhy = e.message || String(e); diag.log(`YouTube: no proof-of-origin token (${tokenWhy}); trying without`); return ""; }
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
  // an automatic "mix" started from a song is endless: just that song. YouTube Music's own playlists (RDCLAK5uy_…) are real ones.
  if (/^RD/.test(list) && !/^RDCLAK5uy_/.test(list) && video) list = "";
  // an artist: music.youtube.com/channel/UC…  (also youtube.com/channel/UC…, /browse/UC…, and /@handle)
  const ch = u.pathname.match(/^\/(?:channel|browse)\/(UC[\w-]{20,})/);
  const hd = u.pathname.match(/^\/@([^/?#]+)/);
  const channel = !video && !list && ch ? ch[1] : "";
  const handle = !video && !list && !channel && hd ? decodeURIComponent(hd[1]) : "";
  return video || list || channel || handle ? { video, list, channel, handle, music: host === "music.youtube.com" } : null;
}
export const isArtistLink = (l) => !!(l && (l.channel || l.handle));

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

/** Download one song's audio: tries YouTube's app identities in turn until one of them gives a real m4a. */
async function fetchAudio(id, onFrac) {
  const { mod, yt } = await client();
  const reasons = [];
  const pot = await tokenFor(id);
  const signedIn = !!yt.session.oauth?.oauth2_tokens && ytSignedIn();
  // signed in: YouTube's TV identity carries the sign-in, so it goes first
  const order = signedIn ? ["TV", "TV_SIMPLY", ...CLIENTS.filter((c) => c !== "TV_SIMPLY")] : CLIENTS;
  for (const name of order) {
    if (!pot && WEBBY.has(name)) continue;                // these need the token
    yt.session.logged_in = signedIn && name.startsWith("TV");   // (the TV sign-in only works with the TV identities)
    try {
      const info = await timed(yt.getBasicInfo(id, pot ? { client: name, po_token: pot } : { client: name }), 30000, `Asking YouTube (${name})`);
      const ps = info.playability_status;
      if (ps && ps.status && ps.status !== "OK") { reasons.push(`${name}: ${ps.status}${ps.reason ? " – " + ps.reason : ""}`); diag.log("YouTube: " + reasons.at(-1)); continue; }
      let fmt;
      try { fmt = info.chooseFormat({ type: "audio", quality: "best", format: "mp4" }); }
      catch { reasons.push(`${name}: no m4a audio`); diag.log("YouTube: " + reasons.at(-1)); continue; }
      let url = await timed(fmt.decipher(yt.session.player), 30000, "Unscrambling the audio address");
      if (pot) { const u = new URL(url); u.searchParams.set("pot", pot); url = u.toString(); }
      const ua = mod.Constants?.CLIENTS?.[name]?.USER_AGENT || navigator.userAgent;
      const size = +fmt.content_length || 0;
      diag.log(`YouTube: ${name} gave an address for ${id} (${Math.round(size / 1024)} KB)`);
      const file = await download(url, size, ua, id, onFrac, WEBBY.has(name) ? (name === "YTMUSIC" ? "https://music.youtube.com" : "https://www.youtube.com") : "");
      yt.session.logged_in = false;
      const b = info.basic_info || {};
      return { ...file, client: name, meta: { title: b.title || "", artist: b.author || "", duration: b.duration || 0, thumb: lastThumb(b.thumbnail) } };
    } catch (e) { yt.session.logged_in = false; reasons.push(`${name}: ${String(e.message || e).replace(/https:\/\/\S+/, "(address)")}`); diag.log("YouTube: " + reasons.at(-1)); }
  }
  yt.session.logged_in = false;
  const first = String(reasons[0] || "").replace(/(Error downloading file):.*/, "$1");    // (not the whole address)
  const bot = reasons.some((r) => /not a bot|sign in|LOGIN_REQUIRED/i.test(r));
  throw new Error(`YouTube refused every way in (${first || "no answer"})` + (pot ? "" : ` · the player check failed: ${tokenWhy}`)
    + (bot && !signedIn ? " · signing in to YouTube (Settings › YouTube Account) may help" : ""));
}

/** Download to Library/Incoming natively (straight to a file; never through the web view).
 *  First the one-piece file download; if YouTube refuses that, the same audio in small pieces (like the Android app does),
 *  which also tells the log the real HTTP status. */
async function download(url, size, ua, id, onFrac, origin = "") {
  const { Filesystem, Directory } = await import("@capacitor/filesystem");
  const rel = `Incoming/yt-${id}-${Date.now().toString(36)}.m4a`;
  const headers = origin ? { "User-Agent": ua, Origin: origin, Referer: origin + "/" } : { "User-Agent": ua };
  const drop = async () => { try { await Filesystem.deleteFile({ path: rel, directory: Directory.Library }); } catch {} };
  const sizeOf = async () => { try { return (await Filesystem.stat({ path: rel, directory: Directory.Library })).size || 0; } catch { return 0; } };
  const ok = (got) => got >= 20000 && !(size && got < size * 0.9);
  let sub = null;
  try { sub = await Filesystem.addListener("progress", (p) => { if (p.contentLength > 0) onFrac?.(p.bytes / p.contentLength, p.bytes, p.contentLength); }); } catch {}
  let firstErr = "";
  try {
    try {                                                      // 1) the whole file in one go
      const full = size ? `${url}&range=0-${size - 1}` : url;
      const r = await timed(Filesystem.downloadFile({ url: full, path: rel, directory: Directory.Library, headers, recursive: true, progress: true }), 300000, "Downloading");
      const got = await sizeOf();
      diag.log(`YouTube: download finished · ${Math.round(got / 1024)} KB${r?.status ? " · HTTP " + r.status : ""}`);
      if (ok(got)) return { rel, size: got };
      firstErr = `refused (${got} bytes)`;
    } catch (e) { firstErr = String(e.message || e).replace(/https?:\/\/\S+/g, "(address)"); }
    await drop();
    diag.log(`YouTube: one-piece download failed (${firstErr}); trying it in pieces`);
    if (!size) throw new Error(firstErr);
    // 2) small pieces through the app's own networking: each one is a short, ordinary request
    const PIECE = 512 * 1024;
    let off = 0, status = 0;
    while (off < size) {
      const end = Math.min(size - 1, off + PIECE - 1);
      let r = null, last = "";
      for (let tryN = 0; tryN < 3 && !r; tryN++) {
        try {
          const x = await timed(CapacitorHttp.get({ url: `${url}&range=${off}-${end}`, headers, responseType: "blob", connectTimeout: 20000, readTimeout: 60000 }), 90000, "Downloading");
          status = x.status;
          if ((x.status === 200 || x.status === 206) && x.data && x.data.length > 100) r = x; else last = `HTTP ${x.status}`;
        } catch (e) { last = String(e.message || e).replace(/https?:\/\/\S+/g, "(address)"); }
        if (!r) await new Promise((res) => setTimeout(res, 400 * (tryN + 1)));
      }
      if (!r) { diag.log(`YouTube: piece ${off}-${end} refused (${last})`); await drop(); throw new Error(`YouTube refused the audio (${last || firstErr})`); }
      if (off === 0) await Filesystem.writeFile({ path: rel, directory: Directory.Library, data: r.data, recursive: true });
      else await Filesystem.appendFile({ path: rel, directory: Directory.Library, data: r.data });
      off = end + 1;
      onFrac?.(off / size, off, size);
    }
    const got = await sizeOf();
    diag.log(`YouTube: pieces finished · ${Math.round(got / 1024)} KB · HTTP ${status}`);
    if (!ok(got)) { await drop(); throw new Error(`download refused (${got} bytes)`); }
    return { rel, size: got };
  } finally { try { await sub?.remove(); } catch {} }
}

// ============================================================ adding songs (one list of tracks → the library)
/**
 * Download a list of tracks [{ id, title, artist, album, albumartist, year, duration, thumb, track }] into the library, one
 * after another. onProgress(fraction, text, { f, text } for the song in progress). opts: ctl.stop ends it early (what is
 * done stays); stopStreak: give up after that many failures in a row (default: 3 failures with nothing worked yet);
 * onOrder(ids): the songs so far in the list's own order (for playlists). Returns { added, skipped, failed, firstError, songs, order, stopped }.
 */
async function addTracks(tracks, lib, onProgress, opts = {}) {
  let added = 0, skipped = 0, failed = 0, firstError = "", streak = 0, stopped = false;
  const songs = [], order = [], covers = new Map();
  const mb = (n) => (n / 1048576).toFixed(1);
  for (let i = 0; i < tracks.length; i++) {
    if (opts.ctl?.stop) { stopped = true; break; }
    const t = tracks[i];
    const base = i / tracks.length, span = 1 / tracks.length;
    const head = `${i + 1} of ${tracks.length}${t.title ? ` · ${t.title}` : ""}`;
    let text = "Starting…", sf = null;
    const rep = (f, sub) => { if (sub !== undefined) text = sub; sf = f; onProgress?.(Math.min(0.995, base + span * (f ?? 0) * 0.9), head, { f: sf, text }); };
    try {
      diag.step = `Downloading · ${t.title || t.id}`;
      if (t.title) {
        const pre = tidy({ title: t.title, artist: t.artist, album: t.album });
        const had = lib.findSame({ ...pre, duration: t.duration || 0, id: t.id });
        if (had) { skipped++; streak = 0; order.push(had.id); opts.onOrder?.(order.slice()); continue; }
      }
      rep(0, "Asking YouTube…");
      const a = await fetchAudio(t.id, (f, got, total) => rep(0.1 + 0.8 * f, total ? `Downloading · ${mb(got)} of ${mb(total)} MB` : "Downloading…"));
      rep(0.95, "Saving to your library…");
      const tags = tidy({ title: t.title || a.meta.title, artist: t.artist || a.meta.artist, album: t.album });
      let cover = null;
      const url = bigThumb(t.thumb || a.meta.thumb, t.id);
      if (t.album && covers.has(url)) cover = covers.get(url);            // (every song on an album shares its cover)
      else {
        try { cover = await getBlob(url); } catch {}
        if (!cover || cover.size < 2000) { try { cover = await getBlob(`https://i.ytimg.com/vi/${t.id}/hqdefault.jpg`); } catch {} }
        if (t.album && cover) covers.set(url, cover);
      }
      const r = await lib.addLocalFile(a.rel, a.size, "m4a", {
        ...tags, albumartist: t.albumartist || "", track: t.track || 0, disc: 0, year: t.year ? String(t.year) : "", genre: "", composer: "", label: "", copyright: "", isrc: "", bpm: "",
        duration: t.duration || a.meta.duration || 0, codec: "AAC · from YouTube", source: `https://music.youtube.com/watch?v=${t.id}`,
      }, cover);
      r.skipped ? skipped++ : (added++, songs.push(r.song));
      streak = 0;
      order.push(r.song.id);
      opts.onOrder?.(order.slice());
    } catch (e) {
      failed++; streak++;
      firstError ||= e.message || String(e);
      diag.log(`YouTube: couldn't add ${t.title || t.id}: ${e.message || e}`);
      if (opts.stopStreak ? streak >= opts.stopStreak : failed >= 3 && !added && !skipped) {
        diag.log(`YouTube: ${opts.stopStreak || 3} failures in a row — stopping`);
        failed += tracks.length - i - 1; stopped = true; break;
      }
    }
  }
  onProgress?.(1, "Done");
  return { added, skipped, failed, firstError, songs, order, stopped };
}

/**
 * Add everything a link points at. lib: the library; onProgress(fraction, text, sub).
 * Returns { added, skipped, failed, firstError, title, playlist, songs }.
 */
export async function importLink(text, lib, onProgress) {
  if (!native) throw new Error("Adding from links works in the phone app");
  const link = parseLink(text);
  if (!link) throw new Error("That isn't a YouTube or YouTube Music link");
  if (isArtistLink(link)) throw new Error("That's an artist link — use readArtist / importArtist");
  diag.log(`YouTube: link → ${JSON.stringify(link)}`);
  onProgress?.(0, "Connecting to YouTube…");
  const { title, playlist, tracks } = await resolve(link);
  let plName = null;
  // a playlist / album link: the playlist is made as soon as the first song lands, in the list's own order
  const onOrder = (ids) => {
    if (!playlist || !ids.length) return;
    if (!plName) { plName = lib.uniquePlaylist(title, title); diag.log(`YouTube: playlist “${plName}”`); }
    lib.meta.playlists[plName] = ids;
    lib.saveMeta();
  };
  const { added, skipped, failed, firstError, songs } = await addTracks(tracks, lib, onProgress, { onOrder });
  lib.rebuild();
  return { added, skipped, failed, firstError, title, playlist: plName, songs };
}

// ============================================================ YouTube Music: search, albums, artists
const txt = (x) => {
  if (x == null) return "";
  if (typeof x === "string") return x;
  if (typeof x.text === "string") return x.text;
  const s = typeof x.toString === "function" ? x.toString() : "";
  return s && s !== "[object Object]" ? s : "";
};
const thumbOf = (t) => lastThumb(t?.contents || t?.thumbnails || t) || "";
const yearOf = (...xs) => { for (const x of xs) { const m = txt(x).match(/\b(19|20)\d{2}\b/); if (m) return m[0]; } return ""; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function trackOf(it, fallbackArtist, extra = {}) {
  const artists = (it.artists || it.authors || []).map((a) => a?.name).filter(Boolean);
  return { id: it.id || it.video_id, title: txt(it.title), artist: artists.join(", ") || fallbackArtist, album: it.album?.name || "",
    duration: it.duration?.seconds || 0, thumb: thumbOf(it.thumbnail), ...extra };
}

/** The albums / singles listed on an artist's page (the full list when YouTube Music offers one). */
async function listReleases(mod, yt, sections, onProgress) {
  const out = new Map();
  const add = (it, single) => {
    const id = it?.id || it?.endpoint?.payload?.browseId || "";
    if (!/^MPREb/.test(id) || out.has(id)) return;
    out.set(id, { id, title: txt(it.title), year: it.year || yearOf(it.subtitle, it.year), single, thumb: thumbOf(it.thumbnail) });
  };
  for (const sec of sections || []) {
    const title = txt(sec.header?.title ?? sec.title).toLowerCase();
    if (!/album|single|\bep\b/.test(title)) continue;
    const single = /single|\bep\b/.test(title) && !/album/.test(title);
    for (const it of sec.contents || []) add(it, single);
    const more = sec.header?.more_content?.endpoint || sec.endpoint;            // "More" → the complete list
    if (more?.call && mod.YTNodes?.MusicTwoRowItem) {
      try {
        onProgress?.(`Reading all ${single ? "singles" : "albums"}…`);
        const page = await timed(more.call(yt.actions || yt.session?.actions, { client: "YTMUSIC", parse: true }), 45000, "Reading the full list");
        for (const it of page?.contents_memo?.getType?.(mod.YTNodes.MusicTwoRowItem) || []) add(it, single);
      } catch (e) { diag.log(`YouTube: full ${title} list unavailable (${e.message || e})`); }
    }
  }
  return [...out.values()];
}

/** One YouTube Music album (browse id MPREb…): { title, artist, year, cover, tracks[] } with the album artist on every track. */
async function readAlbum(yt, id, fallbackArtist = "", rel = {}) {
  const al = await timed(yt.music.getAlbum(id), 45000, `Reading ${rel.title || "the album"}`);
  const hdr = al.header || {};
  const title = (txt(hdr.title) || rel.title || "Album").replace(/^(Album|Single|EP)\s*-\s*/i, "");
  const artist = fallbackArtist || (hdr.strapline_text_one ? txt(hdr.strapline_text_one) : "") ||
    (hdr.author?.name || "") || (txt(hdr.subtitle).split(/\s*•\s*/)[1] || "");
  const year = hdr.year || yearOf(hdr.subtitle, hdr.second_subtitle) || rel.year || "";
  const cover = thumbOf(hdr.thumbnails ?? hdr.thumbnail) || rel.thumb || "";
  let n = 0;
  const tracks = [];
  for (const it of al.contents || []) {
    if (!it?.id) continue;
    n++;
    tracks.push(trackOf(it, artist, { album: title, albumartist: artist, year, thumb: cover || thumbOf(it.thumbnail), track: parseInt(txt(it.index), 10) || n }));
  }
  return { title, artist, year, cover, tracks };
}

/** Download one album from YouTube Music search (it becomes an album in the library, not a playlist). */
export async function importAlbum(id, lib, onProgress, ctl = {}, hint = {}) {
  if (!native) throw new Error("Adding from YouTube works in the phone app");
  onProgress?.(0, "Reading the album…");
  const { yt } = await client();
  const al = await readAlbum(yt, id, hint.artist || "", hint);
  diag.log(`YouTube: album ${al.title} — ${al.tracks.length} songs`);
  const r = await addTracks(al.tracks, lib, onProgress, { ctl });
  lib.rebuild();
  return { ...r, title: al.title };
}

/**
 * Search YouTube Music. type: "song" | "album" | "playlist" | "artist".
 * Returns [{ kind, id, title, sub, thumb, duration, artist, album, year, channel }] (songs carry what's needed to download them).
 */
export async function searchMusic(q, type = "song") {
  if (!native) throw new Error("Searching YouTube Music works in the phone app");
  const { yt } = await client();
  const res = await timed(yt.music.search(q, { type }), 30000, "Searching YouTube Music");
  const items = [];
  for (const shelf of res.contents || []) for (const it of shelf?.contents || []) if (it?.type === "MusicResponsiveListItem" || it?.flex_columns) items.push(it);
  const names = (xs) => (xs || []).map((a) => a?.name).filter(Boolean).join(", ");
  const out = [];
  const seen = new Set();
  for (const it of items) {
    const thumb = thumbOf(it.thumbnail?.contents ?? it.thumbnails ?? it.thumbnail);
    let r = null;
    if (type === "song" && /^[\w-]{11}$/.test(it.id || "")) {
      const artist = names(it.artists || it.authors) || it.author?.name || "";
      r = { kind: "song", id: it.id, title: txt(it.title), artist, album: it.album?.name || "", duration: it.duration?.seconds || 0, thumb,
        sub: [artist, it.album?.name, it.duration?.text].filter(Boolean).join(" · ") };
    } else if (type === "album" && /^MPREb/.test(it.id || "")) {
      const artist = names(it.artists || it.authors) || it.author?.name || "";
      r = { kind: "album", id: it.id, title: txt(it.title), artist, year: it.year || "", thumb, sub: [txt(it.subtitle).split(/\s*•\s*/)[0] || "Album", artist, it.year].filter(Boolean).join(" · ") };
    } else if (type === "playlist" && it.id) {
      const id = String(it.id).replace(/^VL/, "");
      const by = it.author?.name || names(it.authors);
      r = { kind: "playlist", id, title: txt(it.title), thumb, sub: ["Playlist", by, it.item_count].filter(Boolean).join(" · ") };
    } else if (type === "artist" && /^UC/.test(it.id || "")) {
      r = { kind: "artist", id: it.id, channel: it.id, title: it.name || txt(it.title), thumb, sub: ["Artist", it.subscribers].filter(Boolean).join(" · ") };
    }
    if (r && r.title && !seen.has(r.kind + r.id)) { seen.add(r.kind + r.id); out.push(r); }
  }
  diag.log(`YouTube: search “${q}” (${type}) → ${out.length}`);
  return out;
}

/** Download a single song found by searchMusic (with what the search already told us, so no tag reading). */
export async function importSong(t, lib, onProgress) {
  if (!native) throw new Error("Adding from YouTube works in the phone app");
  const r = await addTracks([t], lib, onProgress, {});
  lib.rebuild();
  return r;
}

/** Read an artist link (no downloading yet): { channel, name, thumb, about, albums[], singles[], top[] } */
export async function readArtist(link, onProgress) {
  if (!native) throw new Error("Adding from links works in the phone app");
  const { mod, yt } = await client();
  let channel = link.channel;
  if (!channel && link.handle) {
    onProgress?.("Finding the artist…");
    try {
      const ep = await timed(yt.resolveURL(`https://www.youtube.com/@${link.handle}`), 30000, "Finding the channel");
      channel = ep?.payload?.browseId || "";
    } catch (e) { diag.log(`YouTube: couldn't resolve @${link.handle}: ${e.message || e}`); }
    if (!/^UC/.test(channel || "")) throw new Error("Couldn't find that channel — paste the artist's link from the YouTube Music app (Share › Copy link)");
  }
  onProgress?.("Reading the artist page…");
  let page;
  try { page = await timed(yt.music.getArtist(channel), 45000, "Reading the artist page"); }
  catch (e) { diag.log(`YouTube: getArtist failed: ${e.message || e}`); throw new Error("That doesn't look like a YouTube Music artist page"); }
  const hdr = page.header || {};
  const name = txt(hdr.title).replace(/\s*-\s*Topic$/i, "").trim();
  if (!name) throw new Error("Couldn't read the artist's name from that page");
  const sections = page.sections || [];
  const releases = await listReleases(mod, yt, sections, onProgress);
  const top = [];
  for (const sec of sections) {                 // "Top songs": a shelf of song rows (video ids are 11 characters)
    if (!/song/i.test(txt(sec.title ?? sec.header?.title))) continue;
    for (const it of sec.contents || []) if (/^[\w-]{11}$/.test(it?.id || "")) top.push(trackOf(it, name));
    if (top.length) break;
  }
  const byYear = (a, b) => String(a.year || "9999").localeCompare(String(b.year || "9999"));
  const r = { channel, name, thumb: thumbOf(hdr.thumbnail ?? hdr.thumbnails), albums: releases.filter((x) => !x.single).sort(byYear), singles: releases.filter((x) => x.single).sort(byYear), top };
  diag.log(`YouTube: artist “${name}” — ${r.albums.length} albums, ${r.singles.length} singles/EPs, ${top.length} top songs`);
  return r;
}

/**
 * Download from an artist read with readArtist. what: "all" (albums + singles/EPs), "albums" or "top".
 * ctl.stop = true ends it early. Returns { added, skipped, failed, firstError, songs, stopped, albums }.
 */
export async function importArtist(a, what, lib, onProgress, ctl = {}) {
  const { yt } = await client();
  const total = { added: 0, skipped: 0, failed: 0, firstError: "", songs: [], stopped: false, albums: 0 };
  const merge = (r) => { total.added += r.added; total.skipped += r.skipped; total.failed += r.failed; total.firstError ||= r.firstError; total.songs.push(...r.songs); total.stopped ||= r.stopped; };
  const opts = { ctl, stopStreak: 5 };
  if (what === "top") {
    onProgress?.(0, "Top songs");
    merge(await addTracks(a.top.map((t) => ({ ...t, albumartist: a.name })), lib, onProgress, opts));
  } else {
    const releases = [...a.albums, ...(what === "all" ? a.singles : [])];
    for (let i = 0; i < releases.length && !total.stopped && !ctl.stop; i++) {
      const rel = releases[i];
      const sub = (f, t, s2) => onProgress?.((i + f) / releases.length, `${rel.title || "Album"} · ${t}`, s2);
      sub(0, "reading…");
      let al;
      try { al = await readAlbum(yt, rel.id, a.name, rel); }
      catch (e) { diag.log(`YouTube: couldn't read ${rel.title}: ${e.message || e}`); total.failed++; total.firstError ||= `couldn't read ${rel.title}`; continue; }
      diag.log(`YouTube: ${al.title} (${al.year || "?"}) — ${al.tracks.length} songs`);
      merge(await addTracks(al.tracks, lib, sub, opts));
      total.albums++;
      lib.rebuild();
      await sleep(250);
    }
  }
  onProgress?.(1, "Done");
  lib.rebuild();
  return total;
}
