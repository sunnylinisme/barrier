// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

struct ShareOptions: Codable {
    var host = true
    var address = ""
    var position = "right"
    var advanced = ShareAdvanced()
    // Where each paired receiver sits relative to this host on a 5x5 grid: fingerprint -> [x, y], y grows downwards.
    var layout: [String: [Int]] = [:]
    // Operating system each paired computer reported over the link: fingerprint -> mac / windows / linux.
    var platforms: [String: String] = [:]
    init() {}
    // Settings saved by older versions lack newer keys; keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(Bool.self, forKey: .host) ?? true
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? "right"
        advanced = (try? c.decodeIfPresent(ShareAdvanced.self, forKey: .advanced)) ?? ShareAdvanced()
        platforms = (try? c.decodeIfPresent([String: String].self, forKey: .platforms)) ?? [:]
        layout = ((try? c.decodeIfPresent([String: [Int]].self, forKey: .layout)) ?? [:]).filter { $0.value.count == 2 && abs($0.value[0]) <= 2 && abs($0.value[1]) <= 2 }
    }
}
// Host-side Barrier options from the advanced settings dialog.
struct ShareAdvanced: Codable, Equatable {
    var switchDelay = 0, doubleTap = 0, cornerSize = 16
    // swapModifiers defaults on: a Mac keyboard on Windows (and the reverse) then copies with ⌘C / Ctrl+C.
    var corners = false, swapModifiers = true, relativeMouse = false, screenSaver = true, switchKeys = true, lockKey = false
    var extra = "", targets = ""
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ShareAdvanced()
        switchDelay = try min(5000, max(0, c.decodeIfPresent(Int.self, forKey: .switchDelay) ?? d.switchDelay))
        doubleTap = try min(2000, max(0, c.decodeIfPresent(Int.self, forKey: .doubleTap) ?? d.doubleTap))
        cornerSize = try min(500, max(0, c.decodeIfPresent(Int.self, forKey: .cornerSize) ?? d.cornerSize))
        corners = try c.decodeIfPresent(Bool.self, forKey: .corners) ?? d.corners
        swapModifiers = try c.decodeIfPresent(Bool.self, forKey: .swapModifiers) ?? d.swapModifiers
        relativeMouse = try c.decodeIfPresent(Bool.self, forKey: .relativeMouse) ?? d.relativeMouse
        screenSaver = try c.decodeIfPresent(Bool.self, forKey: .screenSaver) ?? d.screenSaver
        switchKeys = try c.decodeIfPresent(Bool.self, forKey: .switchKeys) ?? d.switchKeys
        lockKey = try c.decodeIfPresent(Bool.self, forKey: .lockKey) ?? d.lockKey
        extra = try c.decodeIfPresent(String.self, forKey: .extra) ?? ""
        targets = try c.decodeIfPresent(String.self, forKey: .targets) ?? ""
    }
    // Extra lines go into the options section; section boundaries would break the generated file.
    func extraLines() throws -> [String] {
        try extra.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { (line: String) throws -> String in
            if line.lowercased().hasPrefix("section") || line.lowercased() == "end" { throw ShareError.message("額外設定不可包含 section 或 end：\(line)") }
            return line
        }
    }
    // Comma separated IPv4 addresses or computer names outside the local network.
    func targetList() throws -> String {
        let items = targets.components(separatedBy: CharacterSet(charactersIn: ", ;\r\n")).filter { !$0.isEmpty }
        for item in items where item.count > 253 || item.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) == nil { throw ShareError.message("請輸入 IPv4 位址或電腦名稱，以逗號分隔：\(item)") }
        if items.count > 16 { throw ShareError.message("最多輸入 16 個位址。") }
        return items.joined(separator: ",")
    }
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
    struct Cell: Hashable { var x: Int, y: Int }
    static let hostName = "windows-host"
    static var ownFingerprint: String?
    // Core screen name of a receiver; unique per computer so several can connect at once.
    static func screenName(_ fingerprint: String) -> String { "r-" + String(fingerprint.dropFirst(10).prefix(16)) }
    static var receiverName: String { ownFingerprint.map(screenName) ?? "windows" }
    static func step(_ direction: String) -> Cell { [Cell(x: 1, y: 0), Cell(x: -1, y: 0), Cell(x: 0, y: -1), Cell(x: 0, y: 1)][directions.firstIndex(of: direction) ?? 0] }
    static func opposite(_ direction: String) -> String { ["left", "right", "down", "up"][directions.firstIndex(of: direction) ?? 0] }
    // Screen name -> grid cell, host first. Without paired receivers this is the classic host + "windows" pair.
    static func cells(_ direction: String, receivers: [String], layout: [String: [Int]]) -> [(String, Cell)] {
        var result: [(String, Cell)] = [(hostName, Cell(x: 0, y: 0))]
        if receivers.isEmpty { return result + [("windows", step(direction))] }
        var order = [step(direction), step(opposite(direction)), Cell(x: 0, y: -1), Cell(x: 0, y: 1), Cell(x: 1, y: 0), Cell(x: -1, y: 0)]
        for ring in 1...2 { for y in -ring...ring { for x in -ring...ring where max(abs(x), abs(y)) == ring { order.append(Cell(x: x, y: y)) } } }
        for (index, fp) in receivers.enumerated() {
            let used = Set(result.map { $0.1 })
            var cell = layout[fp].map { Cell(x: $0[0], y: $0[1]) }
            if cell == nil || used.contains(cell!) { cell = index == 0 && !used.contains(step(direction)) ? step(direction) : order.first { !used.contains($0) && $0 != Cell(x: 0, y: 0) } }
            result.append((screenName(fp), cell!))
        }
        return result
    }
    static func config(_ direction: String, _ a: ShareAdvanced = ShareAdvanced(), receivers: [String] = [], layout: [String: [Int]] = [:], platforms: [String: String] = [:]) throws -> String {
        guard directions.contains(direction) else { throw ShareError.message("請選擇有效的螢幕位置。") }
        let grid = cells(direction, receivers: receivers, layout: layout)
        var text = "section: screens\n"
        for (name, _) in grid {
            text += " \(name):\n"
            // Swap on non-Mac receivers only: a Mac keyboard's Command then acts as Ctrl there.
            // Mac to Mac needs no swap; a receiver whose system is unknown is treated as Windows.
            let platform = receivers.first(where: { screenName($0) == name }).flatMap { platforms[$0] }
            if a.swapModifiers && name != hostName && platform != "mac" { text += "  ctrl = super\n  super = ctrl\n" }
        }
        // The first receiver also answers to "windows", the name receivers used before 0.3.9.
        if let first = receivers.first { text += "end\nsection: aliases\n \(screenName(first)):\n  windows\n" }
        text += "end\nsection: links\n"
        let order = [direction, opposite(direction)] + directions.filter { $0 != direction && $0 != opposite(direction) }
        var used: [String] = []
        for (name, cell) in grid {
            text += " \(name):\n"
            for d in order {
                let next = Cell(x: cell.x + step(d).x, y: cell.y + step(d).y)
                for (other, place) in grid where place == next { text += "  \(d) = \(other)\n"; if !used.contains(d) { used.append(d) } }
            }
        }
        text += "end\nsection: options\n clipboardSharing = true\n"
        if a.switchDelay > 0 { text += " switchDelay = \(a.switchDelay)\n" }
        if a.doubleTap > 0 { text += " switchDoubleTap = \(a.doubleTap)\n" }
        if a.corners { text += " switchCorners = all\n switchCornerSize = \(a.cornerSize)\n" }
        if a.relativeMouse { text += " relativeMouseMoves = true\n" }
        text += " screenSaverSync = \(a.screenSaver ? "true" : "false")\n"
        if a.switchKeys { for d in order where used.contains(d) { text += " keystroke(Control+Alt+\(d.prefix(1).uppercased() + d.dropFirst())) = switchInDirection(\(d))\n" } }
        if a.lockKey { text += " keystroke(Control+Alt+L) = lockCursorToScreen(toggle)\n" }
        for line in try a.extraLines() { text += " \(line)\n" }
        return text + "end\n"
    }
    static var receivers: [String] = []
    static func command(_ options: ShareOptions) throws -> Process {
        let p = profile(options.host), process = Process()
        process.executableURL = bin.appendingPathComponent(options.host ? "barriers" : "barrierc")
        var args = ["-f", "--no-tray", "--file-clipboard", "--profile-dir", p.path, "--log", p.appendingPathComponent(options.host ? "server.log" : "mac.log").path, "--name", options.host ? hostName : receiverName]
        if options.host {
            let path = p.appendingPathComponent("screens.conf")
            try config(options.position, options.advanced, receivers: receivers, layout: options.layout, platforms: options.platforms).write(to: path, atomically: true, encoding: .utf8)
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
    // Shared vX.Y.Z releases carry both platforms; mac-vX.Y.Z is the pre-0.3.9 Mac-only form.
    static let prefixes = ["v", "mac-v"]
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
        for release in list where release.draft != true && release.prerelease != true {
            guard let prefix = prefixes.first(where: { release.tag_name.hasPrefix($0) }), let version = parts(String(release.tag_name.dropFirst(prefix.count))), let url = URL(string: release.html_url),
                  release.html_url.hasPrefix("https://github.com/sunnylinisme/barrier/releases/") else { continue }
            if version.lexicographicallyPrecedes(current) || version == current { continue }
            if best == nil || best!.0.lexicographicallyPrecedes(version) { best = (version, url) }
        }
        guard let best = best else { return nil }
        return (best.0.map(String.init).joined(separator: "."), best.1)
    }
}

