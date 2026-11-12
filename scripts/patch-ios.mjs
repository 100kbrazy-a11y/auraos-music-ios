// Adds what the iPhone app needs on top of Capacitor's default project. Safe to run any number of times.
//  - keeps music playing in the background and on the lock screen
//  - shows the app's folder in the Files app (exported music packs land there)
//  - dark UI with a light status bar
//  - allows Subsonic / Navidrome servers on your home network (plain http)
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const app = path.join(root, "ios/App/App");
const plistPath = path.join(app, "Info.plist");
const delegatePath = path.join(app, "AppDelegate.swift");
if (!fs.existsSync(plistPath)) { console.error("No iOS project yet: run `npx cap add ios` first."); process.exit(1); }

// ---------------------------------------------------------------- Info.plist
let plist = fs.readFileSync(plistPath, "utf8");
const val = (v) => {
  if (v === true) return "<true/>";
  if (v === false) return "<false/>";
  if (Array.isArray(v)) return "<array>\n" + v.map((s) => `\t\t<string>${s}</string>`).join("\n") + "\n\t</array>";
  if (typeof v === "object") return "<dict>\n" + Object.entries(v).map(([k, x]) => `\t\t<key>${k}</key>\n\t\t${val(x)}`).join("\n") + "\n\t</dict>";
  return `<string>${v}</string>`;
};
function setKey(key, v) {
  const re = new RegExp(`\\t?<key>${key}</key>\\s*(<true/>|<false/>|<string>[^<]*</string>|<array>[\\s\\S]*?</array>|<dict>[\\s\\S]*?</dict>)\\n?`);
  const entry = `\t<key>${key}</key>\n\t${val(v)}\n`;
  plist = re.test(plist) ? plist.replace(re, entry) : plist.replace(/<\/dict>\s*<\/plist>\s*$/, `${entry}</dict>\n</plist>\n`);
}
setKey("CFBundleDisplayName", "AuraOS Music");
setKey("UIBackgroundModes", ["audio"]);
setKey("UIFileSharingEnabled", true);
setKey("LSSupportsOpeningDocumentsInPlace", true);
setKey("UIUserInterfaceStyle", "Dark");
setKey("UIViewControllerBasedStatusBarAppearance", true);
setKey("UIRequiredDeviceCapabilities", ["arm64"]);
setKey("ITSAppUsesNonExemptEncryption", false);
setKey("NSAppTransportSecurity", { NSAllowsArbitraryLoads: true, NSAllowsLocalNetworking: true });
setKey("NSLocalNetworkUsageDescription", "AuraOS Music connects to music servers on your home network, like Navidrome.");
setKey("NSPhotoLibraryUsageDescription", "Choose a picture to use as cover art.");
fs.writeFileSync(plistPath, plist);

// ---------------------------------------------------------------- AppDelegate.swift
let sw = fs.readFileSync(delegatePath, "utf8");
if (!sw.includes("AuraOS audio session")) {
  sw = sw.replace("import Capacitor\n", "import Capacitor\nimport AVFoundation\n");
  sw = sw.replace(
    /(didFinishLaunchingWithOptions[^{]*\{\n)/,
    `$1        // AuraOS audio session: play like a music app (keeps going when locked, ignores the silent switch,
        // shows on the lock screen and Control Center)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
`,
  );
  fs.writeFileSync(delegatePath, sw);
}
console.log("iOS project patched");
