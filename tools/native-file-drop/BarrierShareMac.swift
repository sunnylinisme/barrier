// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ApplicationServices
import Foundation

struct ShareOptions: Codable {
    var host = true
    var address = ""
    var position = "right"
}
enum ShareError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
final class ShareSettings {
    static let directions = ["right", "left", "up", "down"]
    static var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BarrierShare", isDirectory: true)
    static var bin: URL {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }
        return Bundle.main.executableURL!.deletingLastPathComponent()
    }
    static func profile(_ host: Bool) -> URL { root.appendingPathComponent(host ? "profile-server" : "profile", isDirectory: true) }
    static func run(_ name: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = bin.appendingPathComponent(name); process.arguments = arguments
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 15) == .timedOut { process.terminate(); throw ShareError.message("設定工具未回應。") }
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 && !allowFailure { throw ShareError.message(result) }
        return result
    }
    static func initialize(_ host: Bool) throws -> String { try run("barrier-pair", ["init", profile(host).path]) }
    static func save(_ options: ShareOptions) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(options).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }
    static func load() throws -> ShareOptions {
        let path = root.appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: path.path) { return ShareOptions() }
        var options = try JSONDecoder().decode(ShareOptions.self, from: Data(contentsOf: path))
        if !directions.contains(options.position) { options.position = "right" }
        return options
    }
    static func config(_ direction: String) throws -> String {
        guard let index = directions.firstIndex(of: direction) else { throw ShareError.message("請選擇有效的螢幕位置。") }
        let opposite = ["left", "right", "down", "up"][index]
        return "section: screens\n windows-host:\n windows:\nend\nsection: links\n windows-host:\n  \(direction) = windows\n windows:\n  \(opposite) = windows-host\nend\nsection: options\n clipboardSharing = true\nend\n"
    }
    static func command(_ options: ShareOptions) throws -> Process {
        let p = profile(options.host), process = Process()
        process.executableURL = bin.appendingPathComponent(options.host ? "barriers" : "barrierc")
        var args = ["-f", "--no-tray", "--file-clipboard", "--profile-dir", p.path, "--log", p.appendingPathComponent(options.host ? "server.log" : "mac.log").path, "--name", options.host ? "windows-host" : "windows"]
        if options.host {
            let path = p.appendingPathComponent("screens.conf")
            try config(options.position).write(to: path, atomically: true, encoding: .utf8)
            args += ["-c", path.path]
        } else {
            var ip = in_addr()
            guard options.address.withCString({ inet_pton(AF_INET, $0, &ip) }) == 1 else { throw ShareError.message("請輸入主控端的區網 IPv4 位址，例如 192.168.1.20。") }
            args += [options.address]
        }
        process.arguments = args; process.standardInput = FileHandle.nullDevice
        return process
    }
    static func trustedPath(_ host: Bool) -> URL { profile(host).appendingPathComponent("SSL/Fingerprints/" + (host ? "TrustedClients.txt" : "TrustedServers.txt")) }
    static func trusted(_ host: Bool, _ fingerprint: String) -> Bool {
        let lines = (try? String(contentsOf: trustedPath(host), encoding: .utf8)) ?? ""
        return lines.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == fingerprint }
    }
    static func trust(_ host: Bool, _ fingerprint: String) throws { _ = try run("barrier-pair", ["trust", profile(host).path, host ? "client" : "server", fingerprint]) }
    @discardableResult static func importPairing(_ old: URL, _ host: Bool, replace: Bool) throws -> Bool {
        let fm = FileManager.default
        let candidates = [old.appendingPathComponent(host ? "profile-server/SSL" : "profile/SSL"), old.appendingPathComponent("profile/SSL"), old.appendingPathComponent("SSL")]
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("Barrier.pem").path) }) else { return false }
        let target = profile(host).appendingPathComponent("SSL", isDirectory: true)
        if source.standardizedFileURL == target.standardizedFileURL { return false }
        if fm.fileExists(atPath: target.appendingPathComponent("Barrier.pem").path) && !replace { return false }
        if let entries = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in entries {
                if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ShareError.message("配對資料夾不可使用符號連結。") }
            }
        }
        try fm.createDirectory(at: profile(host), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = profile(host).appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging.appendingPathComponent("SSL"))
        _ = try run("barrier-pair", ["init", staging.path])
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: profile(host).appendingPathComponent("SSL.backup-" + UUID().uuidString)) }
        try fm.moveItem(at: staging.appendingPathComponent("SSL"), to: target)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.appendingPathComponent("Barrier.pem").path)
        return true
    }
    static func localAddresses() -> String {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return "請查看系統網路設定" }
        defer { freeifaddrs(first) }
        var addresses: [String] = [], item = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host); if !value.hasPrefix("127.") { addresses.append(value) }
            }
        }
        return addresses.joined(separator: "、")
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class ShareApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    var options = ShareOptions()
    var window: NSWindow!
    let role = NSPopUpButton(), position = NSPopUpButton(), address = NSTextField()
    let addresses = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: ""), fingerprint = NSTextField(wrappingLabelWithString: ""), positionHint = NSTextField(labelWithString: "由主控端設定")
    let start = NSButton(title: "開始連線", target: nil, action: nil), stop = NSButton(title: "停止", target: nil, action: nil), importButton = NSButton(title: "沿用舊版配對", target: nil, action: nil), clear = NSButton(title: "清除檔案暫存", target: nil, action: nil)
    let details = NSTextView()
    var tray: NSStatusItem!, core: Process?, pipe: Pipe?, pending = Data(), prompted = Set<String>(), loading = true
    let test: Bool
    init(test: Bool = false) { self.test = test; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) { buildWindow() }
    func buildWindow() {
        let menu = NSMenu(), appMenu = NSMenu(), appItem = NSMenuItem()
        appMenu.addItem(withTitle: "結束 Barrier Share", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Barrier Share · Windows／Mac 通用測試版"; window.delegate = self; window.isReleasedWhenClosed = false
        window.contentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 760, height: 650))
        window.contentView!.wantsLayer = true
        window.contentView!.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        func at(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) { view.frame = NSRect(x: x, y: y, width: width, height: height); window.contentView!.addSubview(view) }
        func label(_ text: String, _ y: CGFloat, title: Bool = false) { let l = NSTextField(labelWithString: text); l.font = title ? .boldSystemFont(ofSize: 20) : .systemFont(ofSize: 14); at(l, 24, y, 710, 28) }
        label("兩台電腦，共用鍵鼠與雙向複製貼上", 20, title: true)
        label("這台電腦", 72); at(role, 150, 66, 580, 32)
        role.addItems(withTitles: ["主控端 — 滑鼠與鍵盤接在這台", "接收端 — 使用另一台的滑鼠與鍵盤"])
        label("主控端 IP", 112); at(address, 150, 108, 580, 28); address.delegate = self; address.placeholderString = "例如 192.168.1.20"
        label("接收端位置", 154); at(position, 150, 148, 580, 32); position.addItems(withTitles: ["主控端右方", "主控端左方", "主控端上方", "主控端下方"]); at(positionHint, 150, 154, 580, 28)
        addresses.maximumNumberOfLines = 2; addresses.isSelectable = true; at(addresses, 24, 194, 710, 45)
        status.textColor = .systemBlue; status.maximumNumberOfLines = 2; at(status, 24, 246, 710, 42)
        for (button, x, width, action) in [(start, CGFloat(24), CGFloat(120), #selector(startBackend)), (stop, 152, 72, #selector(stopClicked)), (importButton, 232, 146, #selector(importPairing)), (clear, 548, 182, #selector(clearCache))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action; at(button, x, 294, width, 34)
        }
        let permissions = NSButton(title: "權限設定", target: self, action: #selector(openPermissions)); permissions.bezelStyle = .rounded; at(permissions, 386, 294, 154, 34)
        label("本機識別碼（首次配對時供另一台核對）", 350)
        fingerprint.font = .monospacedSystemFont(ofSize: 12, weight: .regular); fingerprint.isSelectable = true; fingerprint.maximumNumberOfLines = 3; at(fingerprint, 24, 380, 710, 50)
        label("選取檔案／資料夾 → 複製 → 移到另一台 → 等接收完成後貼上", 446)
        label("Windows 使用 Ctrl+C／V；Mac 使用 ⌘C／V。兩個方向都保留原檔。", 473)
        label("大檔案分段傳送；檔案大小以可用磁碟空間為準。", 500)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        details.isEditable = false; details.font = .monospacedSystemFont(ofSize: 11, weight: .regular); details.autoresizingMask = [.width]; details.isVerticallyResizable = true
        scroll.documentView = details; at(scroll, 24, 536, 710, 90); details.frame = scroll.bounds
        role.target = self; role.action = #selector(roleChanged); position.target = self; position.action = #selector(positionChanged)
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); tray.button?.title = "⇄"; let trayMenu = NSMenu()
        trayMenu.addItem(withTitle: "開啟 Barrier Share", action: #selector(showWindow), keyEquivalent: "").target = self
        trayMenu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""); tray.menu = trayMenu
        do {
            if !test {
                let old = Bundle.main.bundleURL.deletingLastPathComponent()
                try ShareSettings.importPairing(old, true, replace: false); try ShareSettings.importPairing(old, false, replace: false)
            }
            options = try ShareSettings.load(); role.selectItem(at: options.host ? 0 : 1); address.stringValue = options.address
            position.selectItem(at: ShareSettings.directions.firstIndex(of: options.position) ?? 0)
            loading = false; try refreshRole()
        } catch { loading = false; showError(error) }
        stop.isEnabled = false; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func refreshRole() throws {
        address.isEnabled = !options.host; position.isHidden = !options.host; positionHint.isHidden = options.host
        fingerprint.stringValue = try ShareSettings.initialize(options.host)
        addresses.stringValue = options.host ? "接收端請填這台的區網 IP：\(ShareSettings.localAddresses())\n接收端的位置由上方選單設定。" : "填入主控端的區網 IP 後連線；兩台可使用 Windows 或 Mac。"
        status.stringValue = FileManager.default.fileExists(atPath: ShareSettings.trustedPath(options.host).path) ? "已保留配對資料，按「開始連線」即可。" : "尚未配對；首次連線時會顯示對方識別碼供核對。"
        try ShareSettings.save(options)
    }
    func showError(_ error: Error) {
        status.stringValue = "操作未完成：" + error.localizedDescription
        if !test { let alert = NSAlert(); alert.messageText = "Barrier Share"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
    @objc func roleChanged() { guard !loading else { return }; options.host = role.indexOfSelectedItem == 0; do { try refreshRole() } catch { showError(error) } }
    @objc func positionChanged() { guard !loading else { return }; options.position = ShareSettings.directions[position.indexOfSelectedItem]; do { try ShareSettings.save(options) } catch { showError(error) } }
    func controlTextDidChange(_ notification: Notification) { if !loading { options.address = address.stringValue.trimmingCharacters(in: .whitespaces); try? ShareSettings.save(options) } }
    @objc func openPermissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func startBackend() {
        guard core == nil else { return }
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            status.stringValue = "請先在系統設定允許 Barrier Share 的「輔助使用」與「輸入監控」，再開始連線。"; return
        }
        do {
            _ = try ShareSettings.initialize(options.host); try ShareSettings.save(options); prompted.removeAll(); pending.removeAll()
            let process = try ShareSettings.command(options), output = Pipe(); process.standardOutput = output; process.standardError = output
            core = process; pipe = output
            output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let bytes = handle.availableData; if bytes.isEmpty { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async { guard let self = self, let process = process, self.core === process else { return }; self.consume(bytes) }
            }
            process.terminationHandler = { [weak self] process in DispatchQueue.main.async { guard let self = self, self.core === process else { return }; self.stopBackend(); self.status.stringValue = "連線程式已停止，請查看下方紀錄；若權限不足，請開啟「權限設定」。" } }
            try process.run(); setRunning(true); status.stringValue = options.host ? "等待接收端連線…" : "正在連線…"
        } catch { stopBackend(); showError(error) }
    }
    func setRunning(_ running: Bool) { start.isEnabled = !running; stop.isEnabled = running; role.isEnabled = !running; position.isEnabled = !running; address.isEnabled = !running && !options.host; importButton.isEnabled = !running; clear.isEnabled = !running }
    func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) { let line = String(decoding: pending[..<newline], as: UTF8.self); pending.removeSubrange(...newline); log(line) }
    }
    func log(_ line: String) {
        details.string = String((details.string + line + "\n").suffix(20000)); details.scrollToEndOfDocument(nil)
        if line.contains("connected to server") || line.contains("has connected") { status.stringValue = "已連線 · 雙向複製貼上已啟用" }
        if line.contains("file clipboard: sending") { status.stringValue = "正在傳送檔案… 可繼續操作滑鼠與鍵盤" }
        if line.contains("file clipboard: receiving") { status.stringValue = "正在接收檔案… 完成後即可貼上" }
        if line.contains("received and verified") { status.stringValue = "已收到檔案，可在 Finder 資料夾使用 ⌘V 貼上" }
        if line.contains("WARNING") && line.contains("file clipboard:") { status.stringValue = "檔案複製未完成；請查看下方原因，修正後重新複製。" }
        if line.contains("server is dead") || line.contains("disconnected") { status.stringValue = "連線中斷，正在重連…" }
        guard let range = line.range(of: "\\(SHA256\\):\\s*([0-9A-Fa-f:]{95})", options: .regularExpression),
              let raw = line[range].split(separator: " ").last else { return }
        let peer = "v2:sha256:" + raw.replacingOccurrences(of: ":", with: "").lowercased()
        if ShareSettings.trusted(options.host, peer) || prompted.contains(peer) { return }; prompted.insert(peer)
        showWindow(); let alert = NSAlert(); alert.messageText = "確認對方電腦"
        alert.informativeText = "請核對另一台視窗的「本機識別碼」是否完全相同：\n\n\(peer)\n\n相同才按「信任」。之後會記住配對，不必重新輸入。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "信任")
        if alert.runModal() == .alertSecondButtonReturn { do { try ShareSettings.trust(options.host, peer); status.stringValue = "已記住對方，等待自動重連…" } catch { showError(error) } }
    }
    @objc func stopClicked() { stopBackend() }
    func stopBackend() {
        let process = core; core = nil; pipe?.fileHandleForReading.readabilityHandler = nil; pipe = nil
        if let process = process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            process.waitUntilExit()
        }
        setRunning(false); status.stringValue = "已停止；設定與配對已保留。"
    }
    @objc func importPairing() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.message = "選擇之前能連線的測試包資料夾（含 profile 或 profile-server）"
        if picker.runModal() == .OK, let path = picker.url {
            do { guard try ShareSettings.importPairing(path, options.host, replace: true) else { throw ShareError.message("找不到舊配對資料，請選原本測試包資料夾。") }; try refreshRole(); status.stringValue = "已沿用舊版配對，不必重貼 v2 識別碼。" }
            catch { showError(error) }
        }
    }
    @objc func clearCache() {
        let alert = NSAlert(); alert.messageText = "清除尚未貼上的接收檔案暫存？"; alert.informativeText = "已貼到其他資料夾的檔案不受影響。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.contains(where: { $0.path.hasPrefix(ShareSettings.root.path + "/") }) { board.clearContents() }
            for host in [true, false] { for name in ["ClipboardCache", "FileClipboardCache"] {
                let path = ShareSettings.profile(host).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            } }
            status.stringValue = "已清除接收檔案暫存。"
        } catch { showError(error) }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { stopBackend(); return .terminateNow }
}