// Launch at login through the system login items (macOS 13+).
enum ShareLogin {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
}

// Remembers a ⌘V pressed while files are still arriving, and pastes them once they are ready
// if the same app is still in front; otherwise the user is asked to paste again.
struct ShareAutoPaste {
    var target: pid_t?
    mutating func pressed(front: pid_t?) { if target == nil { target = front } }
    mutating func ready(front: pid_t?) -> pid_t? { defer { target = nil }; return target != nil && target == front ? target : nil }
}

// Small floating window at the bottom right that shows a file transfer while it runs, so the
// progress is visible even when the main window is hidden. It does not take keyboard focus.
// Short transfers finish before it appears; once shown it stays until the result has been read.
final class ShareTransferPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 96), styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
    let title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: ""), bar = NSProgressIndicator(), cancel = NSButton(title: "取消傳送", target: nil, action: nil)
    var active = false, pending: DispatchWorkItem?, closing: DispatchWorkItem?, note = ""
    init(target: AnyObject, cancelAction: Selector) {
        panel.title = "Barrier Share"; panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.becomesKeyOnlyIfNeeded = true
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.frame = NSRect(x: 16, y: 62, width: 308, height: 18)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.frame = NSRect(x: 16, y: 40, width: 220, height: 16)
        bar.style = .bar; bar.isIndeterminate = true; bar.frame = NSRect(x: 16, y: 14, width: 210, height: 16)
        cancel.bezelStyle = .rounded; cancel.target = target; cancel.action = cancelAction; cancel.frame = NSRect(x: 236, y: 8, width: 92, height: 30)
        for view in [title, detail, bar, cancel] as [NSView] { panel.contentView!.addSubview(view) }
    }
    func begin(_ text: String, showAfter delay: Double = 1) {
        closing?.cancel(); pending?.cancel(); active = true; note = ""
        title.stringValue = text; detail.stringValue = "完成前可繼續操作滑鼠與鍵盤"; cancel.isHidden = false; bar.isHidden = false; bar.startAnimation(nil)
        let work = DispatchWorkItem { [weak self] in if let self = self, self.active { self.show() } }
        pending = work; if delay <= 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }
    func progress(_ text: String) {
        guard active else { return }
        let parts = text.components(separatedBy: "… ")
        title.stringValue = parts[0] + "…" + note; detail.stringValue = parts.count > 1 ? parts[1] : ""
    }
    func finish(_ text: String, detail note: String) {
        pending?.cancel(); active = false
        guard panel.isVisible else { return }
        title.stringValue = text; detail.stringValue = note; bar.stopAnimation(nil); bar.isHidden = true; cancel.isHidden = true
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        closing = work; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
    func show() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.minY + 16)); panel.orderFrontRegardless()
    }
}

// Turns "file clipboard: progress sent N bytes" log lines into a size and speed for the status card.
struct ShareProgress {
    var lastBytes: Int64 = 0, lastTime = Date(), speed = 0.0
    mutating func reset() { lastBytes = 0; lastTime = Date(); speed = 0 }
    mutating func describe(_ line: String, now: Date = Date()) -> String? {
        guard let range = line.range(of: #"file clipboard: progress (sent|received) [0-9]+ bytes"#, options: .regularExpression) else { return nil }
        let words = line[range].split(separator: " "), sent = words[3] == "sent"
        guard let bytes = Int64(words[4]) else { return nil }
        let seconds = now.timeIntervalSince(lastTime)
        if seconds > 0.05 && bytes >= lastBytes { let current = Double(bytes - lastBytes) / seconds; speed = speed == 0 ? current : speed * 0.6 + current * 0.4 }
        lastBytes = bytes; lastTime = now
        return (sent ? "正在傳送檔案… 已傳 " : "正在接收檔案… 已收 ") + ShareProgress.size(bytes) + (speed > 0 ? " · " + ShareProgress.size(Int64(speed)) + "/s" : "")
    }
    static func size(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]; var value = Double(bytes), unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return (unit == 0 ? String(format: "%.0f", value) : String(format: value < 10 ? "%.1f" : "%.0f", value)) + " " + units[unit]
    }
}

