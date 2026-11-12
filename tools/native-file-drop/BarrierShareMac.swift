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

// Looks up the newest published Mac release; only the public release list is requested, nothing is sent.
enum ShareUpdate {
    static let releases = URL(string: "https://api.github.com/repos/sunnylinisme/barrier/releases?per_page=30")!
    static let prefix = "mac-v"
    struct Release: Decodable { let tag_name: String; let html_url: String; let draft: Bool?; let prerelease: Bool? }
    static func parts(_ text: String) -> [Int]? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(pieces.count), !pieces.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        return (pieces.map { $0! } + [0, 0]).prefix(3).map { $0 }
    }
    static var current: [Int] { parts(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? [0, 0, 0] }
    // Returns the highest non-draft, non-prerelease Mac release newer than current, or nil.
    static func newer(_ data: Data, current: [Int]) -> (version: String, url: URL)? {
        guard let list = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        var best: ([Int], URL)?
        for release in list where release.draft != true && release.prerelease != true && release.tag_name.hasPrefix(prefix) {
            guard let version = parts(String(release.tag_name.dropFirst(prefix.count))), let url = URL(string: release.html_url),
                  release.html_url.hasPrefix("https://github.com/sunnylinisme/barrier/releases/") else { continue }
            if version.lexicographicallyPrecedes(current) || version == current { continue }
            if best == nil || best!.0.lexicographicallyPrecedes(version) { best = (version, url) }
        }
        guard let best = best else { return nil }
        return (best.0.map(String.init).joined(separator: "."), best.1)
    }
}

