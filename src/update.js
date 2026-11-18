// In-app updates. iOS doesn't let an app replace itself, so this checks GitHub for a newer version, shows what's new,
// and hands the new build to SideStore (which installs it over this one and keeps your music, playlists and settings).
import { Capacitor, CapacitorHttp } from "@capacitor/core";
import releases from "./release.json";
import { diag } from "./diag.js";

const REPO = "100kbrazy-a11y/auraos-music-ios";
export const current = releases[0];
export const installURL = `sidestore://install?url=https://github.com/${REPO}/releases/latest/download/Strata-Music.ipa`;
export const ipaURL = `https://github.com/${REPO}/releases/latest/download/Strata-Music.ipa`;
const LAST = "strata-update-check";

const parts = (v) => String(v || "0").split(".").map((x) => parseInt(x, 10) || 0);
export function newer(a, b) {            // is version a newer than b?
  const x = parts(a), y = parts(b);
  for (let i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0); }
  return false;
}

/** Ask GitHub for the newest release list. Returns { latest, news[] (entries newer than this build, newest first) }. */
export async function check() {
  const url = `https://raw.githubusercontent.com/${REPO}/main/src/release.json?t=${Date.now()}`;
  let list;
  if (Capacitor.isNativePlatform()) {
    const r = await CapacitorHttp.get({ url, headers: { "Cache-Control": "no-cache" }, responseType: "json", connectTimeout: 15000, readTimeout: 20000 });
    if (r.status !== 200) throw new Error(`GitHub answered ${r.status}`);
    list = typeof r.data === "string" ? JSON.parse(r.data) : r.data;
  } else {
    const r = await fetch(url, { cache: "no-store" });
    if (!r.ok) throw new Error(`GitHub answered ${r.status}`);
    list = await r.json();
  }
  if (!Array.isArray(list) || !list.length) throw new Error("Couldn't read the release list");
  try { localStorage.setItem(LAST, String(Date.now())); } catch {}
  const news = list.filter((e) => newer(e.version, current.version));
  diag.log(`Update: this is ${current.version}, newest is ${list[0].version}`);
  return { latest: list[0], news };
}
/** true if it's been a day since the last check (for the quiet check at launch) */
export function due() { try { return Date.now() - (+localStorage.getItem(LAST) || 0) > 864e5; } catch { return true; } }
export const notesText = (e) => `${e.name} · ${e.version}\n` + (e.notes || []).map((n) => `• ${n}`).join("\n");

/** open the new build in SideStore (or the plain download link as a fallback) */
export async function install() {
  try { const { App } = await import("@capacitor/app"); await App.openUrl({ url: installURL }); return; } catch (e) { diag.log("Update: openUrl: " + (e.message || e)); }
  try { location.href = installURL; } catch { window.open(ipaURL, "_blank"); }
}
