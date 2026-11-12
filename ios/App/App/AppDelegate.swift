import UIKit
import Capacitor
import WebKit
import AVFoundation

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // AuraOS audio session: play like a music app (keeps going when locked, ignores the silent switch,
        // shows on the lock screen and Control Center)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}

// ===== AuraOS native chrome (begin) =====
// Real iOS 26 Liquid Glass for the parts of the app that float over everything: the media bar + tabs bubble
// (upright), the tab pill + media bubble (sideways), and the song menus / dialogs (system alerts are glass on iOS 26).
// The web screens keep running underneath and tell this what to show; taps, swipes and drags here are sent back.

import UniformTypeIdentifiers

class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(NativeChromePlugin())
    }
}

@objc(NativeChromePlugin)
public class NativeChromePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativeChromePlugin"
    public let jsName = "NativeChrome"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progress", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "actionSheet", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "confirm", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "prompt", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickAudio", returnType: CAPPluginReturnPromise),
    ]
    var chrome: GlassChrome?
    let picker = AudioPicker()

    func send(_ type: String, _ extra: [String: Any] = [:]) {
        var data = extra
        data["type"] = type
        notifyListeners("event", data: data)
    }

    @objc func start(_ call: CAPPluginCall) {
        let tabs: [[String: String]] = (call.getArray("tabs") ?? []).compactMap { item in
            guard let o = item as? JSObject else { return nil }
            return ["id": (o["id"] as? String) ?? "", "label": (o["label"] as? String) ?? "", "symbol": (o["symbol"] as? String) ?? "circle"]
        }
        DispatchQueue.main.async {
            guard let host = self.bridge?.viewController?.view else { call.reject("no view"); return }
            if self.chrome == nil { self.chrome = GlassChrome(host: host, tabs: tabs, plugin: self) }
            call.resolve(["glass": GlassChrome.hasGlass])
        }
    }

    @objc func update(_ call: CAPPluginCall) {
        var s: [String: Any] = [:]
        for k in ["tab", "title", "artist", "art", "artKey"] { if let v = call.getString(k) { s[k] = v } }
        for k in ["song", "playing", "tucked", "pinned", "visible", "bounce"] { if let v = call.getBool(k) { s[k] = v } }
        for k in ["r", "g", "b"] { if let v = call.getDouble(k) { s[k] = v } }
        DispatchQueue.main.async { self.chrome?.apply(s) }
        call.resolve()
    }

    @objc func progress(_ call: CAPPluginCall) {
        let pos = call.getDouble("pos") ?? 0, dur = call.getDouble("dur") ?? 0, playing = call.getBool("playing") ?? false
        DispatchQueue.main.async { self.chrome?.setProgress(pos: pos, dur: dur, playing: playing) }
        call.resolve()
    }

    // ---------------------------------------------------------------- system (glass) menus and dialogs
    private func present(_ ac: UIAlertController) {
        guard let vc = bridge?.viewController else { return }
        if let pop = ac.popoverPresentationController {           // iPad: show it in the middle
            pop.sourceView = vc.view
            pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        var top: UIViewController = vc
        while let p = top.presentedViewController { top = p }
        top.present(ac, animated: true)
    }

    @objc func actionSheet(_ call: CAPPluginCall) {
        let title = call.getString("title"), message = call.getString("message")
        let items = call.getArray("items") ?? []
        DispatchQueue.main.async {
            let ac = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
            for item in items {
                guard let o = item as? JSObject, let id = o["id"] as? String else { continue }
                let label = (o["label"] as? String) ?? id
                let destructive = (o["destructive"] as? Bool) ?? false
                let action = UIAlertAction(title: label, style: destructive ? .destructive : .default) { _ in call.resolve(["id": id]) }
                if let sym = o["symbol"] as? String, let img = UIImage(systemName: sym) { action.setValue(img, forKey: "image") }
                ac.addAction(action)
            }
            ac.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in call.resolve([:]) })
            self.present(ac)
        }
    }

    @objc func confirm(_ call: CAPPluginCall) {
        let title = call.getString("title"), message = call.getString("message")
        let ok = call.getString("ok") ?? "OK", destructive = call.getBool("destructive") ?? false
        DispatchQueue.main.async {
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in call.resolve(["ok": false]) })
            ac.addAction(UIAlertAction(title: ok, style: destructive ? .destructive : .default) { _ in call.resolve(["ok": true]) })
            self.present(ac)
        }
    }

    @objc func prompt(_ call: CAPPluginCall) {
        let title = call.getString("title"), message = call.getString("message")
        let value = call.getString("value") ?? "", ok = call.getString("ok") ?? "OK"
        DispatchQueue.main.async {
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            ac.addTextField { tf in tf.text = value; tf.clearButtonMode = .whileEditing; tf.autocapitalizationType = .sentences }
            ac.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in call.resolve([:]) })
            ac.addAction(UIAlertAction(title: ok, style: .default) { _ in
                let v = (ac.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                call.resolve(v.isEmpty ? [:] : ["value": v])
            })
            self.present(ac)
        }
    }
}

