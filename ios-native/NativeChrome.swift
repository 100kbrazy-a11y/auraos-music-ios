// ===== AuraOS native chrome (begin) =====
// Real iOS 26 Liquid Glass for the parts of the app that float over everything: the media bar + tabs bubble
// (upright), the tab pill + media bubble (sideways), and the song menus / dialogs (system alerts are glass on iOS 26).
// The web screens keep running underneath and tell this what to show; taps, swipes and drags here are sent back.

import UIKit
import Capacitor
import WebKit
import UniformTypeIdentifiers
import AVFoundation
import MediaPlayer

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
        CAPPluginMethod(name: "header", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "settings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progressShow", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "libraryPath", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "haptic", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "chromeFade", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bgStart", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bgStop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "npButton", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "morphBegin", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "morphFrame", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "morphEnd", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "copyIn", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progressUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progressHide", returnType: CAPPluginReturnPromise),
    ]
    var progressPanel: ProgressPanel?
    var npPlay: GlassCircle?
    let bg = BackgroundPlayer()
    var morphBack: UIImageView?          // a picture of the library, behind the (see-through) web view
    var morphGlass: UIVisualEffectView?  // real Liquid Glass between that picture and the player's pieces
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    let settingsNav = SettingsNav()
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
            call.resolve(["glass": GlassChrome.hasGlass, "ios": UIDevice.current.systemVersion])
        }
    }

    @objc func update(_ call: CAPPluginCall) {
        var s: [String: Any] = [:]
        for k in ["tab", "title", "artist", "art", "artKey"] { if let v = call.getString(k) { s[k] = v } }
        for k in ["song", "playing", "tucked", "pinned", "visible", "bounce", "covered"] { if let v = call.getBool(k) { s[k] = v } }
        for k in ["r", "g", "b"] { if let v = call.getDouble(k) { s[k] = v } }
        DispatchQueue.main.async { self.chrome?.apply(s) }
        call.resolve()
    }

    /// The page's top bar: title, back button, the page's buttons, and whether the page is scrolled.
    @objc func header(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? "", back = call.getBool("back") ?? false, scrolled = call.getBool("scrolled") ?? false
        let textVisible = call.getBool("textVisible") ?? true
        let actions: [[String: Any]] = (call.getArray("actions") ?? []).compactMap { item in
            guard let o = item as? JSObject else { return nil }
            var a: [String: Any] = [:]
            a["symbol"] = (o["symbol"] as? String) ?? "circle"
            a["label"] = (o["label"] as? String) ?? ""
            a["text"] = (o["text"] as? Bool) ?? false
            a["prominent"] = (o["prominent"] as? Bool) ?? false
            a["on"] = (o["on"] as? Bool) ?? false
            return a
        }
        DispatchQueue.main.async { self.chrome?.setHeader(title: title, back: back, scrolled: scrolled, actions: actions, textVisible: textVisible) }
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
        let packs = call.getString("kind") == "pack"
        DispatchQueue.main.async {
            var types: [UTType] = packs ? [.zip] : [.audio]
            for ext in packs ? ["zip"] : ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "alac", "caf"] {
                if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) }
            }
            let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            vc.allowsMultipleSelection = true
            if packs {
                // start in Downloads if iOS allows it (it otherwise opens wherever you were last time)
                let dl = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Downloads", isDirectory: true)
                vc.directoryURL = dl
            }
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
        // move the picker's temporary copies into the app's own folder, so iOS can't clear them away mid-import
        let inbox = NativeChromePlugin.library.appendingPathComponent("Incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let files: [[String: Any]] = urls.map { u in
            let rel = "Incoming/" + UUID().uuidString + "-" + u.lastPathComponent
            let dest = NativeChromePlugin.library.appendingPathComponent(rel)
            var use = u
            if (try? FileManager.default.moveItem(at: u, to: dest)) != nil { use = dest }
            else if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { use = dest }
            let size = (try? use.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ["name": u.lastPathComponent, "path": use.absoluteString, "size": size, "rel": use == dest ? rel : ""]
        }
        call?.resolve(["files": files])
        call = nil
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        call?.resolve(["files": [[String: String]]()])
        call = nil
    }
}

extension NativeChromePlugin {
    /// Settings as a real iOS screen (system back button, switches, slider). open: push it in; otherwise just refresh it.
    @objc func settings(_ call: CAPPluginCall) {
        let open = call.getBool("open") ?? false
        let sections: [[String: Any]] = (call.getArray("sections") ?? []).compactMap { $0 as? JSObject }.map { SettingsNav.plain($0) }
        DispatchQueue.main.async {
            self.settingsNav.plugin = self
            if let t = self.chrome?.tint { self.settingsNav.tint = t }
            if open, let host = self.bridge?.viewController { self.settingsNav.open(from: host, sections: sections) }
            else { self.settingsNav.update(sections) }
            call.resolve()
        }
    }
}

extension NativeChromePlugin {
    @objc func progressShow(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? ""
        DispatchQueue.main.async {
            guard let host = self.bridge?.viewController?.view else { call.resolve(); return }
            self.progressPanel?.dismiss()
            let p = ProgressPanel(host: host, title: title, tint: self.chrome?.tint ?? .systemPink)
            self.progressPanel = p
            if self.bgTask == .invalid {     // ask iOS for extra time if the app is switched away mid-import
                self.bgTask = UIApplication.shared.beginBackgroundTask(withName: "AuraOS import") { [weak self] in
                    guard let self = self else { return }
                    UIApplication.shared.endBackgroundTask(self.bgTask)
                    self.bgTask = .invalid
                }
            }
            call.resolve()
        }
    }
    @objc func progressUpdate(_ call: CAPPluginCall) {
        let f = call.getDouble("fraction"), text = call.getString("text"), step = call.getString("step")
        let log = (call.getArray("log") ?? []).compactMap { $0 as? String }
        DispatchQueue.main.async { self.progressPanel?.update(fraction: f, text: text, step: step, log: log); call.resolve() }
    }
    @objc func progressHide(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.progressPanel?.dismiss()
            self.progressPanel = nil
            if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
            call.resolve()
        }
    }
}

extension NativeChromePlugin {
    static var library: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0] }

    /// file:// URL of the app's Library folder (songs live in Library/Songs/…)
    @objc func libraryPath(_ call: CAPPluginCall) {
        call.resolve(["url": NativeChromePlugin.library.absoluteString])
    }

    /// Copy a song into the app: a whole picked file, or a byte range of a music pack (a stored zip entry).
    /// Done here so the audio never has to pass through the web view.
    @objc func copyIn(_ call: CAPPluginCall) {
        guard let from = call.getString("from"), let to = call.getString("to"), let src = URL(string: from) else { call.reject("missing from/to"); return }
        let offset = UInt64(max(0, call.getDouble("offset") ?? 0))
        let length = call.getDouble("length") ?? -1
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dest = NativeChromePlugin.library.appendingPathComponent(to)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                let input = try FileHandle(forReadingFrom: src)
                defer { try? input.close() }
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                let output = try FileHandle(forWritingTo: dest)
                defer { try? output.close() }
                try input.seek(toOffset: offset)
                var left: Int64 = length < 0 ? Int64.max : Int64(length)
                var written: Int64 = 0
                while left > 0 {
                    let n = Int(min(Int64(1 << 20), left))
                    guard let chunk = try input.read(upToCount: n), !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    left -= Int64(chunk.count)
                }
                if length >= 0 && written != Int64(length) { throw NSError(domain: "AuraOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "only \(written) of \(Int64(length)) bytes could be copied"]) }
                call.resolve(["bytes": written])
            } catch {
                call.reject("Couldn't save the song: \(error.localizedDescription)")
            }
        }
    }

    @objc func removeFile(_ call: CAPPluginCall) {
        guard let to = call.getString("to") else { call.resolve(); return }
        try? FileManager.default.removeItem(at: NativeChromePlugin.library.appendingPathComponent(to))
        call.resolve()
    }
}