// Drag the paired receivers around this host on a 5x5 grid. Neighbouring cells are linked edges;
// every screen must touch the group, or the cursor could never reach it.
final class ShareLayoutView: NSView {
    static let cell = CGSize(width: 104, height: 64), span = 2
    var names: [String: String], placement: [String: ShareSettings.Cell], blue: NSColor, onChange: (() -> Void)?
    var dragging: String?, pointer = NSPoint.zero
    override var isFlipped: Bool { true }
    init(names: [String: String], placement: [String: ShareSettings.Cell], blue: NSColor) {
        self.names = names; self.placement = placement; self.blue = blue
        super.init(frame: NSRect(x: 0, y: 0, width: ShareLayoutView.cell.width * 5, height: ShareLayoutView.cell.height * 5))
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    func rect(_ c: ShareSettings.Cell) -> NSRect { NSRect(x: CGFloat(c.x + 2) * Self.cell.width + 5, y: CGFloat(c.y + 2) * Self.cell.height + 5, width: Self.cell.width - 10, height: Self.cell.height - 10) }
    func reachable() -> Bool {
        let all = Set(placement.values); var seen: Set<ShareSettings.Cell> = [ShareSettings.Cell(x: 0, y: 0)]
        var queue = Array(seen)
        while let c = queue.popLast() {
            for n in [ShareSettings.Cell(x: c.x + 1, y: c.y), ShareSettings.Cell(x: c.x - 1, y: c.y), ShareSettings.Cell(x: c.x, y: c.y + 1), ShareSettings.Cell(x: c.x, y: c.y - 1)] where all.contains(n) && !seen.contains(n) { seen.insert(n); queue.append(n) }
        }
        return all.isSubset(of: seen)
    }
    @discardableResult func place(_ fp: String, _ c: ShareSettings.Cell) -> Bool {
        guard abs(c.x) <= Self.span, abs(c.y) <= Self.span, c != ShareSettings.Cell(x: 0, y: 0), !placement.contains(where: { $0.key != fp && $0.value == c }) else { return false }
        placement[fp] = c; needsDisplay = true; onChange?(); return true
    }
    override func mouseDown(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); dragging = placement.first { rect($0.value).contains(pointer) }?.key }
    override func mouseDragged(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); if dragging != nil { needsDisplay = true } }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let fp = dragging { place(fp, ShareSettings.Cell(x: Int(p.x / Self.cell.width) - 2, y: Int(p.y / Self.cell.height) - 2)) }
        dragging = nil; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 244/255, green: 246/255, blue: 250/255, alpha: 1).setFill(); bounds.fill()
        let dash = NSColor(srgbRed: 219/255, green: 226/255, blue: 237/255, alpha: 1)
        for y in -2...2 { for x in -2...2 { let path = NSBezierPath(rect: rect(ShareSettings.Cell(x: x, y: y))); path.setLineDash([4, 3], count: 2, phase: 0); dash.setStroke(); path.stroke() } }
        func tile(_ r: NSRect, _ text: String, host: Bool) {
            let shape = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10); (host ? blue : .white).setFill(); shape.fill(); blue.setStroke(); shape.lineWidth = 1.5; shape.stroke()
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: host ? NSColor.white : NSColor.labelColor, .paragraphStyle: style])
            string.draw(in: NSRect(x: r.minX + 6, y: r.midY - 9, width: r.width - 12, height: 18))
        }
        tile(rect(ShareSettings.Cell(x: 0, y: 0)), "這台（主控端）", host: true)
        for (fp, c) in placement {
            var r = rect(c); if fp == dragging { r.origin = NSPoint(x: pointer.x - r.width / 2, y: pointer.y - r.height / 2) }
            tile(r, names[fp] ?? "", host: false)
        }
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
final class ShareApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    // "0.3.9" for releases; "0.3.9.N 測試版" for test builds, whose Info.plist carries "N commit".
    static let testBuild = (Bundle.main.object(forInfoDictionaryKey: "BarrierShareTestBuild") as? String ?? "").split(separator: " ").map(String.init)
    static let testCommit = testBuild.count == 2 ? testBuild[1] : ""
    static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return testBuild.count == 2 ? "\(version).\(testBuild[0]) 測試版" : version
    }
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
    // Paired computers in pairing order: every receiver for a host, the one host for a receiver.
    var peers: [(fingerprint: String, name: String)] = []
    let arrange = NSButton(title: "排列螢幕…", target: nil, action: nil)
    var computers: [NearbyComputer] = [], connectedAddress = "", consent: NSAlert?, consentId: String?, enabled = true, loading = true, promptedPermissions = false
    let network = NSTextField(labelWithString: "●  區域網路"), update = NSButton(title: "", target: nil, action: nil)
    var updateURL: URL?, updateTimer: Timer?
    let autostart = NSButton(checkboxWithTitle: "登入時自動啟動", target: nil, action: nil)
    var transferring = false, progress = ShareProgress()
    lazy var transferPanel = ShareTransferPanel(target: self, cancelAction: #selector(resume))
    var receiving = false, autoPaste = ShareAutoPaste(), pasteMonitor: Any?, lastProgress = ""
    let test: Bool
    init(test: Bool = false) { self.test = test; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        // ⌘V while files are still arriving: paste them as soon as they are complete.
        pasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.receiving, event.keyCode == 9, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return }
            // The window only appears once the user asks for the files; until then they arrive quietly.
            if self.autoPaste.target == nil {
                self.autoPaste.pressed(front: NSWorkspace.shared.frontmostApplication?.processIdentifier)
                self.transferPanel.begin("正在接收檔案…", showAfter: 0); self.transferPanel.note = "（傳完自動貼上）"
                self.transferPanel.progress(self.lastProgress.isEmpty ? "正在接收檔案… 準備中" : self.lastProgress)
            }
        }
    }
    // Sent to the app directly, not through the event tap, so it can never be forwarded to the other computer.
    func paste(into pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] { if let key = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down) { key.flags = .maskCommand; key.postToPid(pid) } }
    }
    func buildWindow() {
        let menu = NSMenu(), appMenu = NSMenu(), appItem = NSMenuItem()
        appMenu.addItem(withTitle: "關於 Barrier Share", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); appMenu.addItem(.separator()); appMenu.addItem(withTitle: "結束 Barrier Share", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Barrier Share " + ShareApp.versionLabel; window.delegate = self; window.isReleasedWhenClosed = false
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
        label("螢幕位置",52,551,140,17,bold:true); at(position,216,545,420,36); arrange.bezelStyle = .rounded; arrange.target = self; arrange.action = #selector(showLayout); at(arrange,648,544,142,38); position.addItems(withTitles:["接收端在右邊  →","接收端在左邊  ←","接收端在上方  ↑","接收端在下方  ↓"])
        positionHint.stringValue="由主控端設定兩台螢幕的相對位置"; positionHint.textColor=muted; at(positionHint,220,553,416,32)
        clear.title="清除暫存"; for (button,x,action) in [(forget,CGFloat(28),#selector(forgetPeer)),(clear,156,#selector(clearCache))] { button.bezelStyle = .rounded; button.target=self; button.action=action; at(button,x,632,124,38) }
        let permissions = NSButton(title:"權限設定",target:self,action:#selector(openPermissions)); permissions.bezelStyle = .rounded; at(permissions,284,632,124,38)
        autostart.target = self; autostart.action = #selector(toggleLogin); autostart.state = !test && ShareLogin.enabled ? .on : .off; at(autostart,418,640,150,22)
        let advancedButton = NSButton(title:"進階設定",target:self,action:#selector(showAdvanced)); advancedButton.bezelStyle = .rounded; at(advancedButton,566,632,106,38)
        let records = NSButton(title:"診斷紀錄",target:self,action:#selector(showDiagnostics)); records.bezelStyle = .rounded; at(records,676,632,136,38)
        label("複製 → 換到另一台 → 等接收完成後貼上",34,682,740,12,color:muted)
        details.isEditable=false; details.font = .monospacedSystemFont(ofSize:12,weight:.regular); details.isVerticallyResizable=true; details.autoresizingMask = [.width]
        role.target = self; role.action = #selector(roleChanged); position.target = self; position.action = #selector(positionChanged); nearby.target = self; nearby.action = #selector(selectionChanged)
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The app icon itself (same as the Dock and the Windows tray). It is a full-colour tile with
        // its own light background, so it stays legible on light and dark menu bars; not a template image.
        if let url = Bundle.main.url(forResource: "BarrierShare", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18); icon.isTemplate = false
            tray.button?.image = icon; tray.button?.imageScaling = .scaleProportionallyDown; tray.button?.title = ""
        } else { tray.button?.title = "⇄" }
        tray.button?.toolTip = "Barrier Share"; let trayMenu = NSMenu()
        trayMenu.delegate = self; trayMenu.autoenablesItems = false; tray.menu = trayMenu
        do {
            if !test { let old = Bundle.main.bundleURL.deletingLastPathComponent(); try ShareSettings.importPairing(old, true, replace: false); try ShareSettings.importPairing(old, false, replace: false) }
            options = try ShareSettings.load(); role.selectItem(at: options.host ? 0 : 1); position.selectItem(at: ShareSettings.directions.firstIndex(of: options.position) ?? 0)
            loading = false; try refreshRole()
            if !test { startLink(); retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in if let self = self, self.enabled && self.link == nil { self.startLink() } } }
            if !test { checkUpdate(); updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.checkUpdate() } }
        } catch { loading = false; showError(error) }
        window.center()
        // A login-item launch stays in the menu bar; opening the app again shows the window.
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        if !loginLaunch || test { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { NSApp.setActivationPolicy(.accessory) }
    }
    @objc func toggleLogin() {
        do { try ShareLogin.set(autostart.state == .on) } catch { showError(error) }
        autostart.state = ShareLogin.enabled ? .on : .off
        if autostart.state == .off && SMAppService.mainApp.status == .requiresApproval { status.stringValue = "請到「系統設定 › 一般 › 登入項目」允許 Barrier Share。" }
    }
    func updateControls() { transferring = transferring && core != nil; start.title = transferring ? "取消傳送" : "恢復連線"; nearby.isHidden = computers.isEmpty; emptyNearby.isHidden = !computers.isEmpty; pair.title = options.host ? "邀請配對  →" : "等待主控端邀請"; start.isEnabled = transferring || !enabled || link == nil; stop.isEnabled = enabled; search.isEnabled = link != nil; pair.isEnabled = options.host && link != nil && nearby.indexOfSelectedItem >= 0 && consent == nil; forget.isEnabled = link != nil && !peers.isEmpty; clear.isEnabled = !enabled && core == nil }
    func refreshRole() throws {
        peers.removeAll(); peersChanged(); computers.removeAll(); nearby.removeAllItems()
        _ = try ShareSettings.initialize(options.host); try ShareSettings.save(options)
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
    // Menu-bar menu, rebuilt each time it opens so the status and toggles are current (same items as the Windows tray).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = menu.addItem(withTitle: status.stringValue.components(separatedBy: "\n").first ?? "", action: nil, keyEquivalent: ""); state.isEnabled = false
        menu.addItem(.separator())
        func item(_ title: String, _ action: Selector, enabled: Bool = true, on: Bool = false) { let i = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); i.target = self; i.isEnabled = enabled; i.state = on ? .on : .off }
        item("開啟視窗", #selector(showWindow))
        item(enabled ? "暫停共用" : "繼續共用", enabled ? #selector(pause) : #selector(resume))
        if options.host { item("排列螢幕…", #selector(showLayoutFromMenu), enabled: !peers.isEmpty) }
        item("進階設定…", #selector(showAdvancedFromMenu))
        item("登入時自動啟動", #selector(toggleLoginFromMenu), on: ShareLogin.enabled)
        item("診斷紀錄", #selector(showDiagnostics))
        item("檢查更新", #selector(checkUpdateFromMenu))
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }
    @objc func showLayoutFromMenu() { showWindow(); showLayout() }
    @objc func showAdvancedFromMenu() { showWindow(); showAdvanced() }
    @objc func toggleLoginFromMenu() { autostart.state = ShareLogin.enabled ? .off : .on; toggleLogin() }
    // A manual check always answers, also when this is the newest version or the check failed.
    @objc func checkUpdateFromMenu() {
        var request = URLRequest(url: ShareUpdate.releases, timeoutInterval: 15)
        request.setValue("BarrierShare-UpdateCheck", forHTTPHeaderField: "User-Agent"); request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let alert = NSAlert(); alert.messageText = "檢查更新"
                if let data = data, let found = ShareUpdate.newer(data, current: ShareUpdate.current) {
                    self.showUpdate(found)
                    alert.informativeText = "有新版 \(found.version)。"; alert.addButton(withTitle: "前往下載"); alert.addButton(withTitle: "稍後")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(found.url) }
                    return
                }
                alert.informativeText = data != nil ? "目前已是最新版（\(ShareApp.versionLabel)）。" : "無法檢查更新：" + (error?.localizedDescription ?? "沒有回應")
                NSApp.activate(ignoringOtherApps: true); alert.runModal()
            }
        }.resume()
    }
    func showUpdate(_ found: (version: String, url: URL)?) {
        update.isHidden = found == nil; network.isHidden = found != nil
        guard let found = found else { return }
        updateURL = found.url
        update.attributedTitle = NSAttributedString(string: "有新版 \(found.version)，前往下載 ↗", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: blue, .underlineStyle: NSUnderlineStyle.single.rawValue])
    }
    func sendTargets() { do { let list = try options.advanced.targetList(); if !list.isEmpty || link != nil { send("TARGETS\t" + list) } } catch { showError(error) } }
    // Host-side Barrier options plus direct addresses for computers on another subnet or VPN.
    func buildAdvanced(_ a: ShareAdvanced) -> (NSAlert, () -> ShareAdvanced) {
        let alert = NSAlert(); alert.messageText = "進階設定"
        alert.informativeText = options.host ? "以下切換設定由這台（主控端）套用到兩台。" : "切換設定只在主控端生效；這台目前是接收端。"
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 520)); var y: CGFloat = 0
        func number(_ title: String, _ value: Int) -> NSTextField {
            let label = NSTextField(labelWithString: title); label.frame = NSRect(x: 0, y: y + 3, width: 380, height: 20); view.addSubview(label)
            let field = NSTextField(string: String(value)); field.frame = NSRect(x: 390, y: y, width: 100, height: 24); field.alignment = .right; view.addSubview(field); y += 34; return field
        }
        func check(_ title: String, _ value: Bool) -> NSButton {
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil); box.state = value ? .on : .off; box.frame = NSRect(x: 0, y: y, width: 490, height: 22); view.addSubview(box); y += 30; return box
        }
        let delay = number("游標停在邊緣多久才切換（毫秒，0 = 立即）", a.switchDelay)
        let tap = number("輕敲兩下邊緣才切換（兩次間隔毫秒，0 = 關閉）", a.doubleTap)
        let corners = check("螢幕四個角落不切換", a.corners)
        let cornerSize = number("　角落範圍（像素）", a.cornerSize)
        let swap = check("Windows 接收端的 Control 與 Command 鍵對調（兩台都是 Mac 時不會對調）", a.swapModifiers)
        let relative = check("相對滑鼠移動（全螢幕遊戲用）", a.relativeMouse)
        let saver = check("螢幕保護程式同步", a.screenSaver)
        let keys = check("Control+Option+方向鍵切換到另一台", a.switchKeys)
        let lock = check("Control+Option+L 把游標鎖在目前這台（再按一次解除）", a.lockKey)
        let targetsLabel = NSTextField(labelWithString: "其他網段或 VPN 的電腦（IP 或名稱，以逗號分隔）"); targetsLabel.frame = NSRect(x: 0, y: y, width: 490, height: 20); view.addSubview(targetsLabel); y += 24
        let targets = NSTextField(string: a.targets); targets.frame = NSRect(x: 0, y: y, width: 490, height: 24); view.addSubview(targets); y += 34
        let extraLabel = NSTextField(labelWithString: "額外設定（Barrier 設定檔 options 語法，例如自訂快捷鍵）"); extraLabel.frame = NSRect(x: 0, y: y, width: 490, height: 20); view.addSubview(extraLabel); y += 24
        let scroll = NSScrollView(frame: NSRect(x: 0, y: y, width: 490, height: 80)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let extra = NSTextView(frame: scroll.bounds); extra.string = a.extra; extra.font = .monospacedSystemFont(ofSize: 12, weight: .regular); extra.isRichText = false; extra.autoresizingMask = [.width]
        scroll.documentView = extra; view.addSubview(scroll); y += 88
        view.frame.size.height = y; alert.accessoryView = view
        alert.addButton(withTitle: "儲存並套用"); alert.addButton(withTitle: "取消")
        let read = { () -> ShareAdvanced in
            var v = ShareAdvanced()
            v.switchDelay = min(5000, max(0, delay.integerValue)); v.doubleTap = min(2000, max(0, tap.integerValue)); v.cornerSize = min(500, max(0, cornerSize.integerValue))
            v.corners = corners.state == .on; v.swapModifiers = swap.state == .on; v.relativeMouse = relative.state == .on; v.screenSaver = saver.state == .on
            v.switchKeys = keys.state == .on; v.lockKey = lock.state == .on; v.targets = targets.stringValue.trimmingCharacters(in: .whitespaces); v.extra = extra.string
            return v
        }
        return (alert, read)
    }
    @objc func showAdvanced() {
        let (alert, read) = buildAdvanced(options.advanced)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = read()
        do {
            _ = try value.targetList(); _ = try value.extraLines()
            options.advanced = value; try ShareSettings.save(options); sendTargets()
            // The host core reads options at start; the saved pairing reconnects it right away.
            if options.host && core != nil { stopBackend() }
            status.stringValue = "已儲存進階設定。"
        } catch { showError(error) }
    }
    @objc func openUpdate() { if let url = updateURL { NSWorkspace.shared.open(url) } }
    @objc func roleChanged() { guard !loading else { return }; stopLink(); stopBackend(); options.host = role.indexOfSelectedItem == 0; do { try refreshRole(); if enabled { startLink() } } catch { showError(error) } }
    @objc func positionChanged() { guard !loading else { return }; options.position = ShareSettings.directions[position.indexOfSelectedItem]; for p in peers { options.layout[p.fingerprint] = nil }; do { try ShareSettings.save(options); if core != nil { stopBackend() } } catch { showError(error) } }
    @objc func selectionChanged() { updateControls() }
    @objc func searchNow() { send("SEARCH"); status.stringValue = "正在搜尋同一區網的電腦…" }
    @objc func invite() { let index = nearby.indexOfSelectedItem; guard index >= 0 && index < computers.count else { return }; stopBackend(); send("PAIR\t" + computers[index].fingerprint); status.stringValue = "正在發出邀請…" }
    @objc func resume() {
        // While a file is moving the same button cancels it: restarting the connection drops the partial copy on both sides.
        if transferring { transferring = false; stopBackend(); startBackend(); status.stringValue = "已取消檔案傳送，正在重新連線…"; return }
        enabled = true; startLink(); updateControls()
    }
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
        if f[0] == "READY" { log("區網搜尋已啟動 · UDP/TCP 24801"); if f.count == 2 { ShareSettings.ownFingerprint = f[1] }; sendTargets(); status.stringValue = options.host ? "正在搜尋接收端…" : "可被搜尋，等待主控端邀請…" }
        else if f[0] == "DEVICE" && f.count == 6 {
            let index = nearby.indexOfSelectedItem, selected = nearby.indexOfSelectedItem >= 0 && nearby.indexOfSelectedItem < computers.count ? computers[index].fingerprint : ""
            computers.removeAll { $0.fingerprint == f[1] }; computers.append(NearbyComputer(fingerprint: f[1], name: decoded(f[2]), address: f[3])); computers.sort { $0.name < $1.name }
            nearby.removeAllItems(); nearby.addItems(withTitles: computers.map { $0.name + "  ·  " + $0.address }); if let item = computers.firstIndex(where: { $0.fingerprint == selected }) { nearby.selectItem(at: item) }
        } else if f[0] == "PLATFORM" && f.count == 3 {
            guard options.platforms[f[1]] != f[2] else { return }
            options.platforms[f[1]] = f[2]
            do { try ShareSettings.save(options) } catch { showError(error) }
            // The swap is written into the host's screen config, so restart the core to apply it.
            if options.host && core != nil { stopBackend(); startBackend() }
        } else if f[0] == "GONE" && f.count == 2 { if let index = computers.firstIndex(where: { $0.fingerprint == f[1] }) { computers.remove(at: index); nearby.removeItem(at: index) } }
        else if (f[0] == "SAVED" || f[0] == "PAIRED") && f.count == 3 {
            // A receiver has one host; a host's new receiver needs the core restarted with the new screen list.
            if f[0] == "PAIRED" { stopBackend(); if !options.host { peers.removeAll() } }
            if let index = peers.firstIndex(where: { $0.fingerprint == f[1] }) { peers[index].name = decoded(f[2]) } else { peers.append((f[1], decoded(f[2]))) }
            peersChanged()
        } else if (f[0] == "REQUEST" || f[0] == "VERIFY") && f.count == 5 { showConsent(f) }
        else if f[0] == "CLOSED" && f.count == 2 && consentId == f[1] { closeConsent() }
        else if f[0] == "CONNECT" && f.count == 4 && peers.contains(where: { $0.fingerprint == f[1] }) {
            if core == nil || (!options.host && connectedAddress != f[3]) { stopBackend(); options.address = f[3]; do { try ShareSettings.save(options); startBackend() } catch { showError(error) } }
        } else if f[0] == "REMOVED" {
            stopBackend()
            if f.count == 2 { peers.removeAll { $0.fingerprint == f[1] }; options.layout[f[1]] = nil } else { peers.removeAll() }
            peersChanged(); try? ShareSettings.save(options); if peers.isEmpty { peerLabel.stringValue = "已解除配對。" }
            status.stringValue = !peers.isEmpty ? "已解除一台；其餘的會自動重新連線。" : options.host ? "可以選擇接收端重新邀請。" : "等待新的配對邀請。"
        }
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
        if peers.count > 1 {
            // Several receivers: choose one, or all of them.
            let menu = NSMenu()
            for p in peers { let item = menu.addItem(withTitle: "解除「\(p.name)」", action: #selector(forgetChosen(_:)), keyEquivalent: ""); item.target = self; item.representedObject = p.fingerprint }
            menu.addItem(.separator()); let all = menu.addItem(withTitle: "全部解除", action: #selector(forgetChosen(_:)), keyEquivalent: ""); all.target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: forget.bounds.height + 4), in: forget); return
        }
        confirmForget("FORGET", "解除後不會自動連線，需要重新邀請並經對方同意。")
    }
    @objc func forgetChosen(_ item: NSMenuItem) {
        if let fp = item.representedObject as? String { confirmForget("FORGET\t" + fp, "解除與「\(peers.first { $0.fingerprint == fp }?.name ?? "")」的配對？") } else { confirmForget("FORGET", "解除所有配對？") }
    }
    func confirmForget(_ command: String, _ question: String) {
        let alert = NSAlert(); alert.messageText = "解除配對？"; alert.informativeText = question; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "解除")
        if alert.runModal() == .alertSecondButtonReturn { stopBackend(); send(command) }
    }
    // Keeps the screen list, the paired label and the position controls in step with the paired computers.
    func peersChanged() {
        ShareSettings.receivers = options.host ? peers.map { $0.fingerprint } : []
        let names = peers.map { $0.name }
        peerLabel.stringValue = names.count == 1 ? "已配對 · \(names[0])\n重新開啟後會自動連線" : names.count > 1 ? "已配對 \(names.count) 台 · " + names.joined(separator: "、") : options.host ? "選擇接收端，按「邀請配對」。" : "等待主控端邀請；首次需要你同意。"
        // Receivers are placed only through 排列螢幕, also when there is just one, so no second control can disagree with it.
        position.isHidden = true; arrange.isHidden = !options.host; arrange.isEnabled = !peers.isEmpty; positionHint.isHidden = false
        positionHint.stringValue = !options.host ? "由主控端設定螢幕的相對位置" : peers.isEmpty ? "配對接收端後，按「排列螢幕」設定位置" : "已配對 \(peers.count) 台；按「排列螢幕」調整位置"
        updateControls()
    }
    func buildLayout() -> (NSAlert, ShareLayoutView) {
        let grid = ShareSettings.cells(options.position, receivers: peers.map { $0.fingerprint }, layout: options.layout)
        var placement: [String: ShareSettings.Cell] = [:]
        for p in peers { if let cell = grid.first(where: { $0.0 == ShareSettings.screenName(p.fingerprint) })?.1 { placement[p.fingerprint] = cell } }
        let view = ShareLayoutView(names: Dictionary(uniqueKeysWithValues: peers.map { ($0.fingerprint, $0.name) }), placement: placement, blue: blue)
        let alert = NSAlert(); alert.messageText = "排列螢幕"; alert.informativeText = "拖曳電腦到這台的上下左右；相鄰的邊就是游標可以移過去的地方。"
        alert.accessoryView = view; alert.addButton(withTitle: "儲存排列"); alert.addButton(withTitle: "取消")
        view.onChange = { [weak alert, weak view] in alert?.buttons.first?.isEnabled = view?.reachable() ?? false }
        return (alert, view)
    }
    @objc func showLayout() {
        let (alert, view) = buildLayout()
        guard alert.runModal() == .alertFirstButtonReturn, view.reachable() else { return }
        for (fp, cell) in view.placement { options.layout[fp] = [cell.x, cell.y] }
        do { try ShareSettings.save(options); if core != nil { stopBackend() }; status.stringValue = "已儲存螢幕排列。" } catch { showError(error) }
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
        let was = transferring
        if line.contains("file clipboard: sending") { status.stringValue = "正在傳送檔案… 可繼續操作滑鼠與鍵盤"; transferring = true; receiving = false; progress.reset() }
        if line.contains("file clipboard: receiving") { status.stringValue = "正在接收檔案… 完成後即可貼上"; transferring = true; receiving = true; autoPaste.target = nil; lastProgress = ""; progress.reset() }
        if let moved = progress.describe(line), transferring { status.stringValue = moved; lastProgress = moved; transferPanel.progress(moved) }
        if line.contains("file clipboard: sent ") { status.stringValue = "檔案已送出 · 可在另一台貼上"; transferring = false }
        if line.contains("received and verified") {
            receiving = false; transferring = false
            if let pid = autoPaste.ready(front: NSWorkspace.shared.frontmostApplication?.processIdentifier) {
                // The core has already published the files; give the pasteboard a moment before pasting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.paste(into: pid) }
                status.stringValue = "已收到檔案並自動貼上"; transferPanel.finish("已收到檔案", detail: "已自動貼上")
            } else { status.stringValue = "已收到檔案，可在 Finder 資料夾使用 ⌘V 貼上"; transferPanel.finish("已收到檔案", detail: "請在 Finder 資料夾再按一次 ⌘V") }
        }
        if line.contains("WARNING") && line.contains("file clipboard:") { status.stringValue = "檔案複製未完成；請查看下方原因。"; transferring = false; receiving = false; autoPaste.target = nil; transferPanel.finish("檔案複製未完成", detail: "詳情見「診斷紀錄」") }
        if line.contains("server is dead") || line.contains("disconnected") { status.stringValue = "連線中斷，正在自動重連…"; transferring = false; receiving = false; autoPaste.target = nil; transferPanel.finish("連線中斷", detail: "檔案沒有傳完，請重新複製") }
        if was != transferring { updateControls() }
    }
    @objc func showDiagnostics() {
        if !test {
            let accessibility = AXIsProcessTrusted(), inputMonitoring = CGPreflightListenEventAccess()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
            log("權限診斷 · 輔助使用：\(accessibility ? "已授權" : "未授權")；輸入監控：\(inputMonitoring ? "已授權" : "未授權")")
            log("版本 \(ShareApp.versionLabel)\(ShareApp.testCommit.isEmpty ? "" : "，commit " + ShareApp.testCommit)")
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
    // While the main window is hidden the app lives only in the menu bar: no Dock icon.
    @objc func showWindow() { NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); if sender === window { NSApp.setActivationPolicy(.accessory) }; return false }
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
        if !configuration.contains("= switchInDirection(\(direction))\n") || !configuration.contains("= switchInDirection(\(opposite))\n") || configuration.components(separatedBy: "keystroke").count != 3 { throw ShareError.message("Switch hotkeys missing for \(direction)") }
    }
    var full = ShareAdvanced(); full.switchDelay = 250; full.doubleTap = 300; full.corners = true; full.cornerSize = 24; full.swapModifiers = true; full.relativeMouse = true; full.screenSaver = false; full.lockKey = true
    full.targets = "10.8.0.5, office-pc.local"; full.extra = "# comment\nkeystroke(Control+Alt+F12) = switchToScreen(windows)\n"
    let fullConfig = try ShareSettings.config("right", full)
    for expected in [" windows:\n  ctrl = super\n  super = ctrl\n", " switchDelay = 250\n", " switchDoubleTap = 300\n", " switchCorners = all\n switchCornerSize = 24\n", " relativeMouseMoves = true\n", " screenSaverSync = false\n", " keystroke(Control+Alt+L) = lockCursorToScreen(toggle)\n", " keystroke(Control+Alt+F12) = switchToScreen(windows)\nend\n"] where !fullConfig.contains(expected) {
        throw ShareError.message("Advanced option missing from config: \(expected)")
    }
    guard !fullConfig.contains("# comment"), try full.targetList() == "10.8.0.5,office-pc.local" else { throw ShareError.message("Advanced extras were not normalized") }
    for bad in ["end", "section: links"] { var a = ShareAdvanced(); a.extra = bad; if (try? a.extraLines()) != nil { throw ShareError.message("Section boundary accepted: \(bad)") } }
    var badTarget = ShareAdvanced(); badTarget.targets = "1.2.3.4 & calc"; if (try? badTarget.targetList()) != nil { throw ShareError.message("Invalid direct address accepted") }
    var withAdvanced = ShareOptions(); withAdvanced.advanced = full; try ShareSettings.save(withAdvanced)
    guard try ShareSettings.load().advanced == full else { throw ShareError.message("Advanced settings roundtrip failed") }
    try Data(#"{"host":false,"address":"192.168.1.9","position":"up"}"#.utf8).write(to: ShareSettings.root.appendingPathComponent("settings.json"))
    let legacy = try ShareSettings.load(); guard !legacy.host && legacy.position == "up" && legacy.advanced == ShareAdvanced(), legacy.advanced.swapModifiers else { throw ShareError.message("Settings from 0.3.8 did not load") }
    let fa = "v2:sha256:" + String(repeating: "a", count: 64), fb = "v2:sha256:" + String(repeating: "b", count: 64), fc = "v2:sha256:" + String(repeating: "c", count: 64)
    var swapped = ShareAdvanced(); swapped.swapModifiers = true
    let multi = try ShareSettings.config("right", swapped, receivers: [fa, fb, fc], layout: [fb: [0, -1]])
    let (na, nb, nc) = (ShareSettings.screenName(fa), ShareSettings.screenName(fb), ShareSettings.screenName(fc))
    let mixed = try ShareSettings.config("right", swapped, receivers: [fa, fb, fc], platforms: [fa: "mac", fb: "windows"])
    guard !mixed.contains(" \(na):\n  ctrl = super"), mixed.contains(" \(nb):\n  ctrl = super\n"), mixed.contains(" \(nc):\n  ctrl = super\n") else { throw ShareError.message("Ctrl/Command swap applied to a Mac receiver or skipped a Windows/unknown one") }
    var withPlatform = ShareOptions(); withPlatform.platforms = [fa: "mac"]; try ShareSettings.save(withPlatform)
    guard try ShareSettings.load().platforms == [fa: "mac"] else { throw ShareError.message("Receiver platforms were not saved") }
    for expected in [" windows-host:\n  right = \(na)\n  left = \(nc)\n  up = \(nb)\n", " \(na):\n  left = windows-host\n", " \(nb):\n  down = windows-host\n", "section: aliases\n \(na):\n  windows\nend\n", " \(nb):\n  ctrl = super\n  super = ctrl\n", "switchInDirection(up)", "switchInDirection(down)"] where !multi.contains(expected) {
        throw ShareError.message("Multi-screen config missing: \(expected)")
    }
    var withLayout = ShareOptions(); withLayout.layout = [fb: [0, -1], "bad": [9, 9]]; try ShareSettings.save(withLayout)
    guard try ShareSettings.load().layout == [fb: [0, -1]] else { throw ShareError.message("Screen layout roundtrip failed") }
    let layout = ShareLayoutView(names: [fa: "書房 Windows", fb: "MacBook Air", fc: "客廳電腦"], placement: [fa: .init(x: 1, y: 0), fb: .init(x: 0, y: -1), fc: .init(x: -1, y: 0)], blue: .systemBlue)
    guard layout.reachable(), !layout.place(fc, .init(x: 1, y: 0)), layout.place(fc, .init(x: 2, y: 2)), !layout.reachable(), layout.place(fc, .init(x: -1, y: 0)), layout.reachable() else { throw ShareError.message("Layout editor rules failed") }
    guard try ShareSettings.config("right").contains(" keystroke(Control+Alt+Right) = switchInDirection(right)\n keystroke(Control+Alt+Left) = switchInDirection(left)\nend\n") else { throw ShareError.message("Hotkey syntax changed") }
    var meter = ShareProgress(); meter.reset(); let t0 = Date()
    let first = meter.describe("[2026-11-12T10:00:00] INFO: file clipboard: progress sent 1048576 bytes", now: t0.addingTimeInterval(1))
    let second = meter.describe("[2026-11-12T10:00:01] INFO: file clipboard: progress received 3145728 bytes", now: t0.addingTimeInterval(2))
    guard let a = first, a.contains("1.0 MB"), let b = second, b.hasPrefix("正在接收"), b.contains("3.0 MB"), b.contains("MB/s"), meter.describe("file clipboard: sent 5 bytes") == nil else { throw ShareError.message("Transfer progress parsing failed") }
    let pop = ShareTransferPanel(target: NSObject(), cancelAction: #selector(NSWindow.orderOut(_:)))
    pop.begin("正在接收檔案…", showAfter: 0); pop.progress(b)
    guard pop.panel.isVisible, pop.title.stringValue == "正在接收檔案…", pop.detail.stringValue.contains("3.0 MB"), !pop.cancel.isHidden else { throw ShareError.message("Transfer window did not show progress") }
    if let content = pop.panel.contentView, let shot = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: shot); try shot.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("gui-transfer.png"))
    }
    pop.finish("已收到檔案", detail: "可在 Finder 資料夾按 ⌘V 貼上")
    guard pop.title.stringValue == "已收到檔案", pop.cancel.isHidden, !pop.active else { throw ShareError.message("Transfer window did not show the result") }
    pop.panel.orderOut(nil)
    var auto = ShareAutoPaste()
    guard auto.ready(front: 7) == nil else { throw ShareError.message("Pasted without a ⌘V") }
    auto.pressed(front: 7); auto.pressed(front: 9)
    guard auto.ready(front: 7) == 7, auto.target == nil else { throw ShareError.message("⌘V during a transfer was not pasted") }
    auto.pressed(front: 7)
    guard auto.ready(front: 9) == nil else { throw ShareError.message("Pasted into a different app") }
    for binary in ["barriers", "barrierc"] { if try !ShareSettings.run(binary, ["--help"], allowFailure: true).contains("--file-clipboard") { throw ShareError.message("Missing backend or file clipboard option") } }
    guard let icon = Bundle.main.url(forResource: "BarrierShare", withExtension: "icns"), NSImage(contentsOf: icon) != nil,
          Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "BarrierShare.icns" else { throw ShareError.message("Missing app icon") }
    let base = "https://github.com/sunnylinisme/barrier/releases/tag/"
    let releases = Data("""
    [{"tag_name":"windows-v9.0.0","html_url":"\(base)windows-v9.0.0","draft":false,"prerelease":false},
     {"tag_name":"mac-v0.4.0","html_url":"\(base)mac-v0.4.0","draft":true,"prerelease":false},
     {"tag_name":"mac-v0.3.9","html_url":"\(base)mac-v0.3.9","draft":false,"prerelease":false},
     {"tag_name":"mac-v0.3.10","html_url":"https://example.com/elsewhere","draft":false,"prerelease":false},
     {"tag_name":"mac-v0.3.8","html_url":"\(base)mac-v0.3.8","draft":false,"prerelease":false},
     {"tag_name":"v0.5.0","html_url":"\(base)v0.5.0","draft":true,"prerelease":false},
     {"tag_name":"v0.3.11","html_url":"\(base)v0.3.11","draft":false,"prerelease":false}]
    """.utf8)
    guard let found = ShareUpdate.newer(releases, current: [0, 3, 4]), found.version == "0.3.11", found.url.absoluteString.hasSuffix("/v0.3.11") else { throw ShareError.message("Update selection ignored platform, draft or origin rules") }
    guard let legacy = ShareUpdate.newer(Data(String(decoding: releases, as: UTF8.self).replacingOccurrences(of: "\"v0.3.11\"", with: "\"x0.3.11\"").utf8), current: [0, 3, 4]), legacy.url.absoluteString.hasSuffix("/mac-v0.3.9") else { throw ShareError.message("Update selection dropped legacy Mac releases") }
    guard ShareUpdate.newer(releases, current: [0, 3, 11]) == nil, ShareUpdate.newer(Data("{\"message\":\"rate limited\"}".utf8), current: [0, 0, 0]) == nil else { throw ShareError.message("Update reported without a newer release") }
    NSApp.finishLaunching()
    let app = ShareApp(test: true); app.buildWindow(); app.options.host = true; app.role.selectItem(at: 0); try app.refreshRole()
    guard let trayIcon = app.tray?.button?.image, trayIcon.size == NSSize(width: 18, height: 18), !trayIcon.isTemplate else { throw ShareError.message("Menu bar icon is not the 18 pt app icon") }
    _ = app.windowShouldClose(app.window)
    guard NSApp.activationPolicy() == .accessory, !app.window.isVisible else { throw ShareError.message("Closing the window left the Dock icon") }
    app.showWindow()
    guard NSApp.activationPolicy() == .regular, app.window.isVisible else { throw ShareError.message("Opening the window did not restore the Dock icon") }
    let trayTest = NSMenu(); app.menuNeedsUpdate(trayTest)
    let trayTitles = trayTest.items.map { $0.title }
    for expected in ["開啟視窗", "排列螢幕…", "進階設定…", "登入時自動啟動", "診斷紀錄", "檢查更新", "結束"] where !trayTitles.contains(expected) { throw ShareError.message("Menu bar item missing: \(expected)") }
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
    app.link = Process(); app.peers.removeAll(); app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.3\t24801\tR")
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
    try "PASS: both pairing roles, saved IP/position, four screen directions, bundled backends, native GUI render, update notice selection, switch hotkeys and transfer progress".write(to: directory.appendingPathComponent("PASS.txt"), atomically: true, encoding: .utf8)
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
