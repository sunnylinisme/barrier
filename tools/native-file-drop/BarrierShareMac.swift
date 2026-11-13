// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ApplicationServices
import Foundation
import ServiceManagement
import UserNotifications

struct ShareOptions: Codable {
    var host = true
    var address = ""
    var position = "right"
    var advanced = ShareAdvanced()
    // Where each paired receiver sits relative to this host on a 5x5 grid: fingerprint -> [x, y], y grows downwards.
    var layout: [String: [Int]] = [:]
    // Operating system each paired computer reported over the link: fingerprint -> mac / windows / linux.
    var platforms: [String: String] = [:]
    // Part of the shared edge each receiver next to this host uses: fingerprint -> all / first / second.
    var edgeRange: [String: String] = [:]
    init() {}
    // Settings saved by older versions lack newer keys; keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(Bool.self, forKey: .host) ?? true
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? "right"
        advanced = (try? c.decodeIfPresent(ShareAdvanced.self, forKey: .advanced)) ?? ShareAdvanced()
        platforms = (try? c.decodeIfPresent([String: String].self, forKey: .platforms)) ?? [:]
        edgeRange = ((try? c.decodeIfPresent([String: String].self, forKey: .edgeRange)) ?? [:]).filter { ["first", "second"].contains($0.value) }
        layout = ((try? c.decodeIfPresent([String: [Int]].self, forKey: .layout)) ?? [:]).filter { $0.value.count == 2 && abs($0.value[0]) <= 2 && abs($0.value[1]) <= 2 }
    }
}
// Host-side Barrier options from the advanced settings dialog.
struct ShareAdvanced: Codable, Equatable {
    var switchDelay = 0, doubleTap = 0, cornerSize = 16
    // swapModifiers defaults on: a Mac keyboard on Windows (and the reverse) then copies with ⌘C / Ctrl+C.
    var corners = false, swapModifiers = true, relativeMouse = false, screenSaver = true, switchKeys = true, lockKey = false
    var extra = "", targets = ""
    // Added with the original Barrier features; defaults keep the earlier behaviour.
    var directKeys = false, broadcastKey = false, capsLockFix = false, preserveFocus = false, clipboard = true, wheelInvert = false
    var switchNeeds = "", wheelScale = 100   // switchNeeds: "" / shift / control / alt
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
        directKeys = try c.decodeIfPresent(Bool.self, forKey: .directKeys) ?? d.directKeys
        broadcastKey = try c.decodeIfPresent(Bool.self, forKey: .broadcastKey) ?? d.broadcastKey
        capsLockFix = try c.decodeIfPresent(Bool.self, forKey: .capsLockFix) ?? d.capsLockFix
        preserveFocus = try c.decodeIfPresent(Bool.self, forKey: .preserveFocus) ?? d.preserveFocus
        clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? d.clipboard
        wheelInvert = try c.decodeIfPresent(Bool.self, forKey: .wheelInvert) ?? d.wheelInvert
        let needs = try c.decodeIfPresent(String.self, forKey: .switchNeeds) ?? ""; switchNeeds = ["shift", "control", "alt"].contains(needs) ? needs : ""
        wheelScale = try min(500, max(10, c.decodeIfPresent(Int.self, forKey: .wheelScale) ?? d.wheelScale))
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
    static func config(_ direction: String, _ a: ShareAdvanced = ShareAdvanced(), receivers: [String] = [], layout: [String: [Int]] = [:], platforms: [String: String] = [:], edgeRange: [String: String] = [:]) throws -> String {
        guard directions.contains(direction) else { throw ShareError.message("請選擇有效的螢幕位置。") }
        let grid = cells(direction, receivers: receivers, layout: layout)
        var text = "section: screens\n"
        for (name, _) in grid {
            text += " \(name):\n"
            // Swap on non-Mac receivers only: a Mac keyboard's Command then acts as Ctrl there.
            // Mac to Mac needs no swap; a receiver whose system is unknown is treated as Windows.
            let platform = receivers.first(where: { screenName($0) == name }).flatMap { platforms[$0] }
            if a.swapModifiers && name != hostName && platform != "mac" { text += "  ctrl = super\n  super = ctrl\n" }
            if a.capsLockFix && name != hostName { text += "  halfDuplexCapsLock = true\n" }
            if a.preserveFocus && name == hostName { text += "  preserveFocus = true\n" }
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
                for (other, place) in grid where place == next {
                    // Part of the edge shared by the host and a receiver right next to it.
                    let hostLink = name == hostName ? other : other == hostName ? name : nil
                    let range = hostLink.flatMap { link in receivers.first { screenName($0) == link } }.flatMap { edgeRange[$0] }
                    let part = range == "first" ? "(0,50)" : range == "second" ? "(50,100)" : ""
                    if name == hostName { text += "  \(d)\(part) = \(other)\n" } else { text += "  \(d) = \(other)\(part)\n" }
                    if !used.contains(d) { used.append(d) }
                }
            }
        }
        text += "end\nsection: options\n clipboardSharing = \(a.clipboard ? "true" : "false")\n"
        if !a.switchNeeds.isEmpty { text += " switchNeeds\(a.switchNeeds.prefix(1).uppercased() + a.switchNeeds.dropFirst()) = true\n" }
        if a.switchDelay > 0 { text += " switchDelay = \(a.switchDelay)\n" }
        if a.doubleTap > 0 { text += " switchDoubleTap = \(a.doubleTap)\n" }
        if a.corners { text += " switchCorners = all\n switchCornerSize = \(a.cornerSize)\n" }
        if a.relativeMouse { text += " relativeMouseMoves = true\n" }
        text += " screenSaverSync = \(a.screenSaver ? "true" : "false")\n"
        if a.switchKeys { for d in order where used.contains(d) { text += " keystroke(Control+Alt+\(d.prefix(1).uppercased() + d.dropFirst())) = switchInDirection(\(d))\n" } }
        if a.lockKey { text += " keystroke(Control+Alt+L) = lockCursorToScreen(toggle)\n" }
        if a.broadcastKey { text += " keystroke(Control+Alt+B) = keyboardBroadcast(toggle)\n" }
        // Control+Alt+1 is this host, 2-9 the receivers in pairing order (as listed in 排列螢幕).
        if a.directKeys { for (i, (name, _)) in grid.prefix(9).enumerated() { text += " keystroke(Control+Alt+\(i + 1)) = switchToScreen(\(name))\n" } }
        // Extra options from the removed expert box: skipped if invalid, so they can never stop the core from starting.
        for line in (try? a.extraLines()) ?? [] { text += " \(line)\n" }
        return text + "end\n"
    }
    static var receivers: [String] = []
    static func command(_ options: ShareOptions) throws -> Process {
        let p = profile(options.host), process = Process()
        process.executableURL = bin.appendingPathComponent(options.host ? "barriers" : "barrierc")
        var args = ["-f", "--no-tray", "--file-clipboard", "--profile-dir", p.path, "--log", p.appendingPathComponent(options.host ? "server.log" : "mac.log").path, "--name", options.host ? hostName : receiverName]
        if options.host {
            let path = p.appendingPathComponent("screens.conf")
            try config(options.position, options.advanced, receivers: receivers, layout: options.layout, platforms: options.platforms, edgeRange: options.edgeRange).write(to: path, atomically: true, encoding: .utf8)
            args += ["-c", path.path]
        } else {
            var ip = in_addr()
            guard options.address.withCString({ inet_pton(AF_INET, $0, &ip) }) == 1 else { throw ShareError.message("請輸入主控端的區網 IPv4 位址，例如 192.168.1.20。") }
            // Receiver-side wheel settings (這台當接收端時).
            if options.advanced.wheelScale != 100 { args += ["--wheel-scale", String(options.advanced.wheelScale)] }
            if options.advanced.wheelInvert { args += ["--wheel-invert"] }
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
    var colors: [String: NSColor] = [:], defaults: (() -> [String: ShareSettings.Cell])?
    @objc func restoreDefaults() { if let d = defaults?() { placement = d; needsDisplay = true; onChange?() } }
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
        ShareScreenMap.drawTile(.init(cell: .init(x: 0, y: 0), name: "這台", isSelf: true), rect(ShareSettings.Cell(x: 0, y: 0)), fontSize: 12)
        for (fp, c) in placement {
            var r = rect(c); if fp == dragging { r.origin = NSPoint(x: pointer.x - r.width / 2, y: pointer.y - r.height / 2) }
            ShareScreenMap.drawTile(.init(cell: c, name: names[fp] ?? "", color: colors[fp] ?? blue), r, fontSize: 12)
        }
    }
}