/// A Liquid Glass card in the middle of the screen while something long runs (adding songs, packs…):
/// title, progress bar, what it's on, and the last few steps it took.
final class ProgressPanel {
    let dim = UIView()
    let card: UIVisualEffectView
    let titleLabel = UILabel()
    let bar = UIProgressView(progressViewStyle: .default)
    let textLabel = UILabel()
    let stepLabel = UILabel()
    let logLabel = UILabel()

    init(host: UIView, title: String, tint: UIColor) {
        let c = UIVisualEffectView(effect: nil)
        if #available(iOS 26.0, *) { let ge = UIGlassEffect(style: .regular); ge.tintColor = tint.withAlphaComponent(0.16); c.effect = ge } else { c.effect = UIBlurEffect(style: .systemThickMaterialDark) }
        card = c
        dim.frame = host.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dim.alpha = 0
        host.addSubview(dim)
        shapeGlass(card, 30)
        dim.addSubview(card)
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        bar.progressTintColor = tint
        bar.trackTintColor = UIColor.white.withAlphaComponent(0.15)
        textLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        textLabel.textColor = .white
        textLabel.text = "Starting…"
        textLabel.numberOfLines = 2
        stepLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stepLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        stepLabel.numberOfLines = 2
        logLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        logLabel.numberOfLines = 4
        let stack = UIStackView(arrangedSubviews: [titleLabel, bar, textLabel, stepLabel, logLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(14, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: dim.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: dim.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: min(360, host.bounds.width - 40)),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -22),
        ])
        card.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.4, options: [], animations: {
            self.dim.alpha = 1
            self.card.transform = .identity
        })
    }

    func update(fraction: Double?, text: String?, step: String?, log: [String]) {
        if let f = fraction { bar.setProgress(Float(max(0, min(1, f))), animated: true) }
        if let t = text, !t.isEmpty { textLabel.text = t }
        if let st = step { stepLabel.text = st; stepLabel.isHidden = st.isEmpty }
        if !log.isEmpty { logLabel.text = log.joined(separator: "\n") }
    }

    func dismiss() {
        UIView.animate(withDuration: 0.25, animations: {
            self.dim.alpha = 0
            self.card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }, completion: { _ in self.dim.removeFromSuperview() })
    }
}

/// Presents Settings so it slides in over the app like a pushed page, with the system's (glass) back button and edge swipe.
final class SettingsNav: NSObject, UINavigationControllerDelegate {
    weak var plugin: NativeChromePlugin?
    var tint = UIColor(red: 1, green: 0.48, blue: 0.63, alpha: 1)
    var nav: UINavigationController?
    var placeholder = UIViewController()
    var screen: SettingsScreen?
    var afterClose: (() -> Void)?
    var shown = false                        // Settings has slid in (so landing back on the placeholder means "closed")

    static func plain(_ o: JSObject) -> [String: Any] {
        var d: [String: Any] = [:]
        for (k, v) in o {
            if let sub = v as? JSObject { d[k] = plain(sub) }
            else if let arr = v as? JSArray {
                d[k] = arr.map { (item: JSValue) -> Any in
                    if let so = item as? JSObject { return plain(so) }
                    return item
                }
            }
            else { d[k] = v }
        }
        return d
    }

    func open(from host: UIViewController, sections: [[String: Any]]) {
        guard nav == nil else { update(sections); return }
        placeholder = UIViewController()          // a fresh one each time (a view controller can only have one parent)
        shown = false
        placeholder.view.backgroundColor = .clear
        placeholder.navigationItem.backButtonDisplayMode = .minimal
        let n = UINavigationController(rootViewController: placeholder)
        n.modalPresentationStyle = .overFullScreen
        n.view.backgroundColor = .clear
        n.overrideUserInterfaceStyle = .dark
        n.view.tintColor = tint
        n.navigationBar.prefersLargeTitles = true
        n.delegate = self
        n.setNavigationBarHidden(true, animated: false)
        let sc = SettingsScreen(style: .insetGrouped)
        sc.owner = self
        sc.sections = sections
        screen = sc
        nav = n
        var top: UIViewController = host
        while let p = top.presentedViewController { top = p }
        top.present(n, animated: false) { n.pushViewController(sc, animated: true) }
    }

    func update(_ sections: [[String: Any]]) {
        guard let sc = screen, !sections.isEmpty else { return }
        sc.sections = sections
        sc.tableView.reloadData()
    }

    /// slide Settings away, then do something (used by rows that open things in the app)
    func close(then: (() -> Void)? = nil) {
        afterClose = then
        nav?.popToRootViewController(animated: true)
    }

    func navigationController(_ n: UINavigationController, willShow vc: UIViewController, animated: Bool) {
        n.setNavigationBarHidden(vc === placeholder, animated: animated)
    }

    func navigationController(_ n: UINavigationController, didShow vc: UIViewController, animated: Bool) {
        if vc === screen { shown = true; return }
        guard vc === placeholder, shown else { return }
        shown = false
        n.dismiss(animated: false) {
            self.nav = nil
            self.screen = nil
            self.plugin?.send("settingsClosed")
            let f = self.afterClose
            self.afterClose = nil
            f?()
        }
    }
}

/// The EQ preset drawn as 10 bars around a centre line.
final class EqGraph: UIView {
    var values: [Double] = [] { didSet { setNeedsDisplay() } }
    var labels: [String] = []
    var color = UIColor.systemPink
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard !values.isEmpty else { return }
        let n = CGFloat(values.count), w = bounds.width / n, top: CGFloat = 8, h = bounds.height - 30
        let mid = top + h / 2
        let line = UIBezierPath(rect: CGRect(x: 0, y: mid - 0.25, width: bounds.width, height: 0.5))
        UIColor.white.withAlphaComponent(0.15).setFill()
        line.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.secondaryLabel]
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * w + w / 2
            let track = UIBezierPath(roundedRect: CGRect(x: x - 3, y: top, width: 6, height: h), cornerRadius: 3)
            UIColor.white.withAlphaComponent(0.08).setFill()
            track.fill()
            let y = mid - CGFloat(v / 12) * (h / 2)
            let bar = UIBezierPath(roundedRect: CGRect(x: x - 3, y: min(y, mid), width: 6, height: max(2, abs(y - mid))), cornerRadius: 3)
            color.setFill()
            bar.fill()
            let knob = UIBezierPath(ovalIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
            UIColor.white.setFill()
            knob.fill()
            if i < labels.count {
                let str = NSAttributedString(string: labels[i], attributes: attrs)
                let sz = str.size()
                str.draw(at: CGPoint(x: x - sz.width / 2, y: bounds.height - 16))
            }
        }
    }
}

