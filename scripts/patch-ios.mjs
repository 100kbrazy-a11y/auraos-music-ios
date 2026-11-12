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
// ---------------------------------------------------------------- native Liquid Glass chrome (ios-native/NativeChrome.swift)
// Kept in AppDelegate.swift so no new files have to be registered in the Xcode project.
const native = fs.readFileSync(path.join(root, "ios-native/NativeChrome.swift"), "utf8").trim();
sw = fs.readFileSync(delegatePath, "utf8");
const B = "// ===== AuraOS native chrome (begin) =====", E = "// ===== AuraOS native chrome (end) =====";
const body = native.split("\n").filter((l) => !/^import (UIKit|Capacitor|WebKit)$/.test(l)).join("\n");
if (!sw.includes("import WebKit")) sw = sw.replace("import Capacitor\n", "import Capacitor\nimport WebKit\n");
const i = sw.indexOf(B), j = sw.indexOf(E);
sw = i >= 0 && j > i ? sw.slice(0, i) + body + sw.slice(j + E.length) : sw.trimEnd() + "\n\n" + body + "\n";
fs.writeFileSync(delegatePath, sw);

// the app's screen uses our view controller (it registers the native chrome plugin)
const sbPath = path.join(app, "Base.lproj/Main.storyboard");
let sb = fs.readFileSync(sbPath, "utf8");
sb = sb.replace(/customClass="CAPBridgeViewController" customModule="Capacitor"/, 'customClass="MainViewController" customModule="App" customModuleProvider="target"');
fs.writeFileSync(sbPath, sb);

// Xcode 26 builds for iOS 15 and newer
const pbxPath = path.join(root, "ios/App/App.xcodeproj/project.pbxproj");
fs.writeFileSync(pbxPath, fs.readFileSync(pbxPath, "utf8").replace(/IPHONEOS_DEPLOYMENT_TARGET = 1[0-4]\.0;/g, "IPHONEOS_DEPLOYMENT_TARGET = 15.0;"));
const podPath = path.join(root, "ios/App/Podfile");
let pod = fs.readFileSync(podPath, "utf8").replace(/platform :ios, '1[0-4]\.0'/, "platform :ios, '15.0'");
if (!pod.includes("AuraOS: pods target iOS 15")) {
  pod = pod.replace("assertDeploymentTarget(installer)", `assertDeploymentTarget(installer)
  # AuraOS: pods target iOS 15 (the oldest Xcode 26 supports)
  installer.pods_project.targets.each do |t|
    t.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' }
  end`);
}
fs.writeFileSync(podPath, pod);
console.log("iOS project patched");