// Calls a closure from a control; toggle() flips `open` and passes it on.
final class ShareBlockTarget: NSObject {
    let action: (Bool) -> Void; var open = false
    init(_ action: @escaping (Bool) -> Void) { self.action = action }
    @objc func toggle() { open.toggle(); action(open) }
}
// Remembers the edge range chosen for each receiver in the arrange editor.
final class ShareRangeTarget: NSObject {
    var ranges: [String: String]
    init(_ ranges: [String: String]) { self.ranges = ranges }
    @objc func changed(_ sender: NSPopUpButton) { if let fp = sender.identifier?.rawValue { ranges[fp] = ["all", "first", "second"][max(0, sender.indexOfSelectedItem)] } }
}
// Ends a modal panel with accept or cancel.
final class ShareModalCloser: NSObject {
    weak var panel: NSWindow?; var accepted = false
    init(_ panel: NSWindow) { self.panel = panel }
    @objc func accept() { accepted = true; NSApp.stopModal(); panel?.orderOut(nil) }
    @objc func cancel() { accepted = false; NSApp.stopModal(); panel?.orderOut(nil) }
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
// Shared palette of the redesigned window (same values as the Windows ShareStyle).
enum ShareStyle {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
    static let background = rgb(244, 246, 250), border = rgb(228, 233, 242), line = rgb(236, 240, 246)
    static let blue = rgb(47, 101, 235), blueInk = rgb(31, 72, 180), tint = rgb(232, 239, 253)
    static let ink = rgb(24, 37, 57), muted = rgb(109, 122, 141), faint = rgb(150, 160, 175), field = rgb(238, 241, 246)
    static let green = rgb(24, 140, 82), greenTint = rgb(226, 245, 234), danger = rgb(200, 45, 45)
    // One colour per receiver in the screen maps: green, purple, orange, pink, amber.
    static let peers = [rgb(34, 160, 96), rgb(132, 86, 214), rgb(232, 120, 40), rgb(221, 72, 140), rgb(214, 160, 20)]
    static func peer(_ index: Int) -> NSColor { peers[index % peers.count] }
}
// White rounded card with a hairline border.
final class ShareCard: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.white.setFill(); shape.fill(); ShareStyle.border.setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}
// Small pill showing the connection state.
final class ShareBadge: NSView {
    var text = "", fore = ShareStyle.muted, back = ShareStyle.field
    func set(_ text: String, _ fore: NSColor, _ back: NSColor) { self.text = text; self.fore = fore; self.back = back; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fore])
        let width = min(bounds.width, label.size().width + 28)
        let pill = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        back.setFill(); NSBezierPath(roundedRect: pill, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        fore.setFill(); NSBezierPath(ovalIn: NSRect(x: 10, y: bounds.height / 2 - 3, width: 6, height: 6)).fill()
        label.draw(at: NSPoint(x: 21, y: (bounds.height - label.size().height) / 2))
    }
    override var isFlipped: Bool { true }
}
// Computer icon on a tinted rounded square.
final class ShareComputerMark: NSView {
    var symbol = ""  // kept for callers; every computer uses the same monitor outline as on Windows
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let k = bounds.width / 52
        ShareStyle.tint.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 12 * k, yRadius: 12 * k).fill()
        ShareStyle.blue.setStroke()
        let screen = NSBezierPath(rect: NSRect(x: 12 * k, y: 12 * k, width: 28 * k, height: 20 * k)); screen.lineWidth = 2 * k; screen.stroke()
        for (a, b) in [(NSPoint(x: 8, y: 37), NSPoint(x: 44, y: 37)), (NSPoint(x: 22, y: 32), NSPoint(x: 22, y: 36)), (NSPoint(x: 30, y: 32), NSPoint(x: 30, y: 36))] {
            let line = NSBezierPath(); line.move(to: NSPoint(x: a.x * k, y: a.y * k)); line.line(to: NSPoint(x: b.x * k, y: b.y * k)); line.lineWidth = 2 * k; line.stroke()
        }
    }
}
// Miniature of the screen arrangement in the connection card.
final class ShareScreenMap: NSView {
    struct Tile { var cell: ShareSettings.Cell; var name: String; var isSelf = false; var placeholder = false; var color: NSColor? = nil }
    var tiles: [Tile] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    // Grey rounded frame; 16:10 screens up to 76×48 with the name underneath; this one has a mouse outline.
    override func draw(_ dirtyRect: NSRect) {
        ShareStyle.background.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).fill()
        guard !tiles.isEmpty else { return }
        let xs = tiles.map { $0.cell.x }, ys = tiles.map { $0.cell.y }
        let cols = CGFloat(xs.max()! - xs.min()! + 1), rows = CGFloat(ys.max()! - ys.min()! + 1), gap: CGFloat = 8, label: CGFloat = 16
        var cw = min(76, (bounds.width - 16 - gap * (cols - 1)) / cols), ch = min(48, (bounds.height - 12 - (gap + label) * rows) / rows)
        cw = min(cw, ch * 1.6); ch = min(ch, cw / 1.6)
        let totalW = cols * cw + (cols - 1) * gap, totalH = rows * (ch + label) + (rows - 1) * gap
        let x0 = (bounds.width - totalW) / 2, y0 = (bounds.height - totalH) / 2
        for t in tiles {
            let r = NSRect(x: x0 + CGFloat(t.cell.x - xs.min()!) * (cw + gap), y: y0 + CGFloat(t.cell.y - ys.min()!) * (ch + label + gap), width: cw, height: ch)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5); path.lineWidth = t.isSelf ? 1.5 : 1
            if t.placeholder { path.setLineDash([4, 3], count: 2, phase: 0) } else { (t.isSelf ? ShareStyle.tint : NSColor.white).setFill(); path.fill() }
            (t.isSelf ? ShareStyle.blue : t.placeholder ? ShareStyle.faint : ShareStyle.border).setStroke(); path.stroke()
            if t.isSelf {
                // A mouse outline marks the computer whose keyboard and mouse are used.
                ShareStyle.blue.setStroke()
                let mouse = NSBezierPath(ovalIn: NSRect(x: r.midX - 5, y: r.midY - 8, width: 10, height: 16)); mouse.lineWidth = 1.5; mouse.stroke()
                let wheel = NSBezierPath(); wheel.move(to: NSPoint(x: r.midX, y: r.midY - 8)); wheel.line(to: NSPoint(x: r.midX, y: r.midY - 3)); wheel.lineWidth = 1.5; wheel.stroke()
            }
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: t.name, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: t.placeholder ? ShareStyle.faint : ShareStyle.muted, .paragraphStyle: style])
                .draw(in: NSRect(x: r.minX - gap / 2, y: r.maxY + 1, width: r.width + gap, height: label))
        }
    }
    // Shared with the arrange editor so both maps look the same.
    static func drawTiles(_ tiles: [Tile], in bounds: NSRect, size: NSSize, gap: CGFloat = 6, fontSize: CGFloat = 10) {
        guard !tiles.isEmpty else { return }
        let xs = tiles.map { $0.cell.x }, ys = tiles.map { $0.cell.y }
        let cols = CGFloat(xs.max()! - xs.min()! + 1), rows = CGFloat(ys.max()! - ys.min()! + 1)
        let scale = min(1, (bounds.width - 8) / (cols * size.width + (cols - 1) * gap), (bounds.height - 8) / (rows * size.height + (rows - 1) * gap))
        let w = size.width * scale, h = size.height * scale, g = gap * scale
        let ox = bounds.midX - (cols * w + (cols - 1) * g) / 2, oy = bounds.midY - (rows * h + (rows - 1) * g) / 2
        for t in tiles {
            let r = NSRect(x: ox + CGFloat(t.cell.x - xs.min()!) * (w + g), y: oy + CGFloat(t.cell.y - ys.min()!) * (h + g), width: w, height: h)
            drawTile(t, r, fontSize: fontSize * max(scale, 0.8))
        }
    }
    static func drawTile(_ t: Tile, _ r: NSRect, fontSize: CGFloat) {
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6); shape.lineWidth = 1.5
        let accent = t.color ?? ShareStyle.faint
        if t.isSelf { ShareStyle.tint.setFill(); shape.fill(); ShareStyle.blue.setStroke(); shape.stroke() }
        else if t.placeholder { shape.setLineDash([4, 3], count: 2, phase: 0); ShareStyle.faint.setStroke(); shape.stroke() }
        else { NSColor.white.setFill(); shape.fill(); accent.setStroke(); shape.stroke() }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        let color: NSColor = t.isSelf ? ShareStyle.blueInk : t.placeholder ? ShareStyle.faint : ShareStyle.ink
        let text = NSAttributedString(string: t.name, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color, .paragraphStyle: style])
        let height = text.size().height
        if t.isSelf, let cursor = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: fontSize, weight: .semibold).applying(.init(paletteColors: [ShareStyle.blue]))) {
            cursor.draw(in: NSRect(x: r.midX - cursor.size.width / 2, y: r.midY - (height + cursor.size.height) / 2, width: cursor.size.width, height: cursor.size.height))
            text.draw(in: NSRect(x: r.minX + 3, y: r.midY - (height + cursor.size.height) / 2 + cursor.size.height, width: r.width - 6, height: height))
        } else { text.draw(in: NSRect(x: r.minX + 3, y: r.midY - height / 2, width: r.width - 6, height: height)) }
    }
}
// Six-digit pairing code in two groups of three large boxes.
final class ShareCodeView: NSView {
    var code = ""
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let digits = Array(code.prefix(6)), box = NSSize(width: 46, height: 58), gap: CGFloat = 8, split: CGFloat = 22
        let total = 6 * box.width + 4 * gap + split; var x = (bounds.width - total) / 2
        for (i, d) in digits.enumerated() {
            let r = NSRect(x: x, y: (bounds.height - box.height) / 2, width: box.width, height: box.height)
            ShareStyle.field.setFill(); NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            let text = NSAttributedString(string: String(d), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold), .foregroundColor: ShareStyle.ink])
            text.draw(at: NSPoint(x: r.midX - text.size().width / 2, y: r.midY - text.size().height / 2))
            x += box.width + (i == 2 ? split : gap)
        }
    }
}
// One row in the nearby list: a section header, or a computer with its system, address and action.
final class ShareDeviceRow: NSView {
    override var isFlipped: Bool { true }
    static func header(_ text: String, width: CGFloat) -> NSView {
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = ShareStyle.muted
        label.frame = NSRect(x: 16, y: 8, width: width - 32, height: 16); view.addSubview(label); return view
    }
    init(width: CGFloat, name: String, detail: String, offline: Bool, paired: Bool, mac: Bool, invite: NSButton?) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 58))
        let mark = ShareComputerMark(frame: NSRect(x: 16, y: 11, width: 36, height: 36)); mark.symbol = mac ? "laptopcomputer" : "desktopcomputer"
        mark.alphaValue = offline ? 0.45 : 1; addSubview(mark)
        let title = NSTextField(labelWithString: name); title.font = .systemFont(ofSize: 14, weight: .semibold); title.textColor = offline ? ShareStyle.faint : ShareStyle.ink
        title.lineBreakMode = .byTruncatingTail; title.frame = NSRect(x: 64, y: 10, width: width - 220, height: 19); addSubview(title)
        let sub = NSTextField(labelWithString: detail); sub.font = .systemFont(ofSize: 12); sub.textColor = offline ? ShareStyle.faint : ShareStyle.muted
        sub.lineBreakMode = .byTruncatingTail; sub.frame = NSRect(x: 64, y: 30, width: width - 220, height: 17); addSubview(sub)
        if let invite = invite { invite.frame = NSRect(x: width - 128, y: 13, width: 112, height: 32); addSubview(invite) }
        else if paired {
            // Pairing state on the right, as on Windows: green ✓ when online, grey when offline.
            let state = NSTextField(labelWithString: offline ? "已配對 · 離線" : "✓ 已配對"); state.font = .systemFont(ofSize: 12, weight: offline ? .regular : .medium)
            state.textColor = offline ? ShareStyle.faint : ShareStyle.green; state.alignment = .right; state.frame = NSRect(x: width - 160, y: 20, width: 144, height: 17); addSubview(state)
        }
        let line = NSBox(frame: NSRect(x: 16, y: 57, width: width - 32, height: 1)); line.boxType = .custom; line.borderWidth = 0; line.fillColor = ShareStyle.line; addSubview(line)
    }
    required init?(coder: NSCoder) { fatalError("unused") }
}
// Borderless text button; a light background appears only while the pointer is over it.
final class ShareQuietButton: NSButton {
    var hovering = false { didSet { needsDisplay = true } }
    convenience init(_ title: String, _ target: AnyObject, _ action: Selector) { self.init(title: title, target: target, action: action) }
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false; font = .systemFont(ofSize: 13) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted { ShareStyle.border.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill() }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let text = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: isEnabled ? ShareStyle.ink : ShareStyle.faint, .paragraphStyle: style])
        text.draw(in: NSRect(x: 4, y: (bounds.height - text.size().height) / 2, width: bounds.width - 8, height: text.size().height))
    }
}
// Filled blue push button used for the main action of a row or dialog.
final class SharePrimaryButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (isEnabled ? (isHighlighted ? ShareStyle.blue.blended(withFraction: 0.18, of: .black)! : ShareStyle.blue) : ShareStyle.field).setFill(); shape.fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: isEnabled ? NSColor.white : ShareStyle.faint, .paragraphStyle: style])
        text.draw(in: NSRect(x: 6, y: (bounds.height - text.size().height) / 2, width: bounds.width - 12, height: text.size().height))
    }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class ShareApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
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
    // role is the model of the 主控端／接收端 segment (kept as a hidden pop-up for older code paths and tests).
    let role = NSPopUpButton(), segment = NSSegmentedControl(labels: ["主控端", "接收端"], trackingMode: .selectOne, target: nil, action: nil)
    let peerLabel = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: ""), roleLabel = NSTextField(labelWithString: "")
    let start = NSButton(title: "繼續共用", target: nil, action: nil), stop = NSButton(title: "暫停共用", target: nil, action: nil), search = ShareQuietButton(title: "重新搜尋", target: nil, action: nil), cancelSend = NSButton(title: "取消傳送", target: nil, action: nil), forget = NSButton(title: "解除配對", target: nil, action: nil), clear = NSButton(title: "清除檔案暫存", target: nil, action: nil)
    let badge = ShareBadge(), map = ShareScreenMap(), filter = NSSearchField(), nearbyCount = NSTextField(labelWithString: ""), nearbyScroll = NSScrollView(), nearbyList = FlippedView()
    let body = FlippedView(), banner = NSView(), bannerText = NSTextField(labelWithString: "")
    // connections: core sessions currently up; dismissedUpdate: version whose banner was closed; announcedUpdate: version already notified.
    var connections = 0, dismissedUpdate = "", announcedUpdate = "", nearbySignature = ""
    let details = NSTextView()
    var tray: NSStatusItem!, core: Process?, corePipe: Pipe?, link: Process?, linkOutput: Pipe?, linkInput: Pipe?, pendingCore = Data(), pendingLink = Data(), retry: Timer?
    // Paired computers in pairing order: every receiver for a host, the one host for a receiver.
    var peers: [(fingerprint: String, name: String)] = []
    let arrange = NSButton(title: "排列螢幕", target: nil, action: nil)
    var computers: [NearbyComputer] = [], connectedAddress = "", consent: NSWindow?, consentId: String?, enabled = true, loading = true, promptedPermissions = false
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
        appMenu.addItem(withTitle: "關於 Barrier Share", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); appMenu.addItem(.separator()); appMenu.addItem(withTitle: "結束 Barrier Share", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu; menu.addItem(appItem)
        // Edit menu so ⌘A / ⌘C work in the diagnostics log (and other text) as in any Mac app.
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "編輯")
        editMenu.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        let W: CGFloat = 720, H: CGFloat = 608
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Barrier Share " + ShareApp.versionLabel; window.delegate = self; window.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: H)); root.wantsLayer = true; root.layer?.backgroundColor = ShareStyle.background.cgColor
        window.contentView = root
        // Update banner above everything; the window grows by its height while it shows.
        banner.frame = NSRect(x: 0, y: 0, width: W, height: 44); banner.wantsLayer = true; banner.layer?.backgroundColor = ShareStyle.tint.cgColor; banner.isHidden = true
        bannerText.textColor = ShareStyle.blueInk; bannerText.font = .systemFont(ofSize: 13); bannerText.lineBreakMode = .byTruncatingTail; bannerText.frame = NSRect(x: 24, y: 13, width: 500, height: 18); banner.addSubview(bannerText)
        let download = SharePrimaryButton(title: "下載更新", target: self, action: #selector(openUpdate)); download.frame = NSRect(x: 560, y: 7, width: 104, height: 30); banner.addSubview(download)
        let dismiss = NSButton(title: "✕", target: self, action: #selector(dismissUpdate)); dismiss.isBordered = false; dismiss.frame = NSRect(x: 670, y: 7, width: 30, height: 30); dismiss.toolTip = "稍後再說"; banner.addSubview(dismiss)
        body.frame = NSRect(x: 0, y: 0, width: W, height: H); root.addSubview(body); root.addSubview(banner)
        func at(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) { view.frame = NSRect(x: x, y: y, width: width, height: height); body.addSubview(view) }
        func text(_ field: NSTextField, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = ShareStyle.ink) { field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; field.lineBreakMode = .byTruncatingTail }
        func plain(_ button: NSButton, _ action: Selector) { button.bezelStyle = .rounded; button.target = self; button.action = action; button.font = .systemFont(ofSize: 13) }
        // Header: this computer and its role.
        at(ShareComputerMark(), 24, 20, 44, 44)
        let name = NSTextField(labelWithString: Host.current().localizedName ?? "Mac"); text(name, 20, .bold); at(name, 80, 17, 420, 26)
        text(roleLabel, 13, .regular, ShareStyle.muted); at(roleLabel, 80, 45, 420, 18)
        segment.target = self; segment.action = #selector(segmentChanged); segment.segmentStyle = .rounded; segment.setAccessibilityLabel("這台電腦的角色")
        segment.setWidth(84, forSegment: 0); segment.setWidth(84, forSegment: 1); at(segment, 520, 28, 176, 30)
        role.addItems(withTitles: ["主控端 · 使用這台的鍵盤滑鼠", "接收端 · 等待主控端邀請"]); role.isHidden = true; role.target = self; role.action = #selector(roleChanged); at(role, 0, 0, 1, 1)
        // Connection card: state, what to do next, and a small map of the screens.
        at(ShareCard(), 24, 84, 672, 168)
        at(badge, 44, 102, 140, 24)
        text(status, 17, .bold); status.maximumNumberOfLines = 2; status.cell?.wraps = true; status.cell?.truncatesLastVisibleLine = true; at(status, 44, 132, 412, 46)
        text(peerLabel, 13, .regular, ShareStyle.muted); at(peerLabel, 44, 180, 412, 18)
        plain(stop, #selector(pause)); plain(start, #selector(resume)); plain(arrange, #selector(showLayout)); plain(cancelSend, #selector(cancelTransfer))
        at(stop, 40, 208, 120, 32); at(start, 40, 208, 120, 32); at(arrange, 164, 208, 120, 32); at(cancelSend, 288, 208, 120, 32)
        at(map, 472, 100, 204, 132)
        // Nearby computers: paired ones first, a search box once the list gets long.
        let nearbyTitle = NSTextField(labelWithString: "附近電腦"); text(nearbyTitle, 15, .semibold); at(nearbyTitle, 24, 274, 90, 20)
        text(nearbyCount, 13, .regular, ShareStyle.muted); at(nearbyCount, 100, 276, 120, 18)
        filter.placeholderString = "搜尋名稱或 IP"; filter.target = self; filter.action = #selector(filterChanged); filter.sendsSearchStringImmediately = true; filter.isHidden = true; at(filter, 352, 270, 234, 28)
        search.target = self; search.action = #selector(searchNow); at(search, 596, 268, 100, 30)
        let listCard = ShareCard(); at(listCard, 24, 306, 672, 236)
        nearbyScroll.frame = NSRect(x: 1, y: 6, width: 670, height: 224); nearbyScroll.drawsBackground = false; nearbyScroll.hasVerticalScroller = true; nearbyScroll.autohidesScrollers = true
        nearbyScroll.documentView = nearbyList; listCard.addSubview(nearbyScroll)
        emptyNearby.alignment = .center; text(emptyNearby, 13, .regular, ShareStyle.muted); emptyNearby.maximumNumberOfLines = 3; emptyNearby.frame = NSRect(x: 40, y: 88, width: 592, height: 60); listCard.addSubview(emptyNearby)
        // Footer: everyday switches; the rarely used actions sit under 更多.
        let rule = NSBox(); rule.boxType = .custom; rule.borderWidth = 0; rule.fillColor = ShareStyle.border; at(rule, 0, 556, W, 1)
        autostart.target = self; autostart.action = #selector(toggleLogin); autostart.state = !test && ShareLogin.enabled ? .on : .off; autostart.font = .systemFont(ofSize: 13); at(autostart, 24, 572, 200, 22)
        at(ShareQuietButton("進階設定", self, #selector(showAdvanced)), 404, 568, 100, 30)
        at(ShareQuietButton("診斷紀錄", self, #selector(showDiagnostics)), 508, 568, 100, 30)
        at(ShareQuietButton("更多  ▾", self, #selector(showMore(_:))), 612, 568, 84, 30)
        details.isEditable=false; details.font = .monospacedSystemFont(ofSize:12,weight:.regular); details.isVerticallyResizable=true; details.autoresizingMask = [.width]
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The app icon itself (same as the Dock and the Windows tray). It is a full-colour tile with
        // its own light background, so it stays legible on light and dark menu bars; not a template image.
        if let url = Bundle.main.url(forResource: "BarrierShare", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18); icon.isTemplate = false
            tray.button?.image = icon; tray.button?.imageScaling = .scaleProportionallyDown; tray.button?.title = ""
        } else { tray.button?.title = "⇄" }
        tray.button?.toolTip = "Barrier Share"; let trayMenu = NSMenu()
        trayMenu.delegate = self; trayMenu.autoenablesItems = false; tray.menu = trayMenu
        if !test { UNUserNotificationCenter.current().delegate = self }
        do {
            if !test { let old = Bundle.main.bundleURL.deletingLastPathComponent(); try ShareSettings.importPairing(old, true, replace: false); try ShareSettings.importPairing(old, false, replace: false) }
            options = try ShareSettings.load(); role.selectItem(at: options.host ? 0 : 1); segment.selectedSegment = options.host ? 0 : 1; roleChangedLabel()
            loading = false; try refreshRole()
            if !test { startLink(); retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in if let self = self, self.enabled && self.link == nil { self.startLink() } } }
            if !test { checkUpdate(); updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.checkUpdate() } }
        } catch { loading = false; showError(error) }
        window.center()
        // A login-item launch stays in the menu bar; opening the app again shows the window.
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        if !loginLaunch || test { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { NSApp.setActivationPolicy(.accessory) }
    }
    func roleChangedLabel() { roleLabel.stringValue = options.host ? "主控端 · 使用這台的鍵盤滑鼠" : "接收端 · 由主控端操作" }
    @objc func segmentChanged() { guard role.indexOfSelectedItem != segment.selectedSegment else { return }; role.selectItem(at: segment.selectedSegment); roleChanged() }
    @objc func filterChanged() { rebuildNearby() }
    @objc func cancelTransfer() { if transferring { resume() } }
    @objc func dismissUpdate() { dismissedUpdate = bannerVersion; setBanner(false) }
    var bannerVersion = ""
    func setBanner(_ show: Bool) {
        guard banner.isHidden == show else { return }
        banner.isHidden = !show; body.frame.origin.y = show ? 44 : 0
        var frame = window.frame; let delta: CGFloat = show ? 44 : -44
        frame.size.height += delta; frame.origin.y -= delta; window.setFrame(frame, display: true)
        (window.contentView as? FlippedView)?.frame.size.height = body.frame.maxY
    }
    @objc func showMore(_ sender: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        let clearItem = menu.addItem(withTitle: "清除暫存檔案", action: #selector(clearCache), keyEquivalent: ""); clearItem.target = self; clearItem.isEnabled = !enabled && core == nil
        menu.addItem(withTitle: "關於 Barrier Share", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let unpair = menu.addItem(withTitle: "解除配對…", action: peers.count > 1 ? nil : #selector(forgetPeer), keyEquivalent: ""); unpair.target = self
        unpair.attributedTitle = NSAttributedString(string: "解除配對…", attributes: [.foregroundColor: ShareStyle.danger, .font: NSFont.menuFont(ofSize: 0)])
        unpair.isEnabled = link != nil && !peers.isEmpty
        if peers.count > 1 {
            let choices = NSMenu()
            for p in peers { let item = choices.addItem(withTitle: "解除「\(p.name)」", action: #selector(forgetChosen(_:)), keyEquivalent: ""); item.target = self; item.representedObject = p.fingerprint }
            choices.addItem(.separator())
            let all = choices.addItem(withTitle: "全部解除", action: #selector(forgetChosen(_:)), keyEquivalent: ""); all.target = self
            all.attributedTitle = NSAttributedString(string: "全部解除", attributes: [.foregroundColor: ShareStyle.danger, .font: NSFont.menuFont(ofSize: 0)])
            unpair.submenu = choices
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    // Paired computers first (offline ones greyed), then the others by name, filtered by the search box.
    func rebuildNearby() {
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let match = { (c: NearbyComputer) in query.isEmpty || c.name.lowercased().contains(query) || c.address.contains(query) }
        let paired = peers.map { p in computers.first { $0.fingerprint == p.fingerprint }.map { ($0, false) } ?? (NearbyComputer(fingerprint: p.fingerprint, name: p.name, address: ""), true) }.filter { match($0.0) }
        let others = computers.filter { c in !peers.contains { $0.fingerprint == c.fingerprint } }.filter(match).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let width = nearbyScroll.contentSize.width
        // Discovery repeats every few seconds and every status change lands here; rebuild the rows only
        // when what they show changes, or the list visibly flickers.
        let canInvite = options.host && link != nil && consent == nil
        let signature = ([String(describing: width), String(canInvite), String(options.host)] + paired.map { "P\($0.0.fingerprint)|\($0.0.name)|\($0.0.address)|\($0.1)|\(options.platforms[$0.0.fingerprint] ?? "")" }
            + others.map { "O\($0.fingerprint)|\($0.name)|\($0.address)|\(options.platforms[$0.fingerprint] ?? "")" }).joined(separator: "\n")
        defer {
            emptyNearby.isHidden = !(paired.isEmpty && others.isEmpty)
            emptyNearby.stringValue = !query.isEmpty && !computers.isEmpty ? "找不到符合的電腦" : !enabled ? "搜尋已暫停\n繼續共用後，會重新尋找附近電腦。" : options.host ? "正在尋找接收端…\n請在另一台選擇「接收端」，保持程式開啟。" : "尚未找到主控端…\n請在另一台選擇「主控端」，保持程式開啟。"
            nearbyCount.stringValue = computers.isEmpty ? "" : "\(computers.count) 台"
            filter.isHidden = computers.count <= 6 && filter.stringValue.isEmpty
        }
        guard signature != nearbySignature else { return }
        nearbySignature = signature
        nearbyList.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        func add(_ view: NSView) { view.frame.origin = NSPoint(x: 0, y: y); nearbyList.addSubview(view); y += view.frame.height }
        func system(_ fp: String) -> String { switch options.platforms[fp] { case "mac": return "Mac"; case "windows": return "Windows"; case "linux": return "Linux"; default: return "電腦" } }
        if !paired.isEmpty { add(ShareDeviceRow.header("已配對", width: width)); for (c, offline) in paired { add(ShareDeviceRow(width: width, name: c.name, detail: offline ? system(c.fingerprint) : "\(system(c.fingerprint)) · \(c.address)", offline: offline, paired: true, mac: options.platforms[c.fingerprint] == "mac", invite: nil)) } }
        if !others.isEmpty {
            if !paired.isEmpty { add(ShareDeviceRow.header("其他電腦", width: width)) }
            for c in others {
                var button: NSButton? = nil
                if options.host {
                    let invite = SharePrimaryButton(title: "邀請配對", target: self, action: #selector(inviteRow(_:))); invite.identifier = NSUserInterfaceItemIdentifier(c.fingerprint)
                    invite.isEnabled = canInvite; button = invite
                }
                add(ShareDeviceRow(width: width, name: c.name, detail: "\(system(c.fingerprint)) · \(c.address)", offline: false, paired: false, mac: options.platforms[c.fingerprint] == "mac", invite: button))
            }
        }
        nearbyList.frame = NSRect(x: 0, y: 0, width: width, height: max(y, nearbyScroll.contentSize.height))
    }
    @objc func inviteRow(_ sender: NSButton) {
        guard let fp = sender.identifier?.rawValue, options.host, link != nil, consent == nil, !peers.contains(where: { $0.fingerprint == fp }) else { return }
        stopBackend(); send("PAIR\t" + fp); status.stringValue = "正在發出邀請…"
    }
    // The connection card's badge and screen map follow the role, pairing and connection.
    func updateCard() {
        if !enabled { badge.set("已暫停", ShareStyle.muted, ShareStyle.field) }
        else if connections > 0 { badge.set("已連線", ShareStyle.green, ShareStyle.greenTint) }
        else if !peers.isEmpty { badge.set("連線中", ShareStyle.blue, ShareStyle.tint) }
        else { badge.set(options.host ? "尚未配對" : "等待邀請", ShareStyle.muted, ShareStyle.field) }
        var tiles = [ShareScreenMap.Tile(cell: .init(x: 0, y: 0), name: "這台", isSelf: true)]
        if options.host {
            let grid = ShareSettings.cells(options.position, receivers: peers.map { $0.fingerprint }, layout: options.layout)
            for (i, p) in peers.enumerated() { if let cell = grid.first(where: { $0.0 == ShareSettings.screenName(p.fingerprint) })?.1 { tiles.append(.init(cell: cell, name: p.name, color: ShareStyle.peer(i))) } }
            if peers.isEmpty { tiles.append(.init(cell: ShareSettings.step(options.position), name: "接收端", placeholder: true)) }
        } else { tiles.append(.init(cell: .init(x: -1, y: 0), name: peers.first?.name ?? "主控端", placeholder: peers.isEmpty, color: peers.isEmpty ? nil : ShareStyle.peer(0))) }
        map.tiles = tiles
    }
    @objc func toggleLogin() {
        do { try ShareLogin.set(autostart.state == .on) } catch { showError(error) }
        autostart.state = ShareLogin.enabled ? .on : .off
        if autostart.state == .off && SMAppService.mainApp.status == .requiresApproval { status.stringValue = "請到「系統設定 › 一般 › 登入項目」允許 Barrier Share。" }
    }
    func updateControls() {
        transferring = transferring && core != nil
        let linkDown = enabled && link == nil
        stop.isHidden = !(enabled && !linkDown); start.isHidden = !stop.isHidden; start.title = enabled ? "恢復連線" : "繼續共用"
        start.isEnabled = !enabled || link == nil; stop.isEnabled = enabled
        arrange.isHidden = !options.host; arrange.isEnabled = !peers.isEmpty
        cancelSend.isHidden = !transferring; cancelSend.frame.origin.x = options.host ? 288 : 164
        status.textColor = enabled ? ShareStyle.ink : ShareStyle.muted
        search.isEnabled = link != nil; forget.isEnabled = link != nil && !peers.isEmpty; clear.isEnabled = !enabled && core == nil
        rebuildNearby(); updateCard()
    }
    func refreshRole() throws {
        peers.removeAll(); peersChanged(); computers.removeAll()
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
    @objc func copyDiagnostics() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(details.string, forType: .string)
        status.stringValue = "已複製診斷紀錄"
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
        guard let found = found else { setBanner(false); return }
        updateURL = found.url; bannerVersion = found.version
        bannerText.stringValue = "有新版 \(found.version) · 安裝時會自動關閉並重新開啟 Barrier Share"
        setBanner(dismissedUpdate != found.version)
        // While the window is closed a system notification announces it once per version.
        if announcedUpdate != found.version && !test && !window.isVisible {
            announcedUpdate = found.version
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }
                let content = UNMutableNotificationContent(); content.title = "Barrier Share 有新版 \(found.version)"; content.body = "點這裡下載更新，安裝時會自動重新開啟。"
                content.userInfo = ["url": found.url.absoluteString]
                center.add(UNNotificationRequest(identifier: "update-" + found.version, content: content, trigger: nil))
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let text = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: text) { NSWorkspace.shared.open(url) }
        completionHandler()
    }
    func sendTargets() { do { let list = try options.advanced.targetList(); if !list.isEmpty || link != nil { send("TARGETS\t" + list) } } catch { showError(error) } }
    // Host-side Barrier options plus direct addresses for computers on another subnet or VPN.
    // Advanced settings in three groups; each row has a name, a short explanation and a switch or menu.
    func buildAdvanced(_ a: ShareAdvanced) -> (NSWindow, () -> ShareAdvanced, ShareModalCloser) {
        let W: CGFloat = 520, width: CGFloat = W + 48
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.titled], backing: .buffered, defer: false); panel.title = "進階設定"
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 640)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor; panel.contentView = view
        var y: CGFloat = 18
        func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ x: CGFloat, _ yy: CGFloat, _ w: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.lineBreakMode = .byTruncatingTail; l.frame = NSRect(x: x, y: yy, width: w, height: size + 6); view.addSubview(l); return l
        }
        _ = label("進階設定", 18, .bold, ShareStyle.ink, 24, y, W); y += 30
        _ = label(options.host ? "由這台（主控端）套用到所有螢幕；儲存後自動重新連線。" : "切換設定只在主控端生效；這台目前是接收端。", 12, .regular, ShareStyle.muted, 24, y, W); y += 30
        var group: ShareCard?, rowY: CGFloat = 0
        func section(_ text: String) { _ = label(text, 11, .semibold, ShareStyle.muted, 24, y, W); y += 20; let card = ShareCard(frame: NSRect(x: 24, y: y, width: W, height: 10)); view.addSubview(card); group = card; rowY = 0 }
        func row(_ title: String, _ detail: String?, _ control: NSView) {
            guard let card = group else { return }
            let h: CGFloat = detail == nil ? 44 : 56
            if rowY > 0 { let rule = NSBox(frame: NSRect(x: 14, y: rowY, width: W - 28, height: 1)); rule.boxType = .custom; rule.borderWidth = 0; rule.fillColor = ShareStyle.line; card.addSubview(rule) }
            let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 13); t.textColor = ShareStyle.ink; t.frame = NSRect(x: 14, y: rowY + (detail == nil ? 13 : 9), width: W - 48 - control.frame.width, height: 18); card.addSubview(t)
            if let detail = detail { let d = NSTextField(labelWithString: detail); d.font = .systemFont(ofSize: 11); d.textColor = ShareStyle.faint; d.frame = NSRect(x: 14, y: rowY + 30, width: W - 48 - control.frame.width, height: 16); card.addSubview(d) }
            control.frame.origin = NSPoint(x: W - 14 - control.frame.width, y: rowY + (h - control.frame.height) / 2); control.setAccessibilityLabel(title); card.addSubview(control)
            rowY += h; card.frame.size.height = rowY + 1; y = card.frame.maxY
        }
        func toggle(_ value: Bool) -> NSSwitch { let s = NSSwitch(); s.state = value ? .on : .off; s.frame.size = s.fittingSize; return s }
        func choice(_ values: [Int], _ name: (Int) -> String, _ current: Int) -> NSPopUpButton {
            var list = values; if !list.contains(current) { list.append(current); list.sort() }
            let box = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 26)); box.addItems(withTitles: list.map(name)); box.selectItem(at: list.firstIndex(of: current) ?? 0)
            for (i, v) in list.enumerated() { box.item(at: i)?.tag = v }; return box
        }
        func seconds(_ v: Int) -> String { v % 1000 == 0 ? "\(v / 1000) 秒" : String(format: "%g 秒", Double(v) / 1000) }
        section("切換螢幕")
        let delay = choice([0, 250, 500, 1000], { $0 == 0 ? "立即" : seconds($0) }, a.switchDelay); row("停留多久才切換", "避免滑鼠擦過邊緣就跑到另一台", delay)
        let tap = choice([0, 250, 400], { $0 == 0 ? "關閉" : seconds($0) + "內" }, a.doubleTap); row("連碰兩下邊緣才切換", nil, tap)
        let corners = toggle(a.corners); row("螢幕角落不切換", "方便點角落的選單或關閉鈕", corners)
        let keys = toggle(a.switchKeys); row("啟用切換快捷鍵", "開啟後，按 Control+Option+方向鍵切到另一台", keys)
        let direct = toggle(a.directKeys); row("啟用跳到指定電腦快捷鍵", "按 Control+Option+1 回到這台，2 以後依排列螢幕的順序", direct)
        let needs = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 26)); needs.addItems(withTitles: ["不需要", "Shift", "Control", "Option"])
        needs.selectItem(at: ["", "shift", "control", "alt"].firstIndex(of: a.switchNeeds) ?? 0)
        row("按住按鍵才切換", "要按住這個鍵，滑鼠碰到邊緣才會切換", needs)
        y += 16; section("鍵盤與滑鼠")
        let swap = toggle(a.swapModifiers); row("在 Windows 上對調 Control 與 Command", "Mac 鍵盤在 Windows 上可按 ⌘C／⌘V；兩台都是 Mac 時不對調", swap)
        let lock = toggle(a.lockKey); row("啟用鎖定游標快捷鍵", "開啟後，按 Control+Option+L 鎖定或解除；鎖定時游標不會跑到另一台", lock)
        let relative = toggle(a.relativeMouse); row("相對滑鼠移動", "全螢幕遊戲用", relative)
        let saver = toggle(a.screenSaver); row("同步螢幕保護程式", nil, saver)
        let broadcast = toggle(a.broadcastKey); row("啟用鍵盤廣播快捷鍵", "開啟後，按 Control+Option+B 開始或停止：打的字會同時送到所有電腦", broadcast)
        let caps = toggle(a.capsLockFix); row("接收端的 Caps Lock 修正", "接收端的大小寫或 Caps Lock 燈號跟按鍵對不上時再開啟", caps)
        let focus = toggle(a.preserveFocus); row("切走時保留這台的視窗焦點", "游標移到另一台時，這台目前使用中的視窗不會失去焦點", focus)
        y += 16; section("剪貼簿")
        let clip = toggle(a.clipboard); row("共用剪貼簿", "關閉後，兩台不再同步複製的文字和檔案", clip)
        y += 16; section("這台當接收端時（只影響這台）")
        let wheelValues = [50, 75, 100, 150, 200]
        let wheel = choice(wheelValues, { "\($0)%" }, a.wheelScale); row("滾輪速度", "另一台的滑鼠在這台捲動時的速度", wheel)
        let invert = toggle(a.wheelInvert); row("反轉滾輪方向", "Mac 自然捲動和 Windows 方向相反時開啟", invert)
        y += 16; section("連線")
        let targetScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 44)); targetScroll.hasVerticalScroller = true; targetScroll.borderType = .bezelBorder
        let targets = NSTextView(frame: targetScroll.bounds); targets.isRichText = false; targets.font = .monospacedSystemFont(ofSize: 12, weight: .regular); targets.autoresizingMask = [.width]
        targets.string = a.targets.components(separatedBy: CharacterSet(charactersIn: ", ;\r\n")).filter { !$0.isEmpty }.joined(separator: "\n"); targetScroll.documentView = targets
        row("手動位址", "跨網段或 VPN 時填入對方 IP，一行一個", targetScroll)
        y += 8
        let buttonsY = y + 8
        let reset = NSButton(title: "恢復預設", target: nil, action: nil); reset.bezelStyle = .rounded; reset.frame = NSRect(x: 24, y: buttonsY, width: 100, height: 32); view.addSubview(reset)
        let cancel = NSButton(title: "取消", target: nil, action: nil); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; cancel.frame = NSRect(x: W + 24 - 232, y: buttonsY, width: 108, height: 32); view.addSubview(cancel)
        let save = SharePrimaryButton(title: "儲存", target: nil, action: nil); save.frame = NSRect(x: W + 24 - 112, y: buttonsY, width: 112, height: 32); view.addSubview(save)
        let closer = ShareModalCloser(panel); save.target = closer; save.action = #selector(ShareModalCloser.accept); cancel.target = closer; cancel.action = #selector(ShareModalCloser.cancel)
        // Rows scroll; the buttons stay fixed underneath.
        let rowsHeight = buttonsY, visible = min(rowsHeight, 600)
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: visible + 56)); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: visible)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        view.frame.size = NSSize(width: width, height: rowsHeight); scroll.documentView = view; root.addSubview(scroll)
        for b in [reset, cancel, save] { b.removeFromSuperview(); b.frame.origin.y = visible + 12; root.addSubview(b) }
        panel.contentView = root; panel.setContentSize(root.frame.size)
        let resetter = ShareBlockTarget { _ in
            let d = ShareAdvanced()
            delay.selectItem(withTag: d.switchDelay); tap.selectItem(withTag: d.doubleTap)
            for (box, on) in [(corners, d.corners), (keys, d.switchKeys), (swap, d.swapModifiers), (lock, d.lockKey), (relative, d.relativeMouse), (saver, d.screenSaver),
                              (direct, d.directKeys), (broadcast, d.broadcastKey), (caps, d.capsLockFix), (focus, d.preserveFocus), (clip, d.clipboard), (invert, d.wheelInvert)] { box.state = on ? .on : .off }
            needs.selectItem(at: 0); wheel.selectItem(withTag: d.wheelScale)
        }
        reset.target = resetter; reset.action = #selector(ShareBlockTarget.toggle)
        objc_setAssociatedObject(panel, "targets", [closer, resetter], .OBJC_ASSOCIATION_RETAIN)
        let read = { () -> ShareAdvanced in
            var v = ShareAdvanced(); v.cornerSize = a.cornerSize
            v.switchDelay = delay.selectedTag(); v.doubleTap = tap.selectedTag()
            v.corners = corners.state == .on; v.swapModifiers = swap.state == .on; v.relativeMouse = relative.state == .on; v.screenSaver = saver.state == .on
            v.switchKeys = keys.state == .on; v.lockKey = lock.state == .on
            v.directKeys = direct.state == .on; v.broadcastKey = broadcast.state == .on; v.capsLockFix = caps.state == .on; v.preserveFocus = focus.state == .on
            v.clipboard = clip.state == .on; v.wheelInvert = invert.state == .on; v.wheelScale = wheel.selectedTag()
            v.switchNeeds = ["", "shift", "control", "alt"][max(0, needs.indexOfSelectedItem)]
            v.targets = targets.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
            // The expert Barrier options box was removed; a value saved by an older version is kept.
            v.extra = a.extra
            return v
        }
        return (panel, read, closer)
    }
    @objc func showAdvanced() {
        let (panel, read, closer) = buildAdvanced(options.advanced)
        while true {
            panel.center(); NSApp.runModal(for: panel); panel.orderOut(nil)
            guard closer.accepted else { return }
            let value = read()
            do {
                // Only the visible fields are checked; a hidden value from the removed expert box must not block saving.
                _ = try value.targetList()
                options.advanced = value; try ShareSettings.save(options); sendTargets()
                // The host core reads options at start; the saved pairing reconnects it right away.
                if options.host && core != nil { stopBackend() }
                status.stringValue = "已儲存進階設定。"; peersChanged(); return
            } catch { let alert = NSAlert(); alert.messageText = "進階設定"; alert.informativeText = error.localizedDescription; alert.runModal() }
        }
    }
    @objc func openUpdate() { if let url = updateURL { NSWorkspace.shared.open(url) } }
    @objc func roleChanged() { guard !loading else { return }; stopLink(); stopBackend(); options.host = role.indexOfSelectedItem == 0; segment.selectedSegment = role.indexOfSelectedItem; roleChangedLabel(); do { try refreshRole(); if enabled { startLink() } } catch { showError(error) } }
    @objc func searchNow() { send("SEARCH"); status.stringValue = "正在搜尋同一區網的電腦…" }
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
        endProcess(process); computers.removeAll(); updateControls()
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
            computers.removeAll { $0.fingerprint == f[1] }; computers.append(NearbyComputer(fingerprint: f[1], name: decoded(f[2]), address: f[3]))
        } else if f[0] == "PLATFORM" && f.count == 3 {
            guard options.platforms[f[1]] != f[2] else { return }
            options.platforms[f[1]] = f[2]
            do { try ShareSettings.save(options) } catch { showError(error) }
            // The swap is written into the host's screen config, so restart the core to apply it.
            if options.host && core != nil { stopBackend(); startBackend() }
        } else if f[0] == "GONE" && f.count == 2 { computers.removeAll { $0.fingerprint == f[1] } }
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
    // Pairing dialog: both computers, the 6-digit code in 3+3 boxes, reject (Enter) or accept.
    func showConsent(_ message: [String]) {
        closeConsent(); showWindow(); let id = message[1]; consentId = id
        let request = message[0] == "REQUEST"
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 372), styleMask: [.titled], backing: .buffered, defer: false)
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: 440, height: 372)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor; panel.contentView = view
        func put(_ v: NSView, _ r: NSRect) { v.frame = r; view.addSubview(v) }
        func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ r: NSRect) {
            let l = NSTextField(wrappingLabelWithString: text); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.alignment = .center; put(l, r)
        }
        put(ShareComputerMark(), NSRect(x: 150, y: 22, width: 44, height: 44))
        label("⟷", 18, .regular, ShareStyle.faint, NSRect(x: 198, y: 30, width: 44, height: 26))
        let other = ShareComputerMark(); other.symbol = "desktopcomputer"; put(other, NSRect(x: 246, y: 22, width: 44, height: 44))
        label(request ? "收到配對邀請" : "核對配對碼", 19, .bold, ShareStyle.ink, NSRect(x: 24, y: 80, width: 392, height: 26))
        label("\(decoded(message[2]))\n請確認另一台顯示相同的 6 位數配對碼。", 13, .regular, ShareStyle.muted, NSRect(x: 24, y: 112, width: 392, height: 40))
        let code = ShareCodeView(); code.code = message[4]; put(code, NSRect(x: 20, y: 162, width: 400, height: 70))
        label("同意後允許共用鍵盤滑鼠及雙向同步剪貼簿。\n配對會被記住，之後自動連線。", 11, .regular, ShareStyle.faint, NSRect(x: 24, y: 242, width: 392, height: 34))
        // Enter rejects: agreeing always takes a deliberate click.
        let reject = NSButton(title: "拒絕", target: self, action: #selector(consentReject)); reject.bezelStyle = .rounded; reject.keyEquivalent = "\r"; put(reject, NSRect(x: 24, y: 304, width: 128, height: 40))
        let accept = SharePrimaryButton(title: "相同，同意配對", target: self, action: #selector(consentAccept)); put(accept, NSRect(x: 164, y: 304, width: 252, height: 40))
        consent = panel; updateControls()
        window.beginSheet(panel) { [weak self] response in
            guard let self = self, self.consentId == id else { return }; self.consent = nil; self.consentId = nil
            self.send((response == .OK ? "ACCEPT\t" : "REJECT\t") + id)
            self.status.stringValue = response == .OK ? "已同意，等待對方確認…" : "已拒絕配對。"; self.updateControls()
        }
    }
    @objc func consentReject() { if let panel = consent { window.endSheet(panel, returnCode: .cancel) } }
    @objc func consentAccept() { if let panel = consent { window.endSheet(panel, returnCode: .OK) } }
    func closeConsent() { let panel = consent; consent = nil; consentId = nil; if let panel = panel { window.endSheet(panel, returnCode: .abort); panel.orderOut(nil) } }
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
        if names.count == 1 && options.host {
            let grid = ShareSettings.cells(options.position, receivers: peers.map { $0.fingerprint }, layout: options.layout)
            let cell = grid.first { $0.0 == ShareSettings.screenName(peers[0].fingerprint) }?.1
            let words = [ShareSettings.Cell(x: 1, y: 0): "右", ShareSettings.Cell(x: -1, y: 0): "左", ShareSettings.Cell(x: 0, y: -1): "上", ShareSettings.Cell(x: 0, y: 1): "下"]
            peerLabel.stringValue = cell.flatMap { words[$0] }.map { "滑鼠往\($0)移到 \(names[0])" } ?? "已配對 · \(names[0])"
        } else if names.count == 1 { peerLabel.stringValue = "已配對主控端 · \(names[0])" }
        else if names.count > 1 { peerLabel.stringValue = "已配對 \(names.count) 台 · " + names.joined(separator: "、") }
        else { peerLabel.stringValue = options.host ? "在下方選擇接收端，按「邀請配對」。" : "等待主控端邀請；首次需要你同意。" }
        if options.host && !options.advanced.clipboard { peerLabel.stringValue += " · 剪貼簿未共用" }
        updateControls()
    }
    // Arrange screens: coloured tiles on a grid, a list of where each one sits, restore/cancel/save.
    func buildLayout() -> (NSWindow, ShareLayoutView, () -> Bool, ShareRangeTarget) {
        let grid = ShareSettings.cells(options.position, receivers: peers.map { $0.fingerprint }, layout: options.layout)
        var placement: [String: ShareSettings.Cell] = [:]
        for p in peers { if let cell = grid.first(where: { $0.0 == ShareSettings.screenName(p.fingerprint) })?.1 { placement[p.fingerprint] = cell } }
        let colors = Dictionary(uniqueKeysWithValues: peers.enumerated().map { ($0.element.fingerprint, ShareStyle.peer($0.offset)) })
        let layoutView = ShareLayoutView(names: Dictionary(uniqueKeysWithValues: peers.map { ($0.fingerprint, $0.name) }), placement: placement, blue: blue); layoutView.colors = colors
        let width = layoutView.frame.width + 248, height = layoutView.frame.height + 140
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false); panel.title = "排列螢幕"
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor; panel.contentView = view
        let title = NSTextField(labelWithString: "排列螢幕"); title.font = .systemFont(ofSize: 18, weight: .bold); title.frame = NSRect(x: 24, y: 18, width: 300, height: 24); view.addSubview(title)
        let hint = NSTextField(labelWithString: "拖曳電腦到這台的上下左右；相鄰的邊就是游標可以移過去的地方。螢幕大小不同時，可在右側選擇只相接上半段或下半段。"); hint.textColor = ShareStyle.muted; hint.font = .systemFont(ofSize: 12); hint.frame = NSRect(x: 24, y: 46, width: width - 48, height: 18); view.addSubview(hint)
        layoutView.frame.origin = NSPoint(x: 24, y: 76); view.addSubview(layoutView)
        let list = FlippedView(frame: NSRect(x: layoutView.frame.maxX + 20, y: 76, width: 204, height: layoutView.frame.height)); view.addSubview(list)
        let ranges = ShareRangeTarget(options.edgeRange)
        let warning = NSTextField(wrappingLabelWithString: ""); warning.textColor = ShareStyle.danger; warning.font = .systemFont(ofSize: 12); warning.frame = NSRect(x: 24, y: layoutView.frame.maxY + 10, width: width - 48, height: 32); view.addSubview(warning)
        let buttonsY = height - 56
        let reset = NSButton(title: "恢復預設", target: nil, action: nil); reset.bezelStyle = .rounded; reset.frame = NSRect(x: 24, y: buttonsY, width: 100, height: 32); view.addSubview(reset)
        let cancel = NSButton(title: "取消", target: nil, action: nil); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; cancel.frame = NSRect(x: width - 248, y: buttonsY, width: 108, height: 32); view.addSubview(cancel)
        let save = SharePrimaryButton(title: "儲存", target: nil, action: nil); save.frame = NSRect(x: width - 132, y: buttonsY, width: 108, height: 32); view.addSubview(save)
        let words = [ShareSettings.Cell(x: 1, y: 0): "右", ShareSettings.Cell(x: -1, y: 0): "左", ShareSettings.Cell(x: 0, y: -1): "上", ShareSettings.Cell(x: 0, y: 1): "下"]
        let refresh = { [weak layoutView, weak list, weak warning, weak save] in
            guard let layoutView = layoutView, let list = list else { return }
            list.subviews.forEach { $0.removeFromSuperview() }
            var y: CGFloat = 0
            for (i, p) in self.peers.enumerated() {
                let dot = NSView(frame: NSRect(x: 0, y: y + 8, width: 12, height: 12)); dot.wantsLayer = true; dot.layer?.cornerRadius = 6; dot.layer?.backgroundColor = ShareStyle.peer(i).cgColor; list.addSubview(dot)
                let name = NSTextField(labelWithString: p.name); name.font = .systemFont(ofSize: 13, weight: .semibold); name.lineBreakMode = .byTruncatingTail; name.frame = NSRect(x: 20, y: y + 4, width: 184, height: 18); list.addSubview(name)
                let cell = layoutView.placement[p.fingerprint]
                var where_ = cell.flatMap { words[$0] }.map { "在這台的\($0)邊" } ?? "經由其他螢幕"
                if self.options.advanced.directKeys && i < 8 { where_ += " · 快捷鍵 Control+Option+\(i + 2)" }
                let place = NSTextField(labelWithString: where_); place.font = .systemFont(ofSize: 11); place.textColor = ShareStyle.muted; place.lineBreakMode = .byTruncatingTail; place.frame = NSRect(x: 20, y: y + 22, width: 184, height: 16); list.addSubview(place)
                y += 42
                // Only a receiver right next to this host shares an edge whose range can be limited.
                if let c = cell, words[c] != nil {
                    let horizontal = c.y == 0
                    let range = NSPopUpButton(frame: NSRect(x: 20, y: y - 2, width: 184, height: 24)); range.controlSize = .small; range.font = .systemFont(ofSize: 11)
                    range.addItems(withTitles: ["相接：整個邊", horizontal ? "相接：上半段" : "相接：左半段", horizontal ? "相接：下半段" : "相接：右半段"])
                    range.selectItem(at: ["all", "first", "second"].firstIndex(of: ranges.ranges[p.fingerprint] ?? "all") ?? 0)
                    range.identifier = NSUserInterfaceItemIdentifier(p.fingerprint); range.target = ranges; range.action = #selector(ShareRangeTarget.changed(_:))
                    range.toolTip = "兩台螢幕大小不同時，只讓邊的一段可以過去"; list.addSubview(range); y += 30
                }
                y += 8
            }
            let ok = layoutView.reachable()
            warning?.stringValue = ok ? "" : "有螢幕和這台連不上。請讓每台都緊鄰這台或其他螢幕。"; save?.isEnabled = ok
        }
        layoutView.onChange = refresh
        reset.target = layoutView; reset.action = #selector(ShareLayoutView.restoreDefaults)
        layoutView.defaults = { [weak self] in
            guard let self = self else { return [:] }
            let fresh = ShareSettings.cells(self.options.position, receivers: self.peers.map { $0.fingerprint }, layout: [:])
            var d: [String: ShareSettings.Cell] = [:]; for p in self.peers { if let c = fresh.first(where: { $0.0 == ShareSettings.screenName(p.fingerprint) })?.1 { d[p.fingerprint] = c } }; return d
        }
        var saved = false
        cancel.target = panel; cancel.action = #selector(NSWindow.close)
        let closer = ShareModalCloser(panel); save.target = closer; save.action = #selector(ShareModalCloser.accept); cancel.target = closer; cancel.action = #selector(ShareModalCloser.cancel)
        objc_setAssociatedObject(panel, "closer", [closer, ranges], .OBJC_ASSOCIATION_RETAIN)
        refresh()
        return (panel, layoutView, { saved = closer.accepted; return saved }, ranges)
    }
    @objc func showLayout() {
        let (panel, view, accepted, ranges) = buildLayout()
        panel.center(); NSApp.runModal(for: panel); panel.orderOut(nil)
        guard accepted(), view.reachable() else { return }
        for (fp, cell) in view.placement { options.layout[fp] = [cell.x, cell.y] }
        options.edgeRange = ranges.ranges.filter { $0.value != "all" }
        do { try ShareSettings.save(options); if core != nil { stopBackend() }; status.stringValue = "已儲存螢幕排列。"; peersChanged() } catch { showError(error) }
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
    func stopBackend() { let process = core; core = nil; connections = 0; corePipe?.fileHandleForReading.readabilityHandler = nil; corePipe = nil; endProcess(process); updateControls() }
    func log(_ line: String) {
        details.string = String((details.string + line + "\n").suffix(20000)); details.scrollToEndOfDocument(nil)
        if line.contains("connected to server") || line.contains("has connected") { status.stringValue = "已連線 · 雙向複製貼上已啟用"; connections += 1; updateCard() }
        if line.contains("disconnected from server") || line.contains("has disconnected") { connections = max(0, connections - 1); updateCard() }
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
            let copyAll = NSButton(title: "全部複製", target: self, action: #selector(copyDiagnostics)); copyAll.bezelStyle = .rounded
            copyAll.frame = NSRect(x: panel.contentView!.bounds.width - 138, y: 12, width: 120, height: 32); copyAll.autoresizingMask = [.minXMargin, .maxYMargin]; panel.contentView!.addSubview(copyAll)
            var area = panel.contentView!.bounds.insetBy(dx:18,dy:18); area.origin.y += 36; area.size.height -= 36
            let scroll=NSScrollView(frame:area); scroll.autoresizingMask=[.width,.height]; scroll.hasVerticalScroller=true; scroll.documentView=details; details.frame=scroll.bounds; panel.contentView!.addSubview(scroll); diagnostics=panel; panel.center()
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
    guard let edit = NSApp.mainMenu?.items.compactMap({ $0.submenu }).first(where: { $0.title == "編輯" }),
          edit.items.contains(where: { $0.keyEquivalent == "a" && $0.action == #selector(NSText.selectAll(_:)) }),
          edit.items.contains(where: { $0.keyEquivalent == "c" && $0.action == #selector(NSText.copy(_:)) }) else { throw ShareError.message("Edit menu lacks ⌘A / ⌘C") }
    let trayTest = NSMenu(); app.menuNeedsUpdate(trayTest)
    let trayTitles = trayTest.items.map { $0.title }
    for expected in ["開啟視窗", "排列螢幕…", "進階設定…", "登入時自動啟動", "診斷紀錄", "檢查更新", "結束"] where !trayTitles.contains(expected) { throw ShareError.message("Menu bar item missing: \(expected)") }
    let peer = "v2:sha256:" + String(repeating: "a", count: 64), name = Data("另一台電腦".utf8).base64EncodedString()
    app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.2\t24801\tR")
    app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.3\t24801\tR")
    guard app.computers.count == 1 && app.computers[0].address == "192.168.1.3" else { throw ShareError.message("Discovery list update failed") }
    app.linkLine("SAVED\t\(peer)\t\(name)")
    app.linkLine("VERIFY\ttest-request\t\(name)\t\(peer)\t123456")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    func snapshot(_ view: NSView?, _ file: String) throws {
        guard let view = view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShareError.message("Cannot render \(file)") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(file))
    }
    guard let pairing = app.consent?.contentView, pairing.subviews.contains(where: { ($0 as? ShareCodeView)?.code == "123456" }) else { throw ShareError.message("Missing pairing dialog or code") }
    try snapshot(pairing, "gui-pairing.png")
    app.linkLine("CLOSED\ttest-request")
    guard app.consent == nil && app.consentId == nil else { throw ShareError.message("Expired pairing dialog remained open") }
    app.linkLine("GONE\t\(peer)"); guard app.computers.isEmpty else { throw ShareError.message("Offline peer remained listed") }
    // Render the available-peer state without starting any input capture or network service.
    app.link = Process(); app.peers.removeAll(); app.peersChanged(); app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.3\t24801\tR")
    for (i, n) in ["客廳電腦", "MacBook Air", "書房 Windows"].enumerated() {
        let fp = "v2:sha256:" + String(repeating: String(i + 1), count: 64)
        app.linkLine("DEVICE\t\(fp)\t\(Data(n.utf8).base64EncodedString())\t192.168.1.\(10 + i)\t24801\tR"); app.linkLine("PLATFORM\t\(fp)\t\(i == 1 ? "mac" : "windows")")
    }
    app.status.stringValue = "找到附近電腦，可以發出配對邀請"
    guard app.nearbyList.subviews.count == 4, app.emptyNearby.isHidden, app.nearbyCount.stringValue == "4 台" else { throw ShareError.message("Nearby list did not show four computers") }
    let firstRow = app.nearbyList.subviews.first
    app.linkLine("DEVICE\t\(peer)\t\(name)\t192.168.1.3\t24801\tR"); app.status.stringValue = "狀態更新"; app.updateControls()
    guard app.nearbyList.subviews.first === firstRow else { throw ShareError.message("Unchanged discovery rebuilt the nearby list (flicker)") }
    app.filter.stringValue = "zzz"; app.rebuildNearby()
    guard app.emptyNearby.stringValue == "找不到符合的電腦" else { throw ShareError.message("Search box did not filter the list") }
    app.filter.stringValue = ""; app.rebuildNearby()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3)); app.window.displayIfNeeded()
    guard let view = app.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ShareError.message("Cannot render window") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.representation(using: .png, properties: [:]) else { throw ShareError.message("Cannot render PNG") }
    try image.write(to: directory.appendingPathComponent("gui-mac.png"))
    app.showUpdate(found); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard !app.banner.isHidden, app.bannerText.stringValue.contains("0.3.11") else { throw ShareError.message("Update banner did not show") }
    try snapshot(app.window.contentView, "gui-mac-update.png")
    app.dismissUpdate(); app.showUpdate(found)
    guard app.banner.isHidden else { throw ShareError.message("Dismissed update banner came back for the same version") }
    // Paired receiver: badge, summary and the arrange editor and advanced settings.
    app.linkLine("SAVED\t\(peer)\t\(name)"); app.connections = 1; app.updateControls()
    guard app.peerLabel.stringValue == "滑鼠往右移到 另一台電腦", app.badge.text == "已連線" else { throw ShareError.message("Connection card summary wrong: \(app.peerLabel.stringValue) / \(app.badge.text)") }
    try snapshot(app.window.contentView, "gui-mac-paired.png")
    let (layoutPanel, layoutView, _, _) = app.buildLayout()
    guard layoutView.reachable(), !layoutView.place(peer, .init(x: 2, y: 2)) || !layoutView.reachable() else { throw ShareError.message("Arrange editor rules failed") }
    layoutView.restoreDefaults(); try snapshot(layoutPanel.contentView, "gui-arrange.png")
    let (advancedPanel, readAdvanced, _) = app.buildAdvanced(ShareAdvanced())
    guard readAdvanced() == ShareAdvanced() else { throw ShareError.message("Advanced settings did not round-trip the defaults") }
    try snapshot(advancedPanel.contentView, "gui-advanced.png")
    try snapshot((advancedPanel.contentView?.subviews.first as? NSScrollView)?.documentView, "gui-advanced-all.png")
    // Original Barrier features: each setting writes its line into the host's screen config.
    var features = ShareAdvanced(); features.directKeys = true; features.broadcastKey = true; features.capsLockFix = true; features.preserveFocus = true
    features.clipboard = false; features.switchNeeds = "control"
    let fx = "v2:sha256:" + String(repeating: "e", count: 64), nx = ShareSettings.screenName(fx)
    let featureConfig = try ShareSettings.config("right", features, receivers: [fx], edgeRange: [fx: "first"])
    for expected in [" clipboardSharing = false\n", " switchNeedsControl = true\n", " keystroke(Control+Alt+B) = keyboardBroadcast(toggle)\n",
                     " keystroke(Control+Alt+1) = switchToScreen(windows-host)\n", " keystroke(Control+Alt+2) = switchToScreen(\(nx))\n",
                     " \(nx):\n  ctrl = super\n  super = ctrl\n  halfDuplexCapsLock = true\n", " windows-host:\n  preserveFocus = true\n",
                     "  right(0,50) = \(nx)\n", "  left = windows-host(0,50)\n"] where !featureConfig.contains(expected) {
        throw ShareError.message("Feature config missing: \(expected)")
    }
    guard try ShareSettings.config("right").contains(" clipboardSharing = true\n"), !(try ShareSettings.config("right")).contains("switchNeeds") else { throw ShareError.message("Feature defaults changed the config") }
    var receiverOptions = ShareOptions(); receiverOptions.host = false; receiverOptions.address = "192.168.1.5"; receiverOptions.advanced.wheelScale = 150; receiverOptions.advanced.wheelInvert = true
    guard let wheelArgs = try ShareSettings.command(receiverOptions).arguments, wheelArgs.contains("--wheel-invert"), let at = wheelArgs.firstIndex(of: "--wheel-scale"), wheelArgs[at + 1] == "150" else { throw ShareError.message("Receiver wheel arguments missing") }
    guard try ShareSettings.run("barrierc", ["--help"], allowFailure: true).contains("--wheel-scale") else { throw ShareError.message("Core lacks --wheel-scale") }
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
