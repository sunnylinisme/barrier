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

struct NearbyComputer { var fingerprint: String; var name: String; var address: String }
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class ShareApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var options = ShareOptions()
    var window: NSWindow!
    let role = NSPopUpButton(), position = NSPopUpButton(), nearby = NSPopUpButton()
    let peerLabel = NSTextField(wrappingLabelWithString: ""), status = NSTextField(wrappingLabelWithString: ""), positionHint = NSTextField(labelWithString: "由主控端設定")
    let start = NSButton(title: "恢復連線", target: nil, action: nil), stop = NSButton(title: "暫停", target: nil, action: nil), search = NSButton(title: "重新搜尋", target: nil, action: nil), pair = NSButton(title: "邀請配對", target: nil, action: nil), forget = NSButton(title: "解除配對", target: nil, action: nil), clear = NSButton(title: "清除檔案暫存", target: nil, action: nil)
    let details = NSTextView()
    var tray: NSStatusItem!, core: Process?, corePipe: Pipe?, link: Process?, linkOutput: Pipe?, linkInput: Pipe?, pendingCore = Data(), pendingLink = Data(), retry: Timer?
    var computers: [NearbyComputer] = [], savedPeer = "", connectedAddress = "", consent: NSAlert?, consentId: String?, enabled = true, loading = true, promptedPermissions = false
    let test: Bool
    init(test: Bool = false) { self.test = test; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) { buildWindow() }
    func buildWindow() {
        let menu = NSMenu(), appMenu = NSMenu(), appItem = NSMenuItem()
        appMenu.addItem(withTitle: "結束 Barrier Share", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Barrier Share · 附近電腦"; window.delegate = self; window.isReleasedWhenClosed = false
        window.contentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 760, height: 650)); window.contentView!.wantsLayer = true; window.contentView!.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        func at(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) { view.frame = NSRect(x: x, y: y, width: width, height: height); window.contentView!.addSubview(view) }
        func label(_ text: String, _ y: CGFloat, title: Bool = false) { let l = NSTextField(labelWithString: text); l.font = title ? .boldSystemFont(ofSize: 20) : .systemFont(ofSize: 14); at(l, 24, y, 710, 28) }
        label("選擇附近電腦，配對後自動連線", 20, title: true)
        label("這台電腦", 72); at(role, 150, 66, 580, 32); role.addItems(withTitles: ["主控端 — 滑鼠與鍵盤接在這台", "接收端 — 同意邀請後即可使用"])
        label("附近電腦", 116); at(nearby, 150, 110, 440, 32); at(search, 600, 110, 130, 32)
        label("接收端位置", 160); at(position, 150, 154, 580, 32); position.addItems(withTitles: ["主控端右方", "主控端左方", "主控端上方", "主控端下方"]); at(positionHint, 150, 160, 580, 28)
        peerLabel.maximumNumberOfLines = 2; at(peerLabel, 24, 206, 710, 44)
        status.textColor = .systemBlue; status.maximumNumberOfLines = 2; at(status, 24, 258, 710, 44)
        for (button, x, width, action) in [(pair, CGFloat(24), CGFloat(140), #selector(invite)), (start, 172, 130, #selector(resume)), (stop, 310, 80, #selector(pause)), (forget, 398, 120, #selector(forgetPeer)), (clear, 526, 204, #selector(clearCache))] { button.bezelStyle = .rounded; button.target = self; button.action = action; at(button, x, 312, width, 34) }
        search.bezelStyle = .rounded; search.target = self; search.action = #selector(searchNow)
        label("首次核對兩邊的 6 位數短碼，雙方同意後記住這台電腦。", 366)
        label("之後開啟程式便會自動重連，IP 改變也不必重新輸入。", 396)
        label("雙向複製檔案／資料夾；等另一台收到檔案後再貼上。", 426)
        label("Windows：Ctrl+C／V　Mac：⌘C／V　大檔案分段傳送。", 456)
        let permissions = NSButton(title: "Mac 鍵鼠權限設定", target: self, action: #selector(openPermissions)); permissions.bezelStyle = .rounded; at(permissions, 24, 490, 230, 30)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; details.isEditable = false; details.font = .monospacedSystemFont(ofSize: 11, weight: .regular); details.autoresizingMask = [.width]; details.isVerticallyResizable = true
        scroll.documentView = details; at(scroll, 24, 534, 710, 92); details.frame = scroll.bounds
        role.target = self; role.action = #selector(roleChanged); position.target = self; position.action = #selector(positionChanged); nearby.target = self; nearby.action = #selector(selectionChanged)
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); tray.button?.title = "⇄"; let trayMenu = NSMenu()
        trayMenu.addItem(withTitle: "開啟 Barrier Share", action: #selector(showWindow), keyEquivalent: "").target = self; trayMenu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""); tray.menu = trayMenu
        do {
            if !test { let old = Bundle.main.bundleURL.deletingLastPathComponent(); try ShareSettings.importPairing(old, true, replace: false); try ShareSettings.importPairing(old, false, replace: false) }
            options = try ShareSettings.load(); role.selectItem(at: options.host ? 0 : 1); position.selectItem(at: ShareSettings.directions.firstIndex(of: options.position) ?? 0)
            loading = false; try refreshRole()
            if !test { startLink(); retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in if let self = self, self.enabled && self.link == nil { self.startLink() } } }
        } catch { loading = false; showError(error) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func updateControls() { start.isEnabled = !enabled || link == nil; stop.isEnabled = enabled; search.isEnabled = link != nil; pair.isEnabled = options.host && link != nil && nearby.indexOfSelectedItem >= 0 && consent == nil; forget.isEnabled = link != nil && !savedPeer.isEmpty; clear.isEnabled = !enabled && core == nil }
    func refreshRole() throws {
        position.isHidden = !options.host; positionHint.isHidden = options.host; savedPeer = ""; computers.removeAll(); nearby.removeAllItems()
        _ = try ShareSettings.initialize(options.host); try ShareSettings.save(options)
        peerLabel.stringValue = options.host ? "選擇接收端，按「邀請配對」。" : "等待主控端邀請；首次需要你同意。"
        status.stringValue = enabled ? "正在啟用區網搜尋…" : "已暫停"; updateControls()
    }
    func showError(_ error: Error) { status.stringValue = "操作未完成：" + error.localizedDescription }
    @objc func roleChanged() { guard !loading else { return }; stopLink(); stopBackend(); options.host = role.indexOfSelectedItem == 0; do { try refreshRole(); if enabled { startLink() } } catch { showError(error) } }
    @objc func positionChanged() { guard !loading else { return }; options.position = ShareSettings.directions[position.indexOfSelectedItem]; do { try ShareSettings.save(options); if core != nil { stopBackend() } } catch { showError(error) } }
    @objc func selectionChanged() { updateControls() }
    @objc func searchNow() { send("SEARCH"); status.stringValue = "正在搜尋同一區網的電腦…" }
    @objc func invite() { let index = nearby.indexOfSelectedItem; guard index >= 0 && index < computers.count else { return }; stopBackend(); send("PAIR\t" + computers[index].fingerprint); status.stringValue = "正在發出邀請…" }
    @objc func resume() { enabled = true; startLink(); updateControls() }
    @objc func pause() { enabled = false; stopLink(); stopBackend(); status.stringValue = "已暫停；不接受邀請，也不會自動重連。"; updateControls() }
    @objc func openPermissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func startLink() {
        guard link == nil && enabled && !test else { return }
        do {
            _ = try ShareSettings.initialize(options.host)
            let process = Process(), output = Pipe(), input = Pipe(); process.executableURL = ShareSettings.bin.appendingPathComponent("barrier-link")
            process.arguments = [ShareSettings.profile(options.host).path, options.host ? "host" : "receiver", Host.current().localizedName ?? "Mac"]
            process.standardOutput = output; process.standardError = output; process.standardInput = input
            link = process; linkOutput = output; linkInput = input; pendingLink.removeAll()
            output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let data = handle.availableData; if data.isEmpty { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async { guard let self = self, let process = process, self.link === process else { return }; self.consume(data, discovery: true) }
            }
            process.terminationHandler = { [weak self] process in DispatchQueue.main.async { guard let self = self, self.link === process else { return }; self.stopLink(); self.status.stringValue = "搜尋服務已停止，正在重試…" } }
            try process.run(); updateControls()
        } catch { stopLink(); showError(error) }
    }
    func send(_ line: String) { guard let process = link, process.isRunning, let input = linkInput else { return }; do { try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) } catch { showError(error) } }
    func endProcess(_ process: Process?) {
        if let process = process, process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }; process.waitUntilExit() }
    }
    func stopLink() {
        closeConsent(); send("QUIT"); let process = link; link = nil; linkOutput?.fileHandleForReading.readabilityHandler = nil; linkOutput = nil; linkInput = nil
        endProcess(process); computers.removeAll(); nearby.removeAllItems(); updateControls()
    }
    func consume(_ data: Data, discovery: Bool) {
        if discovery {
            pendingLink.append(data); while let newline = pendingLink.firstIndex(of: 10) { let line = String(decoding: pendingLink[..<newline], as: UTF8.self); pendingLink.removeSubrange(...newline); linkLine(line) }
        } else {
            pendingCore.append(data); while let newline = pendingCore.firstIndex(of: 10) { let line = String(decoding: pendingCore[..<newline], as: UTF8.self); pendingCore.removeSubrange(...newline); log(line) }
        }
    }
    func decoded(_ text: String) -> String { Data(base64Encoded: text).map { String(decoding: $0, as: UTF8.self) } ?? "未知電腦" }
    func linkLine(_ line: String) {
        let f = line.components(separatedBy: "\t")
        if f[0] == "READY" { status.stringValue = options.host ? "正在搜尋接收端…" : "可被搜尋，等待主控端邀請…" }
        else if f[0] == "DEVICE" && f.count == 6 {
            let index = nearby.indexOfSelectedItem, selected = nearby.indexOfSelectedItem >= 0 && nearby.indexOfSelectedItem < computers.count ? computers[index].fingerprint : ""
            computers.removeAll { $0.fingerprint == f[1] }; computers.append(NearbyComputer(fingerprint: f[1], name: decoded(f[2]), address: f[3])); computers.sort { $0.name < $1.name }
            nearby.removeAllItems(); nearby.addItems(withTitles: computers.map { $0.name + "  ·  " + $0.address }); if let item = computers.firstIndex(where: { $0.fingerprint == selected }) { nearby.selectItem(at: item) }
        } else if f[0] == "GONE" && f.count == 2 { if let index = computers.firstIndex(where: { $0.fingerprint == f[1] }) { computers.remove(at: index); nearby.removeItem(at: index) } }
        else if (f[0] == "SAVED" || f[0] == "PAIRED") && f.count == 3 {
            if f[0] == "PAIRED" { stopBackend() }; savedPeer = f[1]; peerLabel.stringValue = "已配對：\(decoded(f[2]))\n開啟程式後會自動搜尋並驗證這台電腦。"
        } else if (f[0] == "REQUEST" || f[0] == "VERIFY") && f.count == 5 { showConsent(f) }
        else if f[0] == "CLOSED" && f.count == 2 && consentId == f[1] { closeConsent() }
        else if f[0] == "CONNECT" && f.count == 4 && f[1] == savedPeer {
            if core == nil || (!options.host && connectedAddress != f[3]) { stopBackend(); options.address = f[3]; do { try ShareSettings.save(options); startBackend() } catch { showError(error) } }
        } else if f[0] == "REMOVED" { stopBackend(); savedPeer = ""; peerLabel.stringValue = "已解除配對。"; status.stringValue = options.host ? "可以選擇接收端重新邀請。" : "等待新的配對邀請。" }
        else if (f[0] == "ERROR" || f[0] == "FATAL") && f.count == 2 { status.stringValue = decoded(f[1]); log(status.stringValue) }
        updateControls()
    }
    func showConsent(_ message: [String]) {
        closeConsent(); showWindow(); let alert = NSAlert(), id = message[1]; consent = alert; consentId = id
        alert.messageText = message[0] == "REQUEST" ? "收到配對邀請" : "核對配對碼"
        alert.informativeText = "\(decoded(message[2]))\n請確認另一台顯示相同的 6 位數配對碼。\n\n同意後允許共用鍵盤滑鼠及雙向同步剪貼簿。配對會被記住，之後自動連線。"
        let code = NSTextField(labelWithString: message[4]); code.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold); code.alignment = .center; code.frame = NSRect(x: 0, y: 0, width: 320, height: 52); alert.accessoryView = code
        alert.addButton(withTitle: "拒絕"); alert.addButton(withTitle: "相同，同意"); updateControls()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, self.consentId == id else { return }; self.consent = nil; self.consentId = nil
            self.send((response == .alertSecondButtonReturn ? "ACCEPT\t" : "REJECT\t") + id)
            self.status.stringValue = response == .alertSecondButtonReturn ? "已同意，等待對方確認…" : "已拒絕配對。"; self.updateControls()
        }
    }
    func closeConsent() { let alert = consent; consent = nil; consentId = nil; if let alert = alert { window.endSheet(alert.window, returnCode: .cancel); alert.window.orderOut(nil) } }
    @objc func forgetPeer() {
        let alert = NSAlert(); alert.messageText = "解除配對？"; alert.informativeText = "解除後不會自動連線，需要重新邀請並經對方同意。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "解除")
        if alert.runModal() == .alertSecondButtonReturn { stopBackend(); send("FORGET") }
    }
    func startBackend() {
        guard core == nil && enabled && !test else { return }
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !promptedPermissions] as CFDictionary) {
            promptedPermissions = true; status.stringValue = "配對已完成；請允許 Barrier Share 的「輔助使用」及「輸入監控」，之後會自動連線。"; return
        }
        do {
            let process = try ShareSettings.command(options), output = Pipe(); process.standardOutput = output; process.standardError = output; core = process; corePipe = output; pendingCore.removeAll()
            output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let data = handle.availableData; if data.isEmpty { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async { guard let self = self, let process = process, self.core === process else { return }; self.consume(data, discovery: false) }
            }
            process.terminationHandler = { [weak self] process in DispatchQueue.main.async { guard let self = self, self.core === process else { return }; self.stopBackend(); self.status.stringValue = "連線暫停，會自動重試；詳情見下方紀錄。" } }
            try process.run(); connectedAddress = options.address; status.stringValue = "配對已驗證，正在連線…"; updateControls()
        } catch { stopBackend(); showError(error) }
    }
    func stopBackend() { let process = core; core = nil; corePipe?.fileHandleForReading.readabilityHandler = nil; corePipe = nil; endProcess(process); updateControls() }
    func log(_ line: String) {
        details.string = String((details.string + line + "\n").suffix(20000)); details.scrollToEndOfDocument(nil)
        if line.contains("connected to server") || line.contains("has connected") { status.stringValue = "已連線 · 雙向複製貼上已啟用" }
        if line.contains("file clipboard: sending") { status.stringValue = "正在傳送檔案… 可繼續操作滑鼠與鍵盤" }
        if line.contains("file clipboard: receiving") { status.stringValue = "正在接收檔案… 完成後即可貼上" }
        if line.contains("received and verified") { status.stringValue = "已收到檔案，可在 Finder 資料夾使用 ⌘V 貼上" }
        if line.contains("WARNING") && line.contains("file clipboard:") { status.stringValue = "檔案複製未完成；請查看下方原因。" }
        if line.contains("server is dead") || line.contains("disconnected") { status.stringValue = "連線中斷，正在自動重連…" }
    }
    @objc func clearCache() {
        guard !enabled && core == nil else { return }
        let alert = NSAlert(); alert.messageText = "清除尚未貼上的接收檔案暫存？"; alert.informativeText = "已貼到其他資料夾的檔案不受影響。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.contains(where: { $0.path.hasPrefix(ShareSettings.root.path + "/") }) { board.clearContents() }
            for host in [true, false] { for name in ["ClipboardCache", "FileClipboardCache"] { let path = ShareSettings.profile(host).appendingPathComponent(name); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } } }
            status.stringValue = "已清除接收檔案暫存。"
        } catch { showError(error) }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { enabled = false; retry?.invalidate(); stopLink(); stopBackend(); return .terminateNow }
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
    let peer = "v2:sha256:" + String(repeating: "a", count: 64), name = Data("另一台電腦".utf8).base64EncodedString()
    app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.2\t24801\tR")
    app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.3\t24801\tR")
    guard app.computers.count == 1 && app.computers[0].address == "192.168.1.3" else { throw ShareError.message("Discovery list update failed") }
    app.linkLine("SAVED\t\(peer)\t\(name)")
    app.linkLine("VERIFY\ttest-request\t\(name)\t\(peer)\t123456")
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    guard let sheet = app.consent?.window.contentView, let sheetBitmap = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { throw ShareError.message("Missing pairing dialog") }
    sheet.cacheDisplay(in: sheet.bounds, to: sheetBitmap)
    try sheetBitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("gui-pairing.png"))
    app.linkLine("CLOSED\ttest-request")
    guard app.consent == nil && app.consentId == nil else { throw ShareError.message("Expired pairing dialog remained open") }
    app.linkLine("GONE\t\(peer)"); guard app.computers.isEmpty else { throw ShareError.message("Offline peer remained listed") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3)); app.window.displayIfNeeded()
    guard let view = app.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShareError.message("Cannot render window") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.representation(using: .png, properties: [:]) else { throw ShareError.message("Cannot render PNG") }
    try image.write(to: directory.appendingPathComponent("gui-mac.png"))
    app.window.orderOut(nil); NSStatusBar.system.removeStatusItem(app.tray)
    try "PASS: both pairing roles, saved IP/position, four screen directions, bundled backends and native GUI render".write(to: directory.appendingPathComponent("PASS.txt"), atomically: true, encoding: .utf8)
}

signal(SIGPIPE, SIG_IGN)
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