func selfTest(_ directory: URL) throws {
    let fm = FileManager.default; try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["PASS.txt", "FAIL.txt"] { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
    let scratch = directory.appendingPathComponent("run-" + UUID().uuidString)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: scratch) }
    ShareSettings.root = scratch.appendingPathComponent("新設定")
    var options = ShareOptions(); options.host = false; options.address = "192.168.7.4"; options.position = "up"
    try ShareSettings.save(options); let restored = try ShareSettings.load()
    guard !restored.host && restored.address == options.address && restored.position == "up" else { throw ShareError.message("Settings roundtrip failed") }
    for host in [true, false] {
        let old = scratch.appendingPathComponent(host ? "舊主控" : "舊接收"), profile = old.appendingPathComponent(host ? "profile-server" : "profile")
        let fingerprint = try ShareSettings.run("barrier-pair", ["init", profile.path])
        _ = try ShareSettings.run("barrier-pair", ["trust", profile.path, host ? "client" : "server", fingerprint])
        guard try ShareSettings.importPairing(old, host, replace: false), try ShareSettings.initialize(host) == fingerprint, ShareSettings.trusted(host, fingerprint) else { throw ShareError.message("Pairing import failed") }
        if try ShareSettings.importPairing(old, host, replace: false) { throw ShareError.message("Existing pairing overwritten") }
    }
    for direction in ShareSettings.directions {
        let configuration = try ShareSettings.config(direction), opposite = ["left", "right", "down", "up"][ShareSettings.directions.firstIndex(of: direction)!]
        if !configuration.contains("\(direction) = windows\n") || !configuration.contains("\(opposite) = windows-host\n") { throw ShareError.message("Invalid screen topology") }
    }
    for binary in ["barriers", "barrierc"] { if try !ShareSettings.run(binary, ["--help"], allowFailure: true).contains("--file-clipboard") { throw ShareError.message("Missing backend or file clipboard option") } }
    NSApp.finishLaunching()
    let app = ShareApp(test: true); app.buildWindow(); app.options.host = true; app.role.selectItem(at: 0); try app.refreshRole()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3)); app.window.displayIfNeeded()
    guard let view = app.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShareError.message("Cannot render window") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.representation(using: .png, properties: [:]) else { throw ShareError.message("Cannot render PNG") }
    try image.write(to: directory.appendingPathComponent("gui-mac.png"))
    app.window.orderOut(nil); NSStatusBar.system.removeStatusItem(app.tray)
    try "PASS: both pairing roles, saved IP/position, four screen directions, bundled backends and native GUI render".write(to: directory.appendingPathComponent("PASS.txt"), atomically: true, encoding: .utf8)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.appearance = NSAppearance(named: .aqua)
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--self-test" {
    let path = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    do { try selfTest(path); exit(0) }
    catch { try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); try? error.localizedDescription.write(to: path.appendingPathComponent("FAIL.txt"), atomically: true, encoding: .utf8); fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
let delegate = ShareApp()
application.delegate = delegate
application.run()