/// The Settings list: rows come from the web side (toggle, slider, choice, menu, eq, info, action).
final class SettingsScreen: UITableViewController {
    weak var owner: SettingsNav?
    var sections: [[String: Any]] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.largeTitleDisplayMode = .always
    }

    func rows(_ s: Int) -> [[String: Any]] { (sections[s]["rows"] as? [[String: Any]]) ?? [] }
    func send(_ type: String, _ extra: [String: Any]) { owner?.plugin?.send(type, extra) }
    var tint: UIColor { owner?.tint ?? .systemPink }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows(section).count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section]["title"] as? String }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section]["footer"] as? String }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let r = rows(indexPath.section)[indexPath.row]
        let id = (r["id"] as? String) ?? ""
        let type = (r["type"] as? String) ?? "action"
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = r["title"] as? String
        cfg.secondaryText = r["subtitle"] as? String
        cfg.secondaryTextProperties.color = .secondaryLabel
        cfg.secondaryTextProperties.numberOfLines = 0
        if let sym = r["symbol"] as? String { cfg.image = UIImage(systemName: sym); cfg.imageProperties.tintColor = tint }
        if (r["destructive"] as? Bool) ?? false { cfg.textProperties.color = .systemRed; cfg.imageProperties.tintColor = .systemRed }
        cell.selectionStyle = type == "action" ? .default : .none
        switch type {
        case "toggle":
            cell.contentConfiguration = cfg
            let sw = UISwitch()
            sw.isOn = (r["value"] as? Bool) ?? false
            sw.onTintColor = tint
            sw.addAction(UIAction { [weak self] _ in self?.send("setting", ["id": id, "value": sw.isOn]) }, for: .valueChanged)
            cell.accessoryView = sw
        case "slider":
            cell.contentConfiguration = cfg
            let label = UILabel()
            label.textColor = .secondaryLabel
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            let fmt = { (v: Int) -> String in v == 0 ? ((r["zero"] as? String) ?? "Off") : "\(v) \((r["unit"] as? String) ?? "")" }
            let slider = UISlider()
            slider.minimumValue = Float((r["min"] as? Double) ?? 0)
            slider.maximumValue = Float((r["max"] as? Double) ?? 10)
            slider.value = Float((r["value"] as? Double) ?? 0)
            slider.minimumTrackTintColor = tint
            label.text = fmt(Int(slider.value.rounded()))
            label.sizeToFit()
            label.frame.size.width = 52
            label.textAlignment = .right
            var last = Int(slider.value.rounded())
            slider.addAction(UIAction { [weak self] _ in
                let v = Int(slider.value.rounded())
                label.text = fmt(v)
                if v != last { last = v; UISelectionFeedbackGenerator().selectionChanged(); self?.send("setting", ["id": id, "value": v]) }
            }, for: .valueChanged)
            slider.addAction(UIAction { _ in slider.setValue(Float(Int(slider.value.rounded())), animated: true) }, for: [.touchUpInside, .touchUpOutside])
            cell.accessoryView = label
            let box = UIView()
            slider.translatesAutoresizingMaskIntoConstraints = false
            box.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(box)
            box.addSubview(slider)
            // the row's text sits above, the slider below it
            var c2 = cfg
            c2.directionalLayoutMargins.bottom = 52
            cell.contentConfiguration = c2
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                box.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                box.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                box.heightAnchor.constraint(equalToConstant: 40),
                slider.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                slider.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                slider.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
        case "choice":
            var c2 = cfg
            c2.directionalLayoutMargins.bottom = 52
            cell.contentConfiguration = c2
            let opts = (r["options"] as? [Any]) ?? []
            let labels = opts.compactMap { ($0 as? [String: Any])?["label"] as? String }
            let seg = UISegmentedControl(items: labels)
            let cur = r["value"].map { "\($0)" } ?? ""
            seg.selectedSegmentIndex = opts.firstIndex { o in (o as? [String: Any])?["value"].map { "\($0)" } == cur } ?? UISegmentedControl.noSegment
            seg.addAction(UIAction { [weak self] _ in
                let i = seg.selectedSegmentIndex
                guard i >= 0, i < opts.count, let o = opts[i] as? [String: Any] else { return }
                self?.send("setting", ["id": id, "value": o["value"] ?? ""])
            }, for: .valueChanged)
            seg.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(seg)
            NSLayoutConstraint.activate([
                seg.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                seg.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                seg.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            ])
        case "menu":
            cell.contentConfiguration = cfg
            let opts = (r["options"] as? [Any]) ?? []
            let cur = (r["value"] as? String) ?? ""
            var bc = UIButton.Configuration.plain()
            bc.title = cur
            bc.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            bc.imagePlacement = .trailing
            bc.imagePadding = 4
            bc.baseForegroundColor = .secondaryLabel
            let b = UIButton(configuration: bc)
            b.menu = UIMenu(children: opts.compactMap { (o: Any) -> UIMenuElement? in
                guard let name = o as? String else { return nil }
                return UIAction(title: name, state: name == cur ? .on : .off) { [weak self] _ in self?.send("setting", ["id": id, "value": name]) }
            })
            b.showsMenuAsPrimaryAction = true
            b.sizeToFit()
            cell.accessoryView = b
        case "eq":
            let g = EqGraph()
            g.values = ((r["values"] as? [Any]) ?? []).compactMap { (v: Any) -> Double? in
                if let d = v as? Double { return d }
                if let i = v as? Int { return Double(i) }
                return nil
            }
            g.labels = ((r["labels"] as? [Any]) ?? []).compactMap { $0 as? String }
            g.color = tint
            g.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(g)
            NSLayoutConstraint.activate([
                g.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                g.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                g.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                g.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -6),
                g.heightAnchor.constraint(equalToConstant: 132),
            ])
        default:                       // info / action
            cell.contentConfiguration = cfg
            if type == "action" && !((r["destructive"] as? Bool) ?? false) { cell.accessoryType = .disclosureIndicator }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let r = rows(indexPath.section)[indexPath.row]
        guard (r["type"] as? String) == "action", let id = r["id"] as? String else { return }
        if (r["stay"] as? Bool) ?? false { send("settingTap", ["id": id]); return }
        owner?.close { [weak self] in self?.owner?.plugin?.send("settingTap", ["id": id]) }   // things that open in the app: slide Settings away first
    }
}

/// Haptics that fit the action.
enum Haptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let medium = UIImpactFeedbackGenerator(style: .medium)
    static let softG = UIImpactFeedbackGenerator(style: .soft)
    static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    static let sel = UISelectionFeedbackGenerator()
    static let note = UINotificationFeedbackGenerator()
    static func tap() { light.impactOccurred() }                       // buttons, skips
    static func press() { medium.impactOccurred(intensity: 0.8) }      // play / pause
    static func soft() { softG.impactOccurred() }                      // opening / closing the player, sheets
    static func tick() { sel.selectionChanged() }                      // moving across tabs, sliders, pickers
    static func thud() { rigid.impactOccurred(intensity: 0.7) }        // landing (the bubble catching the player)
    static func play(_ kind: String) {
        switch kind {
        case "press": press()
        case "soft": soft()
        case "tick": tick()
        case "thud": thud()
        case "success": note.notificationOccurred(.success)
        case "warning": note.notificationOccurred(.warning)
        case "error": note.notificationOccurred(.error)
        default: tap()
        }
    }
}

/// Give a glass view its rounded shape the way iOS 26 wants it. Real Liquid Glass ignores layer.cornerRadius and must
/// NOT be clipped (clipping cuts off its rim, highlights and the bending at the edges — it then looks like a fake);
/// it takes the shape from cornerConfiguration instead. What's *inside* the glass is still clipped to the same shape.
func shapeGlass(_ v: UIVisualEffectView, _ r: CGFloat) {
    let r = max(0, r)
    v.layer.cornerCurve = .continuous
    v.contentView.layer.cornerRadius = r
    v.contentView.layer.cornerCurve = .continuous
    v.contentView.clipsToBounds = true
    if #available(iOS 26.0, *) {
        v.clipsToBounds = false
        v.layer.cornerRadius = r
        v.cornerConfiguration = .corners(radius: .fixed(Double(r)))
    } else {
        v.clipsToBounds = true
        v.layer.cornerRadius = r
    }
}

/// A round button of clear Liquid Glass with a symbol on it (it bends what's behind it, and reacts to touch).
final class GlassCircle: UIView {
    let glass = UIVisualEffectView(effect: nil)
    let icon = UIImageView()
    var onTap: (() -> Void)?
    var symbolSize: CGFloat = 30
    override init(frame: CGRect) {
        super.init(frame: frame)
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect(style: .clear)
            g.isInteractive = true
            glass.effect = g
        } else {
            glass.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }
        addSubview(glass)
        icon.tintColor = .white
        icon.contentMode = .center
        icon.layer.shadowColor = UIColor.black.cgColor
        icon.layer.shadowOpacity = 0.35
        icon.layer.shadowRadius = 3
        icon.layer.shadowOffset = CGSize(width: 0, height: 1)
        glass.contentView.addSubview(icon)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        shapeGlass(glass, bounds.width / 2)
        icon.frame = glass.bounds
    }
    func setSymbol(_ name: String) {
        icon.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .bold))
    }
    @objc func tapped() {
        Haptics.press()
        UIView.animate(withDuration: 0.12, animations: { self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9) }, completion: { _ in
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.6, options: [.allowUserInteraction], animations: { self.transform = .identity })
        })
        onTap?()
    }
}

