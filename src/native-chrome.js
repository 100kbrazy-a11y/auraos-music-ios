// The iPhone app's real Liquid Glass bubble, tabs and menus (drawn natively: ios-native/NativeChrome.swift).
// This side tells it what to show and hears back what was tapped or dragged. Anywhere else (Android, browsers)
// it stays off and the web versions are used.
import { Capacitor, registerPlugin } from "@capacitor/core";

const NC = registerPlugin("NativeChrome");
const SYMBOLS = { albums: "square.stack.fill", artists: "music.mic", songs: "music.note", playlists: "music.note.list", browse: "safari" };

export const nc = {
  on: false,
  last: {},
  async start(tabs, handlers) {
    if (Capacitor.getPlatform() !== "ios" || !Capacitor.isPluginAvailable("NativeChrome")) return false;
    try { await NC.start({ tabs: tabs.map((t) => ({ id: t.id, label: t.label, symbol: SYMBOLS[t.id] || "circle" })) }); }
    catch (e) { console.warn("native chrome unavailable", e); return false; }
    NC.addListener("event", (e) => handlers[e.type]?.(e));
    this.on = true;
    document.documentElement.classList.add("native-chrome");
    return true;
  },
  /** Only sends what changed. */
  update(o) {
    if (!this.on) return;
    const diff = {};
    for (const [k, v] of Object.entries(o)) if (this.last[k] !== v) { diff[k] = v; this.last[k] = v; }
    if (Object.keys(diff).length) NC.update(diff).catch(() => {});
  },
  hide() { if (!this.on) return; this.last.visible = false; NC.update({ visible: false }).catch(() => {}); },
  show(bounce) { if (!this.on) return; this.last.visible = true; NC.update({ visible: true, bounce: !!bounce }).catch(() => {}); },
  progress(pos, dur, playing) {
    if (this.on) NC.progress({ pos: pos || 0, dur: dur || 0, playing: !!playing }).catch(() => {});
  },
  tint(css) {
    if (!this.on || !css) return;
    const rgb = cssRgb(css);
    if (rgb) this.update({ r: rgb[0], g: rgb[1], b: rgb[2] });
  },
  /** Song artwork as a small JPEG for the bubble. */
  async art(key, url) {
    if (!this.on || this.last.artKey === key) return;
    let b64 = "";
    if (url) {
      try {
        const img = new Image();
        img.src = url;
        await img.decode();
        const c = document.createElement("canvas");
        c.width = c.height = 132;
        const s = Math.min(img.naturalWidth, img.naturalHeight);
        c.getContext("2d").drawImage(img, (img.naturalWidth - s) / 2, (img.naturalHeight - s) / 2, s, s, 0, 0, 132, 132);
        b64 = c.toDataURL("image/jpeg", 0.86).split(",")[1] || "";
      } catch {}
    }
    this.last.artKey = key;
    NC.update({ artKey: key, art: b64 }).catch(() => {});
  },
  /** iPhone: pick music in the Files browser. Resolves to File objects (copies the picker made for us). */
  async pickAudio() {
    const r = await NC.pickAudio();
    const out = [];
    for (const f of r?.files || []) {
      try {
        const res = await fetch(Capacitor.convertFileSrc(f.path));
        if (!res.ok) continue;
        const b = await res.blob();
        out.push(new File([b], f.name, { type: b.type && b.type !== "application/octet-stream" ? b.type : "" }));
      } catch (e) { console.warn("couldn't read", f.name, e); }
    }
    return out;
  },
  // ---- system menus and dialogs (glass on iOS 26)
  async actionSheet(title, message, items) {
    const r = await NC.actionSheet({ title, message, items });
    return r?.id ?? null;
  },
  async confirm(title, message, ok, destructive) {
    return !!(await NC.confirm({ title, message, ok, destructive }))?.ok;
  },
  async prompt(title, message, value, ok) {
    return (await NC.prompt({ title, message, value, ok }))?.value ?? null;
  },
};

const SYM = { trash: "trash", delete: "trash", remove: "minus.circle", play: "play.fill", next: "text.insert", queue: "text.append",
  playlist: "music.note.list", add: "plus", heart: "heart", heartOn: "heart.fill", edit: "pencil", album: "square.stack", artist: "music.mic",
  share: "square.and.arrow.up", info: "info.circle", search: "magnifyingglass", shuffle: "shuffle", download: "arrow.down.circle", radio: "dot.radiowaves.left.and.right" };
export const symbolFor = (icon) => SYM[icon] || null;

let probe;
function cssRgb(css) {
  probe ||= Object.assign(document.createElement("canvas"), { width: 1, height: 1 }).getContext("2d", { willReadFrequently: true });
  probe.clearRect(0, 0, 1, 1);
  probe.fillStyle = "#000";
  probe.fillStyle = css;
  probe.fillRect(0, 0, 1, 1);
  const d = probe.getImageData(0, 0, 1, 1).data;
  return [d[0], d[1], d[2]];
}