extension NativeChromePlugin {
    /// Apple's Files browser, showing only music files (the web file picker offers the camera and Photos instead).
    @objc func pickAudio(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            var types: [UTType] = [.audio]
            for ext in ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "alac", "caf"] {
                if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) }
            }
            let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            vc.allowsMultipleSelection = true
            self.picker.call = call
            vc.delegate = self.picker
            guard let host = self.bridge?.viewController else { call.reject("no view"); return }
            var top: UIViewController = host
            while let p = top.presentedViewController { top = p }
            top.present(vc, animated: true)
        }
    }
}

final class AudioPicker: NSObject, UIDocumentPickerDelegate {
    var call: CAPPluginCall?
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let files: [[String: String]] = urls.map { ["name": $0.lastPathComponent, "path": $0.absoluteString] }
        call?.resolve(["files": files])
        call = nil
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        call?.resolve(["files": [[String: String]]()])
        call = nil
    }
}

/// Lets touches through to the web view everywhere except on the glass.
final class PassthroughView: UIView {
    var onLayout: (() -> Void)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
}

final class GlassChrome: NSObject, UIGestureRecognizerDelegate {
    static var hasGlass: Bool { if #available(iOS 26.0, *) { return true }; return false }

    weak var plugin: NativeChromePlugin?
    let root = PassthroughView()
    let tabs: [[String: String]]

    // the glass
    let dockGlass: UIVisualEffectView      // upright: media bar + tabs in one bubble
    let pillGlass: UIVisualEffectView      // sideways: the tab pill
    let miniGlass: UIVisualEffectView      // sideways: the media bubble

    // media bar
    let miniRow = UIView()
    let art = UIImageView()
    let artClip = UIView()
    let titleLabel = UILabel()
    let artistLabel = UILabel()
    let textBox = UIView()
    let prevButton = UIButton(type: .system)
    let playButton = UIButton(type: .system)
    let nextButton = UIButton(type: .system)
    let track = UIView()
    let fill = UIView()
    let divider = UIView()

    // tabs
    let tabsRow = UIView()
    var tabButtons: [UIView] = []
    var tabIcons: [UIImageView] = []
    var tabLabels: [UILabel] = []
    let lens = UIView()

    // state
    var hasSong = false, playing = false, tucked = false, pinned = false, visible = true
    var tab = "albums"
    var tint = UIColor(red: 1, green: 0.48, blue: 0.63, alpha: 1)
    var artKey = ""
    var pos = 0.0, dur = 0.0, progAt = CACurrentMediaTime()
    var link: CADisplayLink?
    var dragTab = false, panMode = 0          // 0 undecided, 1 sideways swipe, 2 drag up to open
    var lastPanY: CGFloat = 0, lastPanT = CACurrentMediaTime(), panV: CGFloat = 0
    let haptic = UISelectionFeedbackGenerator()

    var landscape: Bool { let b = root.bounds; return b.width > b.height && b.width >= 640 }

    init(host: UIView, tabs: [[String: String]], plugin: NativeChromePlugin) {
        self.tabs = tabs
        self.plugin = plugin
        dockGlass = GlassChrome.glass()
        pillGlass = GlassChrome.glass()
        miniGlass = GlassChrome.glass()
        super.init()
        root.frame = host.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.backgroundColor = .clear
        host.addSubview(root)
        for g in [dockGlass, pillGlass, miniGlass] { root.addSubview(g) }
        buildMini()
        buildTabs()
        root.onLayout = { [weak self] in self?.layout(animated: false) }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        retint()
        layout(animated: false)
    }

    /// bounds + center rather than frame: these views get scaled while they appear and disappear
    func put(_ v: UIView, _ r: CGRect) {
        v.bounds = CGRect(origin: .zero, size: r.size)
        v.center = CGPoint(x: r.midX, y: r.midY)
    }

    static func glass() -> UIVisualEffectView {
        let v = UIVisualEffectView(effect: nil)
        v.clipsToBounds = true
        v.layer.cornerCurve = .continuous
        return v
    }

    func glassEffect(interactive: Bool) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect(style: .regular)
            g.isInteractive = interactive
            g.tintColor = tint.withAlphaComponent(0.22)      // a little of the song's colour
            return g
        }
        return UIBlurEffect(style: .systemThinMaterialDark)
    }

    func retint() {
        dockGlass.effect = glassEffect(interactive: true)
        pillGlass.effect = glassEffect(interactive: true)
        miniGlass.effect = glassEffect(interactive: true)
        fill.backgroundColor = tint
        for (i, t) in tabs.enumerated() where i < tabIcons.count {
            let on = t["id"] == tab
            tabIcons[i].tintColor = on ? tint : UIColor.white.withAlphaComponent(0.72)
            tabLabels[i].textColor = on ? .white : UIColor.white.withAlphaComponent(0.72)
        }
    }

    // ---------------------------------------------------------------- building
    func symbolButton(_ b: UIButton, _ name: String, size: CGFloat, glass: Bool) {
        let img = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        if glass, #available(iOS 26.0, *) {
            var c = UIButton.Configuration.glass()
            c.image = img
            c.baseForegroundColor = .white
            c.cornerStyle = .capsule
            b.configuration = c
        } else {
            var c = UIButton.Configuration.plain()
            c.image = img
            c.baseForegroundColor = .white
            b.configuration = c
        }
    }

    func buildMini() {
        artClip.clipsToBounds = true
        artClip.layer.cornerRadius = 10
        artClip.layer.cornerCurve = .continuous
        artClip.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        art.contentMode = .scaleAspectFill
        artClip.addSubview(art)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        artistLabel.font = .systemFont(ofSize: 13)
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        textBox.addSubview(titleLabel)
        textBox.addSubview(artistLabel)
        symbolButton(prevButton, "backward.fill", size: 17, glass: false)
        symbolButton(playButton, "play.fill", size: 19, glass: true)
        symbolButton(nextButton, "forward.fill", size: 17, glass: false)
        prevButton.addTarget(self, action: #selector(prevTap), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playTap), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTap), for: .touchUpInside)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        track.layer.cornerRadius = 1
        track.clipsToBounds = true
        fill.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSubview(fill)
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        for v in [artClip, textBox, prevButton, playButton, nextButton, track] { miniRow.addSubview(v) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(miniTap))
        tap.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(miniPan(_:)))
        pan.delegate = self
        miniRow.addGestureRecognizer(tap)
        miniRow.addGestureRecognizer(pan)
    }

    func buildTabs() {
        lens.isUserInteractionEnabled = false
        lens.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        lens.layer.cornerCurve = .continuous
        lens.layer.borderWidth = 0.5
        lens.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        tabsRow.addSubview(lens)
        for t in tabs {
            let b = UIView()
            let icon = UIImageView(image: UIImage(systemName: t["symbol"] ?? "circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)))
            icon.contentMode = .center
            let label = UILabel()
            label.text = t["label"]
            label.font = .systemFont(ofSize: 10.5, weight: .semibold)
            label.textAlignment = .center
            b.addSubview(icon)
            b.addSubview(label)
            b.isUserInteractionEnabled = false
            tabsRow.addSubview(b)
            tabButtons.append(b)
            tabIcons.append(icon)
            tabLabels.append(label)
        }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(tabPress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 10_000
        tabsRow.addGestureRecognizer(press)
    }

    // ---------------------------------------------------------------- layout
    func layout(animated: Bool) {
        let b = root.bounds
        guard b.width > 0 else { return }
        let safe = root.safeAreaInsets
        let land = landscape
        let apply = {
            if land { self.layoutSideways(b, safe) } else { self.layoutUpright(b, safe) }
            let show: CGFloat = self.visible ? 1 : 0
            self.dockGlass.alpha = land ? 0 : show
            self.pillGlass.alpha = land ? show : 0
            self.miniGlass.alpha = land && self.hasSong ? show : 0
        }
        if animated {
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else {
            UIView.performWithoutAnimation(apply)
        }
        placeLens(animated: animated)
        updateFill()
    }

    func layoutUpright(_ b: CGRect, _ safe: UIEdgeInsets) {
        if miniRow.superview !== dockGlass.contentView { dockGlass.contentView.addSubview(miniRow) }
        if divider.superview !== dockGlass.contentView { dockGlass.contentView.addSubview(divider) }
        if tabsRow.superview !== dockGlass.contentView { dockGlass.contentView.addSubview(tabsRow) }
        let miniH: CGFloat = hasSong ? 62 : 0, tabsH: CGFloat = 62
        let w = b.width - 24, h = miniH + tabsH
        put(dockGlass, CGRect(x: 12, y: b.height - safe.bottom - 10 - h, width: w, height: h))
        dockGlass.layer.cornerRadius = 26
        miniRow.frame = CGRect(x: 0, y: 0, width: w, height: 62)
        miniRow.alpha = hasSong ? 1 : 0
        divider.frame = CGRect(x: 0, y: miniH, width: w, height: hasSong ? 0.5 : 0)
        tabsRow.frame = CGRect(x: 0, y: miniH, width: w, height: tabsH)
        // media bar: cover, title, play/pause, next
        artClip.transform = .identity
        artClip.frame = CGRect(x: 10, y: 9, width: 44, height: 44)
        artClip.layer.cornerRadius = 10
        art.frame = artClip.bounds
        prevButton.alpha = 0
        nextButton.frame = CGRect(x: w - 50, y: 9, width: 44, height: 44)
        playButton.frame = CGRect(x: w - 100, y: 10, width: 42, height: 42)
        for v in [textBox, playButton, nextButton, track] { v.alpha = 1 }
        textBox.frame = CGRect(x: 66, y: 12, width: w - 66 - 108, height: 40)
        titleLabel.frame = CGRect(x: 0, y: 0, width: textBox.bounds.width, height: 20)
        artistLabel.frame = CGRect(x: 0, y: 21, width: textBox.bounds.width, height: 18)
        track.frame = CGRect(x: 14, y: 60, width: w - 28, height: 2)
        // tabs: side by side
        let n = CGFloat(max(1, tabButtons.count)), tw = (w - 8) / n
        for (i, tb) in tabButtons.enumerated() {
            tb.frame = CGRect(x: 4 + CGFloat(i) * tw, y: 0, width: tw, height: tabsH)
            tabIcons[i].frame = CGRect(x: 0, y: 9, width: tw, height: 28)
            tabLabels[i].frame = CGRect(x: 0, y: 37, width: tw, height: 16)
        }
    }

    func layoutSideways(_ b: CGRect, _ safe: UIEdgeInsets) {
        if tabsRow.superview !== pillGlass.contentView { pillGlass.contentView.addSubview(tabsRow) }
        if miniRow.superview !== miniGlass.contentView { miniGlass.contentView.addSubview(miniRow) }
        divider.removeFromSuperview()
        // the tab pill: 68 wide, centred on the right; shorter and a little higher when the media bar tucks under it
        let n = CGFloat(max(1, tabButtons.count))
        let btn: CGFloat = tucked ? 51 : 60
        let pillH = n * btn + (n - 1) * 2 + 8
        let pillX = b.width - safe.right - 12 - 68
        let pillY = b.height / 2 - pillH / 2 - (tucked ? 40 : 0)
        put(pillGlass, CGRect(x: pillX, y: pillY, width: 68, height: pillH))
        pillGlass.layer.cornerRadius = 34
        tabsRow.frame = pillGlass.bounds
        for (i, tb) in tabButtons.enumerated() {
            tb.frame = CGRect(x: 4, y: 4 + CGFloat(i) * (btn + 2), width: 60, height: btn)
            tabIcons[i].frame = CGRect(x: 0, y: btn / 2 - 20, width: 60, height: 26)
            tabLabels[i].frame = CGRect(x: 0, y: btn / 2 + 6, width: 60, height: 13)
            tabLabels[i].font = .systemFont(ofSize: 9.5, weight: .semibold)
        }
        // the media bubble along the bottom, or wrapped to its cover and tucked in under the pill
        let left = safe.left + 12
        let fullW = pillX - 12 - left
        let fullH: CGFloat = 66
        let bottom = b.height - safe.bottom - 10
        if tucked {
            let tuckH: CGFloat = 86
            let y = min(b.height / 2 - 40 + pillH / 2 + 8, b.height - 6 - tuckH)
            put(miniGlass, CGRect(x: pillX, y: y, width: 68, height: tuckH))
            miniGlass.layer.cornerRadius = 22
            miniRow.frame = miniGlass.bounds
            let zoom: CGFloat = pinned ? 1 : 1.42             // zoomed in to fill the bubble (corners cropped by it)
            artClip.transform = .identity
            artClip.frame = CGRect(x: 10, y: 9, width: 48, height: 48)
            artClip.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            artClip.layer.cornerRadius = pinned ? 10 : 0
            art.frame = artClip.bounds
            for v in [textBox, prevButton, playButton, nextButton] { v.alpha = 0 }
            track.alpha = 1
            track.frame = CGRect(x: 10, y: 78, width: 48, height: 2)
        } else {
            put(miniGlass, CGRect(x: left, y: bottom - fullH, width: fullW, height: fullH))
            miniGlass.layer.cornerRadius = 22
            miniRow.frame = miniGlass.bounds
            artClip.transform = .identity
            artClip.frame = CGRect(x: 9, y: 9, width: 48, height: 48)
            artClip.layer.cornerRadius = 10
            art.frame = artClip.bounds
            for v in [textBox, prevButton, playButton, nextButton, track] { v.alpha = 1 }
            nextButton.frame = CGRect(x: fullW - 52, y: 11, width: 44, height: 44)
            playButton.frame = CGRect(x: fullW - 104, y: 10, width: 46, height: 46)
            prevButton.frame = CGRect(x: fullW - 152, y: 11, width: 44, height: 44)
            textBox.frame = CGRect(x: 70, y: 13, width: max(0, fullW - 70 - 160), height: 40)
            titleLabel.frame = CGRect(x: 0, y: 0, width: textBox.bounds.width, height: 20)
            artistLabel.frame = CGRect(x: 0, y: 21, width: textBox.bounds.width, height: 18)
            track.frame = CGRect(x: 14, y: fullH - 3, width: fullW - 28, height: 2)
        }
    }

    func tabFrame(_ id: String) -> CGRect? {
        guard let i = tabs.firstIndex(where: { $0["id"] == id }), i < tabButtons.count else { return nil }
        return tabButtons[i].frame
    }

    func lensFrame(for f: CGRect) -> CGRect {
        if landscape { let s = min(f.width, f.height); return CGRect(x: f.midX - s / 2, y: f.midY - s / 2, width: s, height: s) }   // a round bubble
        return f.insetBy(dx: 4, dy: 5)
    }

    func placeLens(animated: Bool) {
        guard let f = tabFrame(tab) else { lens.alpha = 0; return }
        let target = lensFrame(for: f)
        let go = {
            self.lens.bounds = CGRect(origin: .zero, size: target.size)
            self.lens.center = CGPoint(x: target.midX, y: target.midY)
            self.lens.layer.cornerRadius = min(target.width, target.height) / 2
            self.lens.alpha = 1
        }
        if animated {
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.68, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState], animations: go)
        } else { UIView.performWithoutAnimation(go) }
    }

    // ---------------------------------------------------------------- state from the web side
    func apply(_ s: [String: Any]) {
        var relayout = false, retab = false
        if let r = s["r"] as? Double, let g = s["g"] as? Double, let bl = s["b"] as? Double {
            let c = UIColor(red: CGFloat(r / 255), green: CGFloat(g / 255), blue: CGFloat(bl / 255), alpha: 1)
            if !c.isEqual(tint) { tint = c; UIView.animate(withDuration: 0.5) { self.retint() } }
        }
        if let v = s["song"] as? Bool, v != hasSong { hasSong = v; relayout = true }
        if let t = s["title"] as? String { titleLabel.text = t }
        if let a = s["artist"] as? String { artistLabel.text = a }
        if let key = s["artKey"] as? String, key != artKey {
            artKey = key
            if let b64 = s["art"] as? String, let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                UIView.transition(with: art, duration: 0.25, options: .transitionCrossDissolve, animations: { self.art.image = img })
            } else { art.image = nil }
        }
        if let p = s["playing"] as? Bool, p != playing {
            playing = p
            symbolButton(playButton, p ? "pause.fill" : "play.fill", size: 19, glass: true)
        }
        if let t = s["tab"] as? String, t != tab { tab = t; retab = true }
        if let v = s["tucked"] as? Bool, v != tucked { tucked = v; relayout = true }
        if let v = s["pinned"] as? Bool, v != pinned { pinned = v; relayout = true }
        if let v = s["visible"] as? Bool, v != visible {
            visible = v
            if v { showChrome(bounce: (s["bounce"] as? Bool) ?? false) } else { hideChrome() }
        }
        if retab { retint(); placeLens(animated: true) }
        if relayout { layout(animated: true) }
    }

    var chromeViews: [UIView] { landscape ? [pillGlass, miniGlass] : [dockGlass] }

    func hideChrome() {
        UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState]) {
            for v in self.chromeViews { v.alpha = 0; v.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
        }
    }

    func showChrome(bounce: Bool) {
        layout(animated: false)
        for v in chromeViews { v.transform = bounce ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity }
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.6, options: [.allowUserInteraction, .beginFromCurrentState]) {
            for v in self.chromeViews { v.transform = .identity }
        }
    }

    func setProgress(pos: Double, dur: Double, playing: Bool) {
        self.pos = pos; self.dur = dur; self.playing = playing; progAt = CACurrentMediaTime()
        updateFill()
    }

    @objc func tick() {
        if playing && visible { updateFill() }
    }

    func updateFill() {
        let now = playing ? pos + (CACurrentMediaTime() - progAt) : pos
        let f = dur > 0 ? min(1, max(0, now / dur)) : 0
        fill.transform = .identity
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width, height: track.bounds.height)
        fill.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.layer.position = CGPoint(x: 0, y: track.bounds.height / 2)
        fill.transform = CGAffineTransform(scaleX: CGFloat(max(0.0001, f)), y: 1)
    }

    // ---------------------------------------------------------------- gestures
    @objc func prevTap() { plugin?.send("prev") }
    @objc func playTap() { plugin?.send("toggle") }
    @objc func nextTap() { plugin?.send("next") }
    @objc func miniTap() { plugin?.send("open") }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is UIButton || touch.view?.superview is UIButton { return false }
        return true
    }

    var slideViews: [UIView] { [artClip, textBox] }

    @objc func miniPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: root)
        switch g.state {
        case .began:
            panMode = 0
            lastPanY = t.y; lastPanT = CACurrentMediaTime(); panV = 0
        case .changed:
            if panMode == 0 && (abs(t.x) > 8 || abs(t.y) > 8) {
                if t.y < -8 && abs(t.y) > abs(t.x) * 1.2 && hasSong { panMode = 2; plugin?.send("dragStart") }
                else if abs(t.x) > abs(t.y) { panMode = 1 }
            }
            if panMode == 2 {
                let now = CACurrentMediaTime()
                panV = (t.y - lastPanY) / CGFloat(max(0.001, now - lastPanT)) / 1000     // px per ms, like the web side
                lastPanY = t.y; lastPanT = now
                plugin?.send("drag", ["dy": Double(t.y)])
            } else if panMode == 1 && !tucked {
                for v in slideViews { v.transform = CGAffineTransform(translationX: t.x * 0.7, y: 0) }
                textBox.alpha = 1 - min(0.7, abs(t.x) / 220)
            }
        case .ended, .cancelled, .failed:
            if panMode == 2 {
                plugin?.send("dragEnd", ["v": Double(panV)])
            } else if panMode == 1 {
                let commit = g.state == .ended && abs(t.x) > 60
                let dir: CGFloat = t.x < 0 ? 1 : -1
                if commit && !tucked {
                    let w = miniRow.bounds.width
                    UIView.animate(withDuration: 0.17, delay: 0, options: [.curveEaseIn], animations: {
                        for v in self.slideViews { v.transform = CGAffineTransform(translationX: -dir * w * 0.7, y: 0) }
                        self.textBox.alpha = 0
                    }, completion: { _ in
                        self.plugin?.send(dir > 0 ? "next" : "prev")
                        for v in self.slideViews { v.transform = CGAffineTransform(translationX: dir * 70, y: 0) }
                        UIView.animate(withDuration: 0.3, delay: 0.12, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.allowUserInteraction], animations: {
                            for v in self.slideViews { v.transform = .identity }
                            self.textBox.alpha = 1
                        })
                    })
                } else {
                    if commit { plugin?.send(dir > 0 ? "next" : "prev") }
                    UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction], animations: {
                        for v in self.slideViews { v.transform = .identity }
                        self.textBox.alpha = 1
                    })
                }
                if tucked { layout(animated: true) }
            }
            panMode = 0
        default: break
        }
    }

    /// Touch the tabs: the bubble jumps to your finger, follows it, and the tab under it opens when you let go.
    @objc func tabPress(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: tabsRow)
        let land = landscape
        func nearest() -> Int {
            var best = 0, bestD = CGFloat.greatestFiniteMagnitude
            for (i, b) in tabButtons.enumerated() {
                let d = land ? abs(b.frame.midY - p.y) : abs(b.frame.midX - p.x)
                if d < bestD { bestD = d; best = i }
            }
            return best
        }
        switch g.state {
        case .began, .changed:
            let i = nearest()
            guard i < tabButtons.count else { return }
            let f = lensFrame(for: tabButtons[i].frame)
            var c = CGPoint(x: f.midX, y: f.midY)
            if land { c.y = min(max(p.y, tabButtons.first!.frame.midY), tabButtons.last!.frame.midY) }
            else { c.x = min(max(p.x, tabButtons.first!.frame.midX), tabButtons.last!.frame.midX) }
            if g.state == .began { haptic.prepare() }
            if (lens.tag != i) { lens.tag = i; haptic.selectionChanged() }
            UIView.animate(withDuration: g.state == .began ? 0.35 : 0.12, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.lens.bounds = CGRect(origin: .zero, size: f.size)
                self.lens.center = c
                self.lens.layer.cornerRadius = min(f.width, f.height) / 2
                self.lens.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                self.lens.backgroundColor = UIColor.white.withAlphaComponent(0.22)
            }
        case .ended:
            let i = nearest()
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.lens.transform = .identity
                self.lens.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            }
            if i < tabs.count, let id = tabs[i]["id"] {
                tab = id
                retint()
                placeLens(animated: true)
                plugin?.send("tab", ["id": id])
            }
        default:
            UIView.animate(withDuration: 0.3) { self.lens.transform = .identity }
            placeLens(animated: true)
        }
    }
}
// ===== AuraOS native chrome (end) =====