extension NativeChromePlugin {
    /// how visible the bubble, tabs and top bar are (0…1), set every frame while the player grows / shrinks
    @objc func chromeFade(_ call: CAPPluginCall) {
        let a = call.getDouble("a") ?? 1
        DispatchQueue.main.async { self.chrome?.fade(CGFloat(a)); call.resolve() }
    }

    @objc func haptic(_ call: CAPPluginCall) {
        let kind = call.getString("kind") ?? "tap"
        DispatchQueue.main.async { Haptics.play(kind); call.resolve() }
    }

    /// The full player's play / pause as real clear glass, laid exactly over the web one while the player is open.
    @objc func npButton(_ call: CAPPluginCall) {
        let show = call.getBool("show") ?? false
        let x = call.getDouble("x") ?? 0, y = call.getDouble("y") ?? 0, w = call.getDouble("w") ?? 0
        let playing = call.getBool("playing") ?? false
        DispatchQueue.main.async {
            guard let host = self.bridge?.viewController?.view else { call.resolve(); return }
            if self.npPlay == nil {
                let b = GlassCircle(frame: .zero)
                b.onTap = { [weak self] in self?.send("toggle") }
                b.alpha = 0
                host.addSubview(b)
                self.npPlay = b
            }
            guard let b = self.npPlay else { call.resolve(); return }
            if show && w > 0 {
                host.bringSubviewToFront(b)
                b.symbolSize = CGFloat(w) * 0.36
                b.setSymbol(playing ? "pause.fill" : "play.fill")
                b.bounds = CGRect(x: 0, y: 0, width: w, height: w)
                b.center = CGPoint(x: x + w / 2, y: y + w / 2)
                if b.alpha < 1 { UIView.animate(withDuration: 0.18) { b.alpha = 1 } }
            } else if b.alpha > 0 {
                UIView.animate(withDuration: 0.12) { b.alpha = 0 }
            }
            call.resolve()
        }
    }
}

/// The lens over the tabs / top-bar buttons while your finger is on them. On iOS 26 it's the system's own clear
/// Liquid Glass (its real rim, light and edge bending) with a magnified copy of the icons inside it, like the system
/// tab bar; on older systems a drawn imitation.
final class GlassLens: UIView {
    let glass = UIVisualEffectView(effect: nil)       // iOS 26: the real glass
    let mirrorHost = UIView()
    let overlay = UIView()                            // older iOS: the drawn rim / shine
    let shine = CAGradientLayer()
    let glow = CAGradientLayer()
    var mirror: UIView?
    weak var source: UIView?
    var magnification: CGFloat = 1.3
    var realGlass: Bool { if #available(iOS 26.0, *) { return true } else { return false } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        mirrorHost.clipsToBounds = true
        mirrorHost.layer.cornerCurve = .continuous
        if realGlass {
            addSubview(glass)
            glass.contentView.addSubview(mirrorHost)
        } else {
            addSubview(mirrorHost)
            overlay.isUserInteractionEnabled = false
            overlay.layer.cornerCurve = .continuous
            overlay.layer.borderWidth = 1
            overlay.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
            overlay.backgroundColor = UIColor.white.withAlphaComponent(0.03)
            glow.type = .radial
            glow.colors = [UIColor.white.withAlphaComponent(0.0).cgColor, UIColor.white.withAlphaComponent(0.18).cgColor]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1.05, y: 1.05)
            shine.colors = [UIColor.white.withAlphaComponent(0.42).cgColor, UIColor.white.withAlphaComponent(0.0).cgColor]
            shine.startPoint = CGPoint(x: 0.5, y: 0)
            shine.endPoint = CGPoint(x: 0.5, y: 0.5)
            overlay.layer.addSublayer(glow)
            overlay.layer.addSublayer(shine)
            addSubview(overlay)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.2
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 0, height: 4)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// the glass materialises as the lens appears and dissolves as it goes (the system's own way of showing glass)
    override var alpha: CGFloat {
        didSet {
            guard #available(iOS 26.0, *) else { return }
            let on = alpha > 0.01
            if on && glass.effect == nil {
                let g = UIGlassEffect(style: .clear)
                g.isInteractive = true
                glass.effect = g
            } else if !on && glass.effect != nil {
                glass.effect = nil
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = min(bounds.width, bounds.height) / 2
        if realGlass {
            glass.frame = bounds
            shapeGlass(glass, r)
        }
        mirrorHost.frame = bounds
        mirrorHost.layer.cornerRadius = r
        overlay.frame = bounds
        overlay.layer.cornerRadius = r
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds; glow.cornerRadius = r
        shine.frame = bounds; shine.cornerRadius = r
        CATransaction.commit()
        updateMirror()
    }

    /// take a picture of what's under it to magnify (call when the finger goes down)
    func begin(source: UIView) {
        self.source = source
        mirror?.removeFromSuperview()
        if let snap = source.snapshotView(afterScreenUpdates: false) {
            mirror = snap
            mirrorHost.addSubview(snap)
        }
        updateMirror()
    }

    /// keep the magnified copy lined up with what's under the lens
    func updateMirror() {
        guard let m = mirror, let src = source, let sup = superview else { return }
        let c = sup.convert(center, to: src)
        m.transform = .identity
        m.bounds = src.bounds
        m.transform = CGAffineTransform(scaleX: magnification, y: magnification)
        m.center = CGPoint(x: bounds.midX + (src.bounds.midX - c.x) * magnification, y: bounds.midY + (src.bounds.midY - c.y) * magnification)
    }
}

extension NativeChromePlugin {
    /// Growing / shrinking the player with real Liquid Glass. The glass has to sit *behind* the player's pieces,
    /// so: a picture of the library goes behind the web view, the glass goes over that picture, and the web view
    /// turns see-through for the length of the animation. reuse: use the picture from when the player opened.
    @objc func morphBegin(_ call: CAPPluginCall) {
        let reuse = call.getBool("reuse") ?? false
        let r = call.getDouble("r") ?? 0, g = call.getDouble("g") ?? 0, b = call.getDouble("b") ?? 0
        DispatchQueue.main.async {
            guard let web = self.bridge?.webView, let sup = web.superview else { call.resolve(["ok": false]); return }
            let place = { (img: UIImage) in
                let iv = self.morphBack ?? UIImageView()
                iv.image = img
                iv.frame = web.frame
                iv.isHidden = false
                if iv.superview !== sup { sup.insertSubview(iv, belowSubview: web) }
                self.morphBack = iv
                let gl = self.morphGlass ?? UIVisualEffectView(effect: nil)
                if #available(iOS 26.0, *) {
                    let ge = UIGlassEffect(style: .regular)
                    ge.tintColor = UIColor(red: CGFloat(r / 255), green: CGFloat(g / 255), blue: CGFloat(b / 255), alpha: 0.16)
                    gl.effect = ge
                } else { gl.effect = UIBlurEffect(style: .systemUltraThinMaterialDark) }
                gl.layer.cornerCurve = .continuous
                gl.alpha = 0
                if gl.superview !== sup { sup.insertSubview(gl, aboveSubview: iv) }
                self.morphGlass = gl
                web.isOpaque = false
                web.backgroundColor = .clear
                web.scrollView.backgroundColor = .clear
                call.resolve(["ok": true])
            }
            if reuse, let img = self.morphBack?.image, img.size == web.bounds.size { place(img); return }
            let cfg = WKSnapshotConfiguration()
            web.takeSnapshot(with: cfg) { img, _ in
                guard let img = img else { call.resolve(["ok": false]); return }
                place(img)
            }
        }
    }

    @objc func morphFrame(_ call: CAPPluginCall) {
        let x = call.getDouble("x") ?? 0, y = call.getDouble("y") ?? 0, w = call.getDouble("w") ?? 0, h = call.getDouble("h") ?? 0
        let rad = call.getDouble("rad") ?? 0, o = call.getDouble("o") ?? 1
        DispatchQueue.main.async {
            guard let gl = self.morphGlass else { call.resolve(); return }
            UIView.performWithoutAnimation {
                gl.frame = CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
                shapeGlass(gl, CGFloat(rad))
                gl.alpha = CGFloat(o)
            }
            call.resolve()
        }
    }

    @objc func morphEnd(_ call: CAPPluginCall) {
        let keep = call.getBool("keep") ?? false     // keep the library picture for when the player closes
        DispatchQueue.main.async {
            guard let web = self.bridge?.webView else { call.resolve(); return }
            web.isOpaque = true
            let bg = UIColor(red: 11 / 255, green: 11 / 255, blue: 14 / 255, alpha: 1)
            web.backgroundColor = bg
            web.scrollView.backgroundColor = bg
            self.morphGlass?.alpha = 0
            self.morphBack?.isHidden = true
            if !keep { self.morphBack?.image = nil }
            call.resolve()
        }
    }
}

extension NativeChromePlugin {
    /// The app is going to the background (or the phone is being locked): keep the music going natively.
    @objc func bgStart(_ call: CAPPluginCall) {
        let items: [[String: Any]] = (call.getArray("items") ?? []).compactMap { $0 as? JSObject }.map { SettingsNav.plain($0) }
        let index = Int(call.getDouble("index") ?? 0), position = call.getDouble("position") ?? 0
        let repeatMode = call.getString("repeat") ?? "off"
        var arts: [String: String] = [:]
        for (k, v) in call.getObject("arts") ?? [:] { if let str = v as? String { arts[k] = str } }
        DispatchQueue.main.async {
            let ok = self.bg.start(items: items, index: index, position: position, repeatMode: repeatMode, arts: arts)
            call.resolve(["ok": ok])
        }
    }
    /// Back in the app: stop the native player and say where it got to.
    @objc func bgStop(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(self.bg.stop()) }
    }
}

