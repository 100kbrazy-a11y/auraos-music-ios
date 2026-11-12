// ===== AuraOS native chrome (begin) =====
// Real iOS 26 Liquid Glass for the parts of the app that float over everything: the media bar + tabs bubble
// (upright), the tab pill + media bubble (sideways), and the song menus / dialogs (system alerts are glass on iOS 26).
// The web screens keep running underneath and tell this what to show; taps, swipes and drags here are sent back.

import UIKit
import Capacitor
import WebKit
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
        CAPPluginMethod(name: "header", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "settings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progressShow", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "libraryPath", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "copyIn", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progressUpdate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progressHide", returnType: CAPPluginReturnPromise),
    ]
    var progressPanel: ProgressPanel?
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
        DispatchQueue.main.async { self.chrome?.setHeader(title: title, back: back, scrolled: scrolled, actions: actions) }
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
        if #available(iOS 26.0, *) { c.effect = UIGlassEffect(style: .regular) } else { c.effect = UIBlurEffect(style: .systemThickMaterialDark) }
        card = c
        dim.frame = host.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dim.alpha = 0
        host.addSubview(dim)
        card.clipsToBounds = true
        card.layer.cornerRadius = 30
        card.layer.cornerCurve = .continuous
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
    let lensGlass = UIVisualEffectView(effect: nil)   // the clear glass bubble over the tabs while your finger is on them
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
            g.tintColor = tint.withAlphaComponent(0.12)      // a little of the song's colour (kept light so the glass stays clear)
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
        lensGlass.isUserInteractionEnabled = false
        lensGlass.clipsToBounds = true
        lensGlass.layer.cornerCurve = .continuous
        lensGlass.alpha = 0
        if #available(iOS 26.0, *) {
            let g = UIGlassEffect(style: .clear)          // clear glass: bends and brightens the icons and titles under it
            g.isInteractive = true
            lensGlass.effect = g
        } else {
            lensGlass.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            lensGlass.layer.borderWidth = 0.5
            lensGlass.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        }
        root.addSubview(lensGlass)                        // above the bubble (glass nested inside glass turns milky)
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
            if magnified < 0 { tb.transform = .identity }
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
        pillGlass.layer.cornerRadius = 34
        tabsRow.frame = pillGlass.bounds
        for (i, tb) in tabButtons.enumerated() {
            if magnified < 0 { tb.transform = .identity }
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
        if let bb = backBtn { bb.frame = CGRect(x: left, y: y, width: 44, height: 44); left += 54 }
        var right = b.width - safe.right - 12 - (landscape ? 80 : 0)     // sideways: stay clear of the tab pill
        for v in actionViews.reversed() {
            let w = v.bounds.width
            v.frame = CGRect(x: right - w, y: y, width: w, height: 44)
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

    func setHeader(title: String, back: Bool, scrolled: Bool, actions: [[String: Any]]) {
        let key = "\(back)|" + actions.map { "\($0["symbol"] ?? "")/\($0["label"] ?? "")/\($0["text"] ?? "")/\($0["prominent"] ?? "")/\($0["on"] ?? "")" }.joined(separator: ",")
        headTitle = title
        topTitle.text = title
        let scrollChanged = scrolled != headScrolled
        headScrolled = scrolled
        if key != headKey {
            headKey = key
            headBack = back
            headActions = actions
            rebuildHeader()
        }
        if scrollChanged {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) { self.layout(animated: false) }
        } else { layout(animated: false) }
    }

    func rebuildHeader() {
        for v in topItems.subviews { v.removeFromSuperview() }
        actionViews = []
        backBtn = nil
        if headBack {
            let b = UIButton(type: .system)
            symbolButton(b, "chevron.backward", size: 17, glass: true)
            b.addTarget(self, action: #selector(backTap), for: .touchUpInside)
            topItems.addSubview(b)
            backBtn = b
        }
        var group: [UIButton] = []
        func flush() {                                   // icon buttons side by side share one glass capsule, like iOS 26
            guard !group.isEmpty else { return }
            let g = GlassChrome.glass()
            g.effect = glassEffect(interactive: true)
            var x: CGFloat = 4
            for btn in group {
                btn.frame = CGRect(x: x, y: 0, width: 40, height: 44)
                g.contentView.addSubview(btn)
                x += 40
            }
            g.bounds = CGRect(x: 0, y: 0, width: x + 4, height: 44)
            g.layer.cornerRadius = 22
            topItems.addSubview(g)
            actionViews.append(g)
            group = []
        }
        for (i, a) in headActions.enumerated() {
            let sym = (a["symbol"] as? String) ?? "circle", label = (a["label"] as? String) ?? ""
            let isText = (a["text"] as? Bool) ?? false, prominent = (a["prominent"] as? Bool) ?? false, on = (a["on"] as? Bool) ?? false
            let b = UIButton(type: .system)
            b.tag = i
            b.addTarget(self, action: #selector(headTap(_:)), for: .touchUpInside)
            if isText {
                flush()
                textButton(b, sym, label, prominent)
                topItems.addSubview(b)
                actionViews.append(b)
            } else {
                var c = UIButton.Configuration.plain()
                c.image = UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
                c.baseForegroundColor = on ? tint : .white
                b.configuration = c
                group.append(b)
            }
        }
        flush()
    }

    @objc func backTap() { plugin?.send("back") }
    @objc func headTap(_ b: UIButton) { plugin?.send("headAction", ["id": b.tag]) }

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
            for v in [self.topGlass, self.topTitle, self.topItems] as [UIView] { v.alpha = 0 }
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

    /// The tab under the glass bubble grows a little, like it's seen through a lens.
    func magnify(_ i: Int) {
        guard i != magnified else { return }
        magnified = i
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            for (j, b) in self.tabButtons.enumerated() {
                b.transform = j == i ? CGAffineTransform(scaleX: 1.16, y: 1.16) : .identity
            }
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
            if g.state == .began {                     // the glass bubble appears where the highlight is, then follows the finger
                root.bringSubviewToFront(lensGlass)
                lensGlass.transform = .identity
                lensGlass.bounds = lens.bounds
                lensGlass.center = tabsRow.convert(lens.center, to: root)
                lensGlass.layer.cornerRadius = lens.layer.cornerRadius
            }
            let cRoot = tabsRow.convert(c, to: root)
            magnify(i)
            UIView.animate(withDuration: g.state == .began ? 0.35 : 0.12, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.lens.bounds = CGRect(origin: .zero, size: f.size)
                self.lens.center = c
                self.lens.layer.cornerRadius = min(f.width, f.height) / 2
                self.lens.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                self.lens.backgroundColor = UIColor.white.withAlphaComponent(0)   // only the clear glass while dragging
                self.lens.layer.borderColor = UIColor.clear.cgColor
                self.lensGlass.bounds = CGRect(origin: .zero, size: f.size)
                self.lensGlass.center = cRoot
                self.lensGlass.layer.cornerRadius = min(f.width, f.height) / 2
                self.lensGlass.transform = CGAffineTransform(scaleX: 1.22, y: 1.22)   // lifted, a bit bigger than the tab
                self.lensGlass.alpha = 1
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
        magnify(-1)
        guard i < tabButtons.count else { return }
        let f = lensFrame(for: restFrame(tabButtons[i]))
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            self.lensGlass.bounds = CGRect(origin: .zero, size: f.size)
            self.lensGlass.center = self.tabsRow.convert(CGPoint(x: f.midX, y: f.midY), to: self.root)
            self.lensGlass.layer.cornerRadius = min(f.width, f.height) / 2
            self.lensGlass.transform = .identity
        })
        UIView.animate(withDuration: 0.3, delay: 0.12, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            self.lensGlass.alpha = 0
        })
    }
}
// ===== AuraOS native chrome (end) =====