final class ShareActionButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor(srgbRed:47/255,green:101/255,blue:235/255,alpha:1)
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:10,yRadius:10)
        (isEnabled ? (isHighlighted ? blue.blended(withFraction:0.18,of:.black)! : blue) : NSColor(srgbRed:230/255,green:236/255,blue:247/255,alpha:1)).setFill(); shape.fill()
        let paragraph=NSMutableParagraphStyle(); paragraph.alignment = .center
        let text=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:15,weight:.semibold),.foregroundColor:isEnabled ? NSColor.white : NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
        text.draw(in:NSRect(x:12,y:(bounds.height-text.size().height)/2,width:bounds.width-24,height:text.size().height))
        if window?.firstResponder === self { NSColor.white.setStroke(); let focus=NSBezierPath(roundedRect:bounds.insetBy(dx:4,dy:4),xRadius:7,yRadius:7); focus.lineWidth=1.5; focus.stroke() }
    }
}
struct NearbyComputer { var fingerprint: String; var name: String; var address: String }
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class ShareApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var options = ShareOptions()
    var window: NSWindow!
    var diagnostics: NSWindow?
    let emptyNearby = NSTextField(wrappingLabelWithString: "正在尋找附近的電腦…\n在另一台開啟程式，並選擇另一個角色。")
    let blue = NSColor(srgbRed: 47/255, green: 101/255, blue: 235/255, alpha: 1), ink = NSColor(srgbRed: 24/255, green: 37/255, blue: 57/255, alpha: 1), muted = NSColor(srgbRed: 109/255, green: 122/255, blue: 141/255, alpha: 1)
    let role = NSPopUpButton(), position = NSPopUpButton(), nearby = NSPopUpButton()
    let peerLabel = NSTextField(wrappingLabelWithString: ""), status = NSTextField(wrappingLabelWithString: ""), positionHint = NSTextField(labelWithString: "由主控端設定")
    let start = NSButton(title: "恢復連線", target: nil, action: nil), stop = NSButton(title: "暫停", target: nil, action: nil), search = NSButton(title: "重新搜尋", target: nil, action: nil), pair = ShareActionButton(title: "邀請配對", target: nil, action: nil), forget = NSButton(title: "解除配對", target: nil, action: nil), clear = NSButton(title: "清除檔案暫存", target: nil, action: nil)
    let details = NSTextView()
    var tray: NSStatusItem!, core: Process?, corePipe: Pipe?, link: Process?, linkOutput: Pipe?, linkInput: Pipe?, pendingCore = Data(), pendingLink = Data(), retry: Timer?
    var computers: [NearbyComputer] = [], savedPeer = "", connectedAddress = "", consent: NSAlert?, consentId: String?, enabled = true, loading = true, promptedPermissions = false
    let network = NSTextField(labelWithString: "●  區域網路"), update = NSButton(title: "", target: nil, action: nil)
    var updateURL: URL?, updateTimer: Timer?
    let test: Bool
    init(test: Bool = false) { self.test = test; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) { buildWindow() }
    func buildWindow() {
        let menu = NSMenu(), appMenu = NSMenu(), appItem = NSMenuItem()
        appMenu.addItem(withTitle: "關於 Barrier Share", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); appMenu.addItem(.separator()); appMenu.addItem(withTitle: "結束 Barrier Share", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Barrier Share \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")".trimmingCharacters(in: .whitespaces); window.delegate = self; window.isReleasedWhenClosed = false
        window.contentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 840, height: 710)); window.contentView!.wantsLayer = true
        window.contentView!.layer?.backgroundColor = NSColor(srgbRed: 244/255, green: 246/255, blue: 250/255, alpha: 1).cgColor
        func at(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) { view.frame = NSRect(x: x, y: y, width: width, height: height); window.contentView!.addSubview(view) }
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat = 14, bold: Bool = false, color: NSColor? = nil) { let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular); l.textColor = color ?? ink; l.lineBreakMode = .byTruncatingTail; at(l,x,y,width,size+14) }
        label("Barrier Share",32,24,550,30,bold:true)
        label("同一張桌面，連上兩台電腦。",34,77,600,14,color:muted)
        network.font = .systemFont(ofSize: 13); network.textColor = blue; network.alignment = .right; at(network,640,42,168,27)
        update.isBordered = false; update.alignment = .right; update.target = self; update.action = #selector(openUpdate); update.isHidden = true; at(update,560,40,248,28)
        for rect in [NSRect(x:32,y:118,width:776,height:112), NSRect(x:32,y:250,width:468,height:250), NSRect(x:520,y:250,width:288,height:250), NSRect(x:32,y:520,width:776,height:94)] {
            let card = NSBox(); card.boxType = .custom; card.borderWidth = 1; card.cornerRadius = 16; card.fillColor = .white; card.borderColor = NSColor(srgbRed:228/255,green:233/255,blue:242/255,alpha:1); at(card,rect.minX,rect.minY,rect.width,rect.height)
        }
        let mark = NSView(); mark.wantsLayer=true; mark.layer?.cornerRadius=12; mark.layer?.backgroundColor=blue.withAlphaComponent(0.09).cgColor; at(mark,52,151,52,52)
        let icon = NSImageView(); icon.image=NSImage(systemSymbolName:"laptopcomputer",accessibilityDescription:"這台電腦"); icon.contentTintColor=blue; icon.imageScaling = .scaleProportionallyUpOrDown; at(icon,64,163,28,28)
        label("這台電腦",120,140,274,12,color:muted); label(Host.current().localizedName ?? "Mac",120,168,274,19,bold:true)
        label("角色",416,140,370,13,color:muted); at(role,412,165,378,34); role.addItems(withTitles:["主控端 · 鍵盤滑鼠在這台","接收端 · 等待主控端邀請"])
        label("附近電腦",52,272,300,18,bold:true); at(search,376,268,104,34); search.bezelStyle = .rounded; search.target=self; search.action = #selector(searchNow)
        at(nearby,48,324,436,38); nearby.font = .systemFont(ofSize:15)
        emptyNearby.font = .systemFont(ofSize:14); emptyNearby.textColor=muted; emptyNearby.maximumNumberOfLines=3; at(emptyNearby,52,325,428,62)
        label("首次核對短碼，對方同意後即可連線。",52,397,428,13,color:muted)
        pair.title="邀請配對  →"; pair.bezelStyle = .rounded; pair.bezelColor=blue; pair.contentTintColor = .white; pair.font = .systemFont(ofSize:15,weight:.semibold); pair.target=self; pair.action = #selector(invite); at(pair,48,438,436,44)
        label("連線狀態",540,272,248,18,bold:true)
        status.textColor=blue; status.font = .systemFont(ofSize:16,weight:.semibold); status.maximumNumberOfLines=3; at(status,540,321,248,70)
        peerLabel.textColor=muted; peerLabel.font = .systemFont(ofSize:12); peerLabel.maximumNumberOfLines=2; peerLabel.lineBreakMode = .byTruncatingTail; at(peerLabel,540,394,248,42)
        for (button,x,width,action) in [(start,CGFloat(536),CGFloat(150),#selector(resume)),(stop,688,104,#selector(pause))] { button.bezelStyle = .rounded; button.target=self; button.action=action; at(button,x,444,width,38) }
        label("螢幕位置",52,551,140,17,bold:true); at(position,216,545,574,36); position.addItems(withTitles:["接收端在右邊  →","接收端在左邊  ←","接收端在上方  ↑","接收端在下方  ↓"])
        positionHint.stringValue="由主控端設定兩台螢幕的相對位置"; positionHint.textColor=muted; at(positionHint,220,553,566,32)
        clear.title="清除暫存"; for (button,x,action) in [(forget,CGFloat(28),#selector(forgetPeer)),(clear,156,#selector(clearCache))] { button.bezelStyle = .rounded; button.target=self; button.action=action; at(button,x,632,124,38) }
        let permissions = NSButton(title:"權限設定",target:self,action:#selector(openPermissions)); permissions.bezelStyle = .rounded; at(permissions,284,632,124,38)
        let records = NSButton(title:"診斷紀錄",target:self,action:#selector(showDiagnostics)); records.bezelStyle = .rounded; at(records,676,632,136,38)
        label("複製 → 換到另一台 → 等接收完成後貼上",34,682,740,12,color:muted)
        details.isEditable=false; details.font = .monospacedSystemFont(ofSize:12,weight:.regular); details.isVerticallyResizable=true; details.autoresizingMask = [.width]
        role.target = self; role.action = #selector(roleChanged); position.target = self; position.action = #selector(positionChanged); nearby.target = self; nearby.action = #selector(selectionChanged)
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); tray.button?.title = "⇄"; let trayMenu = NSMenu()
        trayMenu.addItem(withTitle: "開啟 Barrier Share", action: #selector(showWindow), keyEquivalent: "").target = self; trayMenu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""); tray.menu = trayMenu
        do {
            if !test { let old = Bundle.main.bundleURL.deletingLastPathComponent(); try ShareSettings.importPairing(old, true, replace: false); try ShareSettings.importPairing(old, false, replace: false) }
            options = try ShareSettings.load(); role.selectItem(at: options.host ? 0 : 1); position.selectItem(at: ShareSettings.directions.firstIndex(of: options.position) ?? 0)
            loading = false; try refreshRole()
            if !test { startLink(); retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in if let self = self, self.enabled && self.link == nil { self.startLink() } } }
            if !test { checkUpdate(); updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in self?.checkUpdate() } }
        } catch { loading = false; showError(error) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func updateControls() { nearby.isHidden = computers.isEmpty; emptyNearby.isHidden = !computers.isEmpty; pair.title = options.host ? "邀請配對  →" : "等待主控端邀請"; start.isEnabled = !enabled || link == nil; stop.isEnabled = enabled; search.isEnabled = link != nil; pair.isEnabled = options.host && link != nil && nearby.indexOfSelectedItem >= 0 && consent == nil; forget.isEnabled = link != nil && !savedPeer.isEmpty; clear.isEnabled = !enabled && core == nil }
    func refreshRole() throws {
        position.isHidden = !options.host; positionHint.isHidden = options.host; savedPeer = ""; computers.removeAll(); nearby.removeAllItems()
        _ = try ShareSettings.initialize(options.host); try ShareSettings.save(options)
        peerLabel.stringValue = options.host ? "選擇接收端，按「邀請配對」。" : "等待主控端邀請；首次需要你同意。"
        status.stringValue = enabled ? "正在啟用區網搜尋…" : "已暫停"; updateControls()
    }
    func showError(_ error: Error) { status.stringValue = "操作未完成：" + error.localizedDescription }
    // Offline or rate-limited checks stay silent; the local network connection never depends on them.
    func checkUpdate() {
        var request = URLRequest(url: ShareUpdate.releases, timeoutInterval: 15)
        request.setValue("BarrierShare-UpdateCheck", forHTTPHeaderField: "User-Agent"); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let data = data { self.showUpdate(ShareUpdate.newer(data, current: ShareUpdate.current)) } else if let error = error { self.log("檢查更新失敗：" + error.localizedDescription) }
            }
        }.resume()
    }
    func showUpdate(_ found: (version: String, url: URL)?) {
        update.isHidden = found == nil; network.isHidden = found != nil
        guard let found = found else { return }
        updateURL = found.url
        update.attributedTitle = NSAttributedString(string: "有新版 \(found.version)，前往下載 ↗", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: blue, .underlineStyle: NSUnderlineStyle.single.rawValue])
    }
    @objc func openUpdate() { if let url = updateURL { NSWorkspace.shared.open(url) } }
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
        if f[0] == "READY" { log("區網搜尋已啟動 · UDP/TCP 24801"); status.stringValue = options.host ? "正在搜尋接收端…" : "可被搜尋，等待主控端邀請…" }
        else if f[0] == "DEVICE" && f.count == 6 {
            let index = nearby.indexOfSelectedItem, selected = nearby.indexOfSelectedItem >= 0 && nearby.indexOfSelectedItem < computers.count ? computers[index].fingerprint : ""
            computers.removeAll { $0.fingerprint == f[1] }; computers.append(NearbyComputer(fingerprint: f[1], name: decoded(f[2]), address: f[3])); computers.sort { $0.name < $1.name }
            nearby.removeAllItems(); nearby.addItems(withTitles: computers.map { $0.name + "  ·  " + $0.address }); if let item = computers.firstIndex(where: { $0.fingerprint == selected }) { nearby.selectItem(at: item) }
        } else if f[0] == "GONE" && f.count == 2 { if let index = computers.firstIndex(where: { $0.fingerprint == f[1] }) { computers.remove(at: index); nearby.removeItem(at: index) } }
        else if (f[0] == "SAVED" || f[0] == "PAIRED") && f.count == 3 {
            if f[0] == "PAIRED" { stopBackend() }; savedPeer = f[1]; peerLabel.stringValue = "已配對 · \(decoded(f[2]))\n重新開啟後會自動連線"
        } else if (f[0] == "REQUEST" || f[0] == "VERIFY") && f.count == 5 { showConsent(f) }
        else if f[0] == "CLOSED" && f.count == 2 && consentId == f[1] { closeConsent() }
        else if f[0] == "CONNECT" && f.count == 4 && f[1] == savedPeer {
            if core == nil || (!options.host && connectedAddress != f[3]) { stopBackend(); options.address = f[3]; do { try ShareSettings.save(options); startBackend() } catch { showError(error) } }
        } else if f[0] == "REMOVED" { stopBackend(); savedPeer = ""; peerLabel.stringValue = "已解除配對。"; status.stringValue = options.host ? "可以選擇接收端重新邀請。" : "等待新的配對邀請。" }
        else if f[0] == "UNAVAILABLE" && f.count == 3 && core == nil { status.stringValue = "正在重新尋找並驗證已配對的電腦…"; log(decoded(f[2])) }
        else if (f[0] == "ERROR" || f[0] == "FATAL") && f.count == 2 { if f[0] == "FATAL" { stopLink() }; status.stringValue = decoded(f[1]); log(status.stringValue) }
        updateControls()
    }
    func showConsent(_ message: [String]) {
        closeConsent(); showWindow(); let alert = NSAlert(), id = message[1]; consent = alert; consentId = id
        alert.messageText = message[0] == "REQUEST" ? "收到配對邀請" : "核對配對碼"
        alert.informativeText = "\(decoded(message[2]))\n請確認另一台顯示相同的 6 位數配對碼。\n\n同意後允許共用鍵盤滑鼠及雙向同步剪貼簿。配對會被記住，之後自動連線。"
        let code = NSTextField(labelWithString: message[4]); code.textColor = blue; code.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold); code.alignment = .center; code.frame = NSRect(x: 0, y: 0, width: 320, height: 52); alert.accessoryView = code
        alert.addButton(withTitle: "拒絕"); alert.addButton(withTitle: "相同，同意"); alert.buttons[1].bezelColor = blue; alert.buttons[1].contentTintColor = .white; updateControls()
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
    @objc func showDiagnostics() {
        if !test {
            let accessibility = AXIsProcessTrusted(), inputMonitoring = CGPreflightListenEventAccess()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
            log("權限診斷 · 輔助使用：\(accessibility ? "已授權" : "未授權")；輸入監控：\(inputMonitoring ? "已授權" : "未授權")")
            log("執行版本：\(version)；組建：\(build)；PID：\(ProcessInfo.processInfo.processIdentifier)")
            log("App 路徑：\(Bundle.main.bundleURL.path)")
        }
        if diagnostics == nil {
            let panel = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:400),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false); panel.title="Barrier Share · 診斷紀錄"; panel.delegate=self; panel.isReleasedWhenClosed=false
            let scroll=NSScrollView(frame:panel.contentView!.bounds.insetBy(dx:18,dy:18)); scroll.autoresizingMask=[.width,.height]; scroll.hasVerticalScroller=true; scroll.documentView=details; details.frame=scroll.bounds; panel.contentView!.addSubview(scroll); diagnostics=panel; panel.center()
        }
        diagnostics?.makeKeyAndOrderFront(nil)
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { enabled = false; retry?.invalidate(); updateTimer?.invalidate(); stopLink(); stopBackend(); return .terminateNow }
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
    guard let icon = Bundle.main.url(forResource: "BarrierShare", withExtension: "icns"), NSImage(contentsOf: icon) != nil,
          Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "BarrierShare.icns" else { throw ShareError.message("Missing app icon") }
    let base = "https://github.com/sunnylinisme/barrier/releases/tag/"
    let releases = Data("""
    [{"tag_name":"windows-v9.0.0","html_url":"\(base)windows-v9.0.0","draft":false,"prerelease":false},
     {"tag_name":"mac-v0.4.0","html_url":"\(base)mac-v0.4.0","draft":true,"prerelease":false},
     {"tag_name":"mac-v0.3.9","html_url":"\(base)mac-v0.3.9","draft":false,"prerelease":false},
     {"tag_name":"mac-v0.3.10","html_url":"https://example.com/elsewhere","draft":false,"prerelease":false},
     {"tag_name":"mac-v0.3.8","html_url":"\(base)mac-v0.3.8","draft":false,"prerelease":false}]
    """.utf8)
    guard let found = ShareUpdate.newer(releases, current: [0, 3, 4]), found.version == "0.3.9", found.url.absoluteString.hasSuffix("/mac-v0.3.9") else { throw ShareError.message("Update selection ignored platform, draft or origin rules") }
    guard ShareUpdate.newer(releases, current: [0, 3, 9]) == nil, ShareUpdate.newer(Data("{\"message\":\"rate limited\"}".utf8), current: [0, 0, 0]) == nil else { throw ShareError.message("Update reported without a newer release") }
    NSApp.finishLaunching()
    let app = ShareApp(test: true); app.buildWindow(); app.options.host = true; app.role.selectItem(at: 0); try app.refreshRole()
    let peer = "v2:sha256:" + String(repeating: "a", count: 64), name = Data("另一台電腦".utf8).base64EncodedString()
    app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.2\t24801\tR")
    app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.3\t24801\tR")
    guard app.computers.count == 1 && app.computers[0].address == "192.168.1.3" else { throw ShareError.message("Discovery list update failed") }
    app.linkLine("SAVED\t\(peer)\t\(name)")
    app.linkLine("VERIFY\ttest-request\t\(name)\t\(peer)\t123456")
    app.consent?.layout()
    app.consent?.window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    guard let sheet = app.consent?.window.contentView, let sheetBitmap = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { throw ShareError.message("Missing pairing dialog") }
    sheet.wantsLayer = true; sheet.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    sheet.layoutSubtreeIfNeeded(); sheet.displayIfNeeded()
    sheet.cacheDisplay(in: sheet.bounds, to: sheetBitmap)
    try sheetBitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("gui-pairing.png"))
    app.linkLine("CLOSED\ttest-request")
    guard app.consent == nil && app.consentId == nil else { throw ShareError.message("Expired pairing dialog remained open") }
    app.linkLine("GONE\t\(peer)"); guard app.computers.isEmpty else { throw ShareError.message("Offline peer remained listed") }
    // Render the available-peer state without starting any input capture or network service.
    app.link = Process(); app.savedPeer = ""; app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.3\t24801\tR")
    app.peerLabel.stringValue = "對方同意後，會記住這台電腦。"; app.status.stringValue = "找到附近電腦\n可以發出配對邀請"
    RunLoop.current.run(until: Date().addingTimeInterval(0.3)); app.window.displayIfNeeded()
    guard let view = app.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShareError.message("Cannot render window") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.representation(using: .png, properties: [:]) else { throw ShareError.message("Cannot render PNG") }
    try image.write(to: directory.appendingPathComponent("gui-mac.png"))
    app.showUpdate(found); RunLoop.current.run(until: Date().addingTimeInterval(0.2)); app.window.displayIfNeeded()
    guard let updateBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShareError.message("Cannot render update notice") }
    view.cacheDisplay(in: view.bounds, to: updateBitmap)
    try updateBitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("gui-mac-update.png"))
    app.window.orderOut(nil); NSStatusBar.system.removeStatusItem(app.tray)
    try "PASS: both pairing roles, saved IP/position, four screen directions, bundled backends, native GUI render and update notice selection".write(to: directory.appendingPathComponent("PASS.txt"), atomically: true, encoding: .utf8)
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