/// Plays the queue natively while the app is in the background or the phone is locked
/// (with the lock screen / Control Center controls), so the music never stops.
final class BackgroundPlayer: NSObject {
    var player: AVPlayer?
    var items: [[String: Any]] = []
    var index = 0
    var repeatMode = "off"
    var arts: [String: MPMediaItemArtwork] = [:]
    var endObs: NSObjectProtocol?
    var targets: [(MPRemoteCommand, Any)] = []

    func url(_ i: Int) -> URL? {
        guard i >= 0, i < items.count, let s = items[i]["path"] as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    func start(items: [[String: Any]], index: Int, position: Double, repeatMode: String, arts: [String: String]) -> Bool {
        _ = stop()
        self.items = items
        self.repeatMode = repeatMode
        self.arts = [:]
        for (k, b64) in arts {
            if let d = Data(base64Encoded: b64), let img = UIImage(data: d) {
                self.arts[k] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            }
        }
        guard url(index) != nil else { return false }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer()
        p.actionAtItemEnd = .pause
        player = p
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let it = n.object as? AVPlayerItem, it === self.player?.currentItem else { return }
            self.ended()
        }
        go(to: index, at: position, play: true)
        setupRemote()
        return true
    }

    func go(to i: Int, at position: Double = 0, play: Bool = true) {
        guard let p = player, let u = url(i) else { return }
        index = i
        p.replaceCurrentItem(with: AVPlayerItem(url: u))
        if position > 0 { p.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        if play { p.play() }
        updateInfo()
    }

    /// next playable song (skips ones that aren't stored as files)
    func step(_ d: Int, wrap: Bool) -> Int? {
        var i = index
        for _ in 0..<max(1, items.count) {
            i += d
            if i >= items.count { if wrap { i = 0 } else { return nil } }
            if i < 0 { if wrap { i = items.count - 1 } else { return nil } }
            if url(i) != nil { return i }
        }
        return nil
    }

    func ended() {
        if repeatMode == "one" { player?.seek(to: .zero); player?.play(); updateInfo(); return }
        if let n = step(1, wrap: repeatMode == "all") { go(to: n) } else { player?.pause(); updateInfo() }
    }

    func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ fn: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            cmd.isEnabled = true
            targets.append((cmd, cmd.addTarget(handler: fn)))
        }
        add(c.playCommand) { [weak self] _ in self?.player?.play(); self?.updateInfo(); return .success }
        add(c.pauseCommand) { [weak self] _ in self?.player?.pause(); self?.updateInfo(); return .success }
        add(c.togglePlayPauseCommand) { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            if p.rate > 0 { p.pause() } else { p.play() }
            self?.updateInfo(); return .success
        }
        add(c.nextTrackCommand) { [weak self] _ in
            guard let self = self, let n = self.step(1, wrap: self.repeatMode != "off") else { return .noSuchContent }
            self.go(to: n); return .success
        }
        add(c.previousTrackCommand) { [weak self] _ in
            guard let self = self, let p = self.player else { return .commandFailed }
            if p.currentTime().seconds > 3 { p.seek(to: .zero); self.updateInfo(); return .success }
            if let n = self.step(-1, wrap: self.repeatMode != "off") { self.go(to: n) } else { p.seek(to: .zero); self.updateInfo() }
            return .success
        }
        add(c.changePlaybackPositionCommand) { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player?.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600)) { _ in self?.updateInfo() }
            return .success
        }
    }

    func updateInfo() {
        guard let p = player, index < items.count else { return }
        let it = items[index]
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (it["title"] as? String) ?? "",
            MPMediaItemPropertyArtist: (it["artist"] as? String) ?? "",
            MPMediaItemPropertyAlbumTitle: (it["album"] as? String) ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, p.currentTime().seconds.isFinite ? p.currentTime().seconds : 0),
            MPNowPlayingInfoPropertyPlaybackRate: p.rate,
        ]
        if let d = it["duration"] as? Double { info[MPMediaItemPropertyPlaybackDuration] = d }
        if let k = it["art"] as? String, let a = arts[k] { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// stop and report where it got to
    func stop() -> [String: Any] {
        guard let p = player else { return ["active": false] }
        let pos = p.currentTime().seconds
        let out: [String: Any] = ["active": true, "index": index, "position": pos.isFinite ? pos : 0, "playing": p.rate > 0]
        p.pause()
        player = nil
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = nil
        for (cmd, t) in targets { cmd.removeTarget(t) }
        targets = []
        return out
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
    let lens = UIView()                    // the resting highlight behind the selected tab
    let lensGlass = GlassLens()               // the clear glass lens over the tabs while your finger is on them
    var magnified = -1

    // top bar
    let topGlass: UIVisualEffectView
    let topTitle = UILabel()
    let topItems = PassthroughView()
    var backBtn: UIButton?
    var actionViews: [UIView] = []
    var headTitle = "", headBack = false, headScrolled = false
    var headActions: [[String: Any]] = []
    var headKey = ""
    var headTextVisible = true
    let pillLens = GlassLens()
    var pillPick = -1
    var covered = false

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
        topGlass = GlassChrome.glass()
        super.init()
        root.frame = host.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.backgroundColor = .clear
        host.addSubview(root)
        root.addSubview(topGlass)                         // the top bar's glass sits under the tab pill
        for g in [dockGlass, pillGlass, miniGlass] { root.addSubview(g) }
        topTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        topTitle.textColor = .white
        topTitle.alpha = 0
        topGlass.alpha = 0
        root.addSubview(topTitle)
        root.addSubview(topItems)
        root.addSubview(pillLens)
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
        v.layer.cornerCurve = .continuous
        shapeGlass(v, 22)
        return v
    }

    func glassEffect(interactive: Bool) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect(style: .regular)
            g.isInteractive = interactive
            g.tintColor = tint.withAlphaComponent(0.16)      // the song's colour, the same strength as everywhere else
            return g
        }
        return UIBlurEffect(style: .systemThinMaterialDark)
    }

    func retint() {
        dockGlass.effect = glassEffect(interactive: true)
        topGlass.effect = glassEffect(interactive: false)
        pillGlass.effect = glassEffect(interactive: true)
        miniGlass.effect = glassEffect(interactive: true)
        fill.backgroundColor = tint
        if !headKey.isEmpty { rebuildHeader(); layoutTop(root.bounds, root.safeAreaInsets) }   // the Play button carries the song's colour
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
            var c = UIButton.Configuration.clearGlass()     // clear glass, like the full player's play button
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
        symbolButton(prevButton, "backward.end.fill", size: 17, glass: false)     // same shapes as the full player's buttons
        symbolButton(playButton, "play.fill", size: 19, glass: true)
        symbolButton(nextButton, "forward.end.fill", size: 17, glass: false)
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
        root.addSubview(lensGlass)                        // above the bubble
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
            self.layoutTop(b, safe)
            let show: CGFloat = self.visible && !self.covered ? 1 : 0
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
        reportAnchor()
    }

    /// Tell the web side where the media bubble is (and its cover, titles and play button), for the grow/shrink animation.
    var lastAnchor = ""
    func reportAnchor() {
        let land = landscape
        let host: UIView = land ? (hasSong ? miniGlass : pillGlass) : dockGlass
        let r = CGRect(x: host.center.x - host.bounds.width / 2, y: host.center.y - host.bounds.height / 2, width: host.bounds.width, height: host.bounds.height)
        let rect = (land && tucked && hasSong) ? CGRect(x: r.minX, y: r.minY, width: 68, height: r.height) : (land || hasSong ? r : r)
        func inRoot(_ v: UIView) -> CGRect {
            let f = CGRect(x: v.center.x - v.bounds.width / 2, y: v.center.y - v.bounds.height / 2, width: v.bounds.width, height: v.bounds.height)
            return (v.superview ?? root).convert(f, to: root)
        }
        let art = inRoot(artClip), text = inRoot(textBox), play = inRoot(playButton)
        let prev = prevButton.alpha > 0.5 ? inRoot(prevButton) : .zero, next = nextButton.alpha > 0.5 ? inRoot(nextButton) : .zero
        let bar = inRoot(track)
        let d: [String: Any] = [
            "x": Double(rect.minX), "y": Double(rect.minY), "w": Double(rect.width), "h": Double(rect.height),
            "ax": Double(art.minX), "ay": Double(art.minY), "aw": Double(art.width), "ah": Double(art.height),
            "tx": Double(text.minX), "ty": Double(text.minY), "tw": Double(text.width), "th": Double(text.height),
            "px": Double(play.minX), "py": Double(play.minY), "pw": Double(play.width), "ph": Double(play.height),
            "vx": Double(prev.minX), "vy": Double(prev.minY), "vw": Double(prev.width), "vh": Double(prev.height),
            "nx": Double(next.minX), "ny": Double(next.minY), "nw": Double(next.width), "nh": Double(next.height),
            "bx": Double(bar.minX), "by": Double(bar.minY), "bw": Double(bar.width), "bh": Double(bar.height),
            "song": hasSong, "tucked": tucked && land,
        ]
        let key = d.keys.sorted().map { "\($0)=\(d[$0] ?? "")" }.joined(separator: ",")
        if key == lastAnchor { return }
        lastAnchor = key
        plugin?.send("anchor", d)
    }

    func layoutUpright(_ b: CGRect, _ safe: UIEdgeInsets) {
        if miniRow.superview !== dockGlass.contentView { dockGlass.contentView.addSubview(miniRow) }
        if divider.superview !== dockGlass.contentView { dockGlass.contentView.addSubview(divider) }
        if tabsRow.superview !== dockGlass.contentView { dockGlass.contentView.addSubview(tabsRow) }
        let miniH: CGFloat = hasSong ? 62 : 0, tabsH: CGFloat = 62
        let w = b.width - 24, h = miniH + tabsH
        put(dockGlass, CGRect(x: 12, y: b.height - safe.bottom - 10 - h, width: w, height: h))
        shapeGlass(dockGlass, 26)
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
            tb.transform = .identity
            put(tb, CGRect(x: 4 + CGFloat(i) * tw, y: 0, width: tw, height: tabsH))
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
        shapeGlass(pillGlass, 34)
        tabsRow.frame = pillGlass.bounds
        for (i, tb) in tabButtons.enumerated() {
            tb.transform = .identity
            put(tb, CGRect(x: 4, y: 4 + CGFloat(i) * (btn + 2), width: 60, height: btn))
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
            shapeGlass(miniGlass, 22)
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
            shapeGlass(miniGlass, 22)
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

    /// a tab's frame ignoring the lens magnification
    func restFrame(_ v: UIView) -> CGRect {
        CGRect(x: v.center.x - v.bounds.width / 2, y: v.center.y - v.bounds.height / 2, width: v.bounds.width, height: v.bounds.height)
    }

    // ---------------------------------------------------------------- the top bar
    func layoutTop(_ b: CGRect, _ safe: UIEdgeInsets) {
        let barH = safe.top + 60
        put(topGlass, CGRect(x: 0, y: 0, width: b.width, height: barH))
        topItems.frame = CGRect(x: 0, y: 0, width: b.width, height: barH)
        let y = safe.top + 8
        var left = safe.left + 14
        if let bb = backBtn { bb.bounds = CGRect(x: 0, y: 0, width: 44, height: 44); bb.center = CGPoint(x: left + 22, y: y + 22); left += 54 }
        var right = b.width - safe.right - 12 - (landscape ? 80 : 0)     // sideways: stay clear of the tab pill
        for v in actionViews.reversed() {
            let w = v.bounds.width
            let isText = (v as? UIButton)?.accessibilityIdentifier?.hasPrefix("t|") == true
            if isText && !headTextVisible {          // tucked away: fades out where it was, takes no room
                v.alpha = 0
                v.center = CGPoint(x: right - w / 2, y: y + 22)
                continue
            }
            if isText { v.alpha = 1 }
            v.center = CGPoint(x: right - w / 2, y: y + 22)
            right -= w + 8
        }
        topTitle.frame = CGRect(x: left + 2, y: y, width: max(0, right - left - 6), height: 44)
        let on = visible && !covered
        topGlass.alpha = on && headScrolled ? 1 : 0          // the glass slab appears once the page scrolls under it
        topTitle.alpha = on && headScrolled ? 1 : 0
        topItems.alpha = on ? 1 : 0
    }

    func textButton(_ b: UIButton, _ sym: String, _ label: String, _ prominent: Bool) {
        var c: UIButton.Configuration
        if #available(iOS 26.0, *) { c = prominent ? .prominentGlass() : .glass() } else { c = prominent ? .filled() : .gray() }
        c.image = UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        c.title = label
        c.imagePadding = 6
        c.cornerStyle = .capsule
        c.baseForegroundColor = .white
        if prominent { c.baseBackgroundColor = tint }
        c.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 16)
        b.configuration = c
        let size = b.sizeThatFits(CGSize(width: 260, height: 44))
        b.bounds = CGRect(x: 0, y: 0, width: ceil(max(70, size.width)), height: 44)
    }

    func setHeader(title: String, back: Bool, scrolled: Bool, actions: [[String: Any]], textVisible: Bool = true) {
        let textChanged = textVisible != headTextVisible
        headTextVisible = textVisible
        let key = "\(back)|" + actions.map { "\($0["symbol"] ?? "")/\($0["label"] ?? "")/\($0["text"] ?? "")/\($0["prominent"] ?? "")/\($0["on"] ?? "")" }.joined(separator: ",")
        headTitle = title
        topTitle.text = title
        let scrollChanged = scrolled != headScrolled
        headScrolled = scrolled
        var animatedRebuild = false
        if key != headKey {
            headKey = key
            headBack = back
            headActions = actions
            animatedRebuild = !actionViews.isEmpty || backBtn != nil
            rebuildHeader(animated: animatedRebuild)
        }
        if animatedRebuild { return }        // the rebuild animates the layout itself (a plain layout now would cut it short)
        if textChanged {                      // Play / Shuffle fade in (or out) and the rest slides to make room
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.layoutTop(self.root.bounds, self.root.safeAreaInsets)
            }
            return
        }
        if scrollChanged {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) { self.layout(animated: false) }
        } else { layout(animated: false) }
    }

    /// Build the top bar's buttons. animated: the icon capsule is kept and stretches / shrinks to its new size, buttons
    /// that go away shrink into it, new ones grow out of it, and the rest fade (going in and out of Search, for example).
    func rebuildHeader(animated: Bool = false) {
        let oldGroup = actionViews.first(where: { $0 is UIVisualEffectView }) as? UIVisualEffectView
        var oldButtons: [String: UIButton] = [:]
        if let og = oldGroup {
            for case let b as UIButton in og.contentView.subviews { if let k = b.accessibilityIdentifier { oldButtons[k] = b } }
        }
        let keepBack = headBack ? backBtn : nil
        var oldTexts: [String: UIButton] = [:]
        for v in actionViews { if let b = v as? UIButton, let k = b.accessibilityIdentifier, k.hasPrefix("t|") { oldTexts[k] = b } }
        var wantedTexts = Set<String>()
        for a in headActions where (a["text"] as? Bool) ?? false {
            wantedTexts.insert("t|\((a["symbol"] as? String) ?? "")|\((a["label"] as? String) ?? "")|\((a["prominent"] as? Bool) ?? false)")
        }
        var kept: [UIView] = []
        if let kb = keepBack { kept.append(kb) }
        for (k, b) in oldTexts where wantedTexts.contains(k) { kept.append(b) }
        if let og = oldGroup { kept.append(og) }
        for v in topItems.subviews where !kept.contains(where: { $0 === v }) {
            if animated {
                UIView.animate(withDuration: 0.22, animations: { v.alpha = 0; v.transform = CGAffineTransform(scaleX: 0.6, y: 0.6) }, completion: { _ in v.removeFromSuperview() })
            } else { v.removeFromSuperview() }
        }
        actionViews = []
        backBtn = nil
        var appearing: [UIView] = []
        if headBack {
            if let kb = keepBack { backBtn = kb }
            else {
                let b = UIButton(type: .system)
                symbolButton(b, "chevron.backward", size: 17, glass: true)
                b.addTarget(self, action: #selector(backTap), for: .touchUpInside)
                b.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
                topItems.addSubview(b)
                backBtn = b
                appearing.append(b)
            }
        }
        var group: [UIButton] = []
        var usedOld = false
        var groupMoves: [(UIButton, CGRect)] = []
        func flush() {                                   // icon buttons side by side share one glass capsule, like iOS 26
            guard !group.isEmpty else { return }
            let g: UIVisualEffectView
            let reused: Bool
            if let og = oldGroup, !usedOld { g = og; usedOld = true; reused = true }
            else { g = GlassChrome.glass(); g.effect = glassEffect(interactive: true); shapeGlass(g, 22); reused = false }
            let keep = Set(group.map { ObjectIdentifier($0) })
            for case let old as UIButton in g.contentView.subviews where !keep.contains(ObjectIdentifier(old)) {
                if animated {                             // shrinks away into the capsule
                    UIView.animate(withDuration: 0.25, animations: { old.alpha = 0; old.transform = CGAffineTransform(scaleX: 0.3, y: 0.3) }, completion: { _ in old.removeFromSuperview() })
                } else { old.removeFromSuperview() }
            }
            var x: CGFloat = 4
            for btn in group {
                let target = CGRect(x: x, y: 0, width: 40, height: 44)
                if btn.superview !== g.contentView {
                    g.contentView.addSubview(btn)
                    btn.transform = .identity
                    btn.frame = target
                    if animated && reused { btn.alpha = 0; btn.transform = CGAffineTransform(scaleX: 0.3, y: 0.3) }   // grows out of it
                }
                groupMoves.append((btn, target))
                x += 40
            }
            let width = x + 4
            if !reused {
                g.bounds = CGRect(x: 0, y: 0, width: width, height: 44)
                if animated { appearing.append(g) }
            } else {
                g.tag = Int(width)                        // the new width; applied in the animation below
            }
            if group.count > 1 && (g.gestureRecognizers ?? []).isEmpty {   // hold and slide: a glass lens picks between them
                let lp = UILongPressGestureRecognizer(target: self, action: #selector(pillPress(_:)))
                lp.minimumPressDuration = 0.22
                g.addGestureRecognizer(lp)
            }
            if g.superview !== topItems { topItems.addSubview(g) }
            actionViews.append(g)
            group = []
        }
        for (i, a) in headActions.enumerated() {
            let sym = (a["symbol"] as? String) ?? "circle", label = (a["label"] as? String) ?? ""
            let isText = (a["text"] as? Bool) ?? false, prominent = (a["prominent"] as? Bool) ?? false, on = (a["on"] as? Bool) ?? false
            if isText {
                flush()
                let key = "t|\(sym)|\(label)|\(prominent)"
                if let b = oldTexts[key], kept.contains(where: { $0 === b }) {
                    b.tag = i
                    actionViews.append(b)
                } else {
                    let b = UIButton(type: .system)
                    b.tag = i
                    b.accessibilityIdentifier = key
                    b.addTarget(self, action: #selector(headTap(_:)), for: .touchUpInside)
                    textButton(b, sym, label, prominent)
                    topItems.addSubview(b)
                    actionViews.append(b)
                    appearing.append(b)
                }
            } else {
                let b = oldButtons.removeValue(forKey: sym) ?? UIButton(type: .system)
                b.removeTarget(nil, action: nil, for: .allEvents)
                b.tag = i
                b.accessibilityIdentifier = sym
                b.addTarget(self, action: #selector(headTap(_:)), for: .touchUpInside)
                var c = UIButton.Configuration.plain()
                c.image = UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
                c.baseForegroundColor = on ? tint : .white
                b.configuration = c
                group.append(b)
            }
        }
        flush()
        if oldGroup != nil && !usedOld, let og = oldGroup {      // no capsule on the new page: shrink the old one away
            if animated {
                UIView.animate(withDuration: 0.25, animations: { og.alpha = 0; og.transform = CGAffineTransform(scaleX: 0.4, y: 0.4) }, completion: { _ in og.removeFromSuperview() })
            } else { og.removeFromSuperview() }
        }
        guard animated else {
            for (btn, target) in groupMoves { btn.alpha = 1; btn.transform = .identity; btn.frame = target }
            for v in actionViews where v.tag > 0 && v is UIVisualEffectView { v.bounds = CGRect(x: 0, y: 0, width: CGFloat(v.tag), height: 44); v.tag = 0 }
            return
        }
        let before = kept.map { ($0, $0.center) }
        UIView.performWithoutAnimation {
            self.layoutTop(self.root.bounds, self.root.safeAreaInsets)      // everything at its new place…
            for (v, c) in before { v.center = c }                            // …except what's kept, which glides there
        }
        for v in appearing { v.alpha = 0; v.transform = CGAffineTransform(scaleX: 0.6, y: 0.6) }
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.3, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            for v in self.actionViews where v.tag > 0 && v is UIVisualEffectView {
                v.bounds = CGRect(x: 0, y: 0, width: CGFloat(v.tag), height: 44)    // the capsule stretches / shrinks
                v.tag = 0
            }
            for (btn, target) in groupMoves { btn.transform = .identity; btn.frame = target; btn.alpha = 1 }
            for v in appearing { v.alpha = 1; v.transform = .identity }
            self.layoutTop(self.root.bounds, self.root.safeAreaInsets)               // and slides to its new place
        })
    }

    @objc func backTap() { Haptics.tap(); plugin?.send("back") }

    /// Hold the top-bar pill: a glass lens appears over the button under your finger and follows it; let go to pick.
    @objc func pillPress(_ g: UILongPressGestureRecognizer) {
        guard let group = g.view as? UIVisualEffectView else { return }
        let content = group.contentView
        let buttons = content.subviews.compactMap { $0 as? UIButton }.sorted { $0.frame.minX < $1.frame.minX }
        guard !buttons.isEmpty else { return }
        let p = g.location(in: content)
        func nearest() -> Int {
            var best = 0, bestD = CGFloat.greatestFiniteMagnitude
            for (i, b) in buttons.enumerated() { let d = abs(b.frame.midX - p.x); if d < bestD { bestD = d; best = i } }
            return best
        }
        let i = nearest()
        let size: CGFloat = 40
        let cx = min(max(p.x, buttons.first!.frame.midX), buttons.last!.frame.midX)
        let centerInRoot = content.convert(CGPoint(x: cx, y: content.bounds.midY), to: root)
        switch g.state {
        case .began:
            pillPick = i
            Haptics.tick()
            root.bringSubviewToFront(pillLens)
            pillLens.transform = .identity
            pillLens.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            pillLens.center = content.convert(CGPoint(x: buttons[i].frame.midX, y: content.bounds.midY), to: root)
            pillLens.begin(source: content)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.pillLens.alpha = 1
                self.pillLens.center = centerInRoot
                self.pillLens.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
                self.pillLens.layoutIfNeeded()
                self.pillLens.updateMirror()
            }
        case .changed:
            if i != pillPick { pillPick = i; Haptics.tick() }
            pillLens.center = centerInRoot
            pillLens.updateMirror()
        case .ended:
            let b = buttons[i]
            let land = content.convert(CGPoint(x: b.frame.midX, y: content.bounds.midY), to: root)
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
                self.pillLens.center = land
                self.pillLens.transform = .identity
                self.pillLens.layoutIfNeeded()
                self.pillLens.updateMirror()
            })
            UIView.animate(withDuration: 0.25, delay: 0.15, options: [.allowUserInteraction, .beginFromCurrentState], animations: { self.pillLens.alpha = 0 })
            headTap(b)
        default:
            UIView.animate(withDuration: 0.2) { self.pillLens.alpha = 0; self.pillLens.transform = .identity }
        }
    }
    @objc func headTap(_ b: UIButton) { Haptics.tap(); plugin?.send("headAction", ["id": b.tag]) }

    func tabFrame(_ id: String) -> CGRect? {
        guard let i = tabs.firstIndex(where: { $0["id"] == id }), i < tabButtons.count else { return nil }
        return restFrame(tabButtons[i])
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
        if let v = s["covered"] as? Bool, v != covered {        // a web sheet is open: step aside so it isn't hidden
            covered = v
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.layout(animated: false) }
        }
        if let v = s["visible"] as? Bool {
            if v != visible {
                visible = v
                if v { showChrome(bounce: (s["bounce"] as? Bool) ?? false) } else { hideChrome() }
            } else if v && ((s["bounce"] as? Bool) ?? false) {
                showChrome(bounce: true)                 // already faded back in by the shrink: just the landing bounce
            }
        }
        if retab { retint(); placeLens(animated: true) }
        if relayout { layout(animated: true) }
    }

    var chromeViews: [UIView] { landscape ? [pillGlass, miniGlass] : [dockGlass] }

    /// fade everything that floats over the app (the player's grow / shrink drives this frame by frame)
    func fade(_ a: CGFloat) {
        if a > 0.001 && !visible {                 // coming back: make sure it's laid out and visible underneath the fade
            visible = true
            for v in chromeViews { v.transform = .identity }
            layout(animated: false)
        }
        UIView.performWithoutAnimation { root.alpha = a }
    }

    func hideChrome() {
        if root.alpha < 1 { return }               // already faded out by the grow animation
        UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState]) {
            for v in self.chromeViews { v.alpha = 0; v.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
            for v in [self.topGlass, self.topTitle, self.topItems] as [UIView] { v.alpha = 0 }
        }
    }

    func showChrome(bounce: Bool) {
        UIView.performWithoutAnimation { root.alpha = 1 }
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
    @objc func prevTap() { Haptics.tap(); plugin?.send("prev") }
    @objc func playTap() { Haptics.press(); plugin?.send("toggle") }
    @objc func nextTap() { Haptics.tap(); plugin?.send("next") }
    @objc func miniTap() { Haptics.soft(); plugin?.send("open") }

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
                if t.y < -8 && abs(t.y) > abs(t.x) * 1.2 && hasSong { panMode = 2; Haptics.soft(); plugin?.send("dragStart") }
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
                if commit { Haptics.tap() }
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
            let f = lensFrame(for: restFrame(tabButtons[i]))
            var c = CGPoint(x: f.midX, y: f.midY)
            if land { c.y = min(max(p.y, tabButtons.first!.frame.midY), tabButtons.last!.frame.midY) }
            else { c.x = min(max(p.x, tabButtons.first!.frame.midX), tabButtons.last!.frame.midX) }
            if g.state == .began { haptic.prepare() }
            if (lens.tag != i) { lens.tag = i; haptic.selectionChanged() }
            if g.state == .began {                     // the glass lens appears where the highlight is, then follows the finger
                lens.backgroundColor = .clear              // (so the magnified picture doesn't include the resting highlight)
                lens.layer.borderColor = UIColor.clear.cgColor
                root.bringSubviewToFront(lensGlass)
                lensGlass.transform = .identity
                lensGlass.bounds = lens.bounds
                lensGlass.center = tabsRow.convert(lens.center, to: root)
                lensGlass.begin(source: tabsRow)
            }
            let cRoot = tabsRow.convert(c, to: root)
            UIView.animate(withDuration: g.state == .began ? 0.35 : 0.12, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.lens.bounds = CGRect(origin: .zero, size: f.size)
                self.lens.center = c
                self.lens.layer.cornerRadius = min(f.width, f.height) / 2
                self.lens.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                self.lens.backgroundColor = UIColor.white.withAlphaComponent(0)   // only the clear glass while dragging
                self.lens.layer.borderColor = UIColor.clear.cgColor
                self.lensGlass.bounds = CGRect(origin: .zero, size: f.size)
                self.lensGlass.center = cRoot
                self.lensGlass.transform = CGAffineTransform(scaleX: 1.22, y: 1.22)   // lifted, a bit bigger than the tab
                self.lensGlass.alpha = 1
                self.lensGlass.layoutIfNeeded()
                self.lensGlass.updateMirror()
            }
        case .ended:
            let i = nearest()
            settleGlass(on: i)
            UIView.animate(withDuration: 0.4, delay: 0.15, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.lens.transform = .identity
                self.lens.backgroundColor = UIColor.white.withAlphaComponent(0.14)
                self.lens.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
            }
            if i < tabs.count, let id = tabs[i]["id"] {
                tab = id
                retint()
                placeLens(animated: true)
                plugin?.send("tab", ["id": id])
            }
        default:
            settleGlass(on: tabs.firstIndex(where: { $0["id"] == tab }) ?? 0)
            UIView.animate(withDuration: 0.3) { self.lens.transform = .identity }
            placeLens(animated: true)
        }
    }

    /// Let go: the glass bubble drops into the chosen tab, shrinks and melts into the resting highlight.
    func settleGlass(on i: Int) {
        guard i < tabButtons.count else { return }
        let f = lensFrame(for: restFrame(tabButtons[i]))
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            self.lensGlass.bounds = CGRect(origin: .zero, size: f.size)
            self.lensGlass.center = self.tabsRow.convert(CGPoint(x: f.midX, y: f.midY), to: self.root)
            self.lensGlass.transform = .identity
            self.lensGlass.layoutIfNeeded()
            self.lensGlass.updateMirror()
        })
        UIView.animate(withDuration: 0.3, delay: 0.12, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            self.lensGlass.alpha = 0
        })
    }
}
// ===== AuraOS native chrome (end) =====
