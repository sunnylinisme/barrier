// SPDX-License-Identifier: GPL-2.0-or-later
// Portable desktop frontend; the existing Barrier processes own the connection.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Xml.Linq;

[assembly: System.Reflection.AssemblyVersion("0.3.11.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.3.11.0")]

static class ShareSettings
{
    public static string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BarrierShare");
    public static string Bin = AppDomain.CurrentDomain.BaseDirectory;
    public static readonly string[] Directions = { "right", "left", "up", "down" };
    public static string Position = "right";
    public static string Profile(bool host) { return Path.Combine(Root, host ? "profile-server" : "profile"); }
    public static string Quote(string value)
    {
        // CommandLineToArgvW quoting, including trailing backslashes.
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char character in value) {
            if (character == '\\') { ++slashes; continue; }
            result.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
            result.Append(character); slashes = 0;
        }
        result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
    }
    public static ProcessStartInfo Command(string exe, params string[] args)
    {
        return new ProcessStartInfo(Path.Combine(Bin, exe), String.Join(" ", args.Select(Quote).ToArray())) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, WorkingDirectory = Bin,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
    }
    public static string Pair(params string[] args)
    {
        using (var process = Process.Start(Command("barrier-pair.exe", args))) {
            var output = Task.Factory.StartNew(() => process.StandardOutput.ReadToEnd());
            var error = Task.Factory.StartNew(() => process.StandardError.ReadToEnd());
            if (!process.WaitForExit(15000)) { process.Kill(); throw new IOException("配對工具未回應。"); }
            if (process.ExitCode != 0) throw new IOException(error.Result + output.Result);
            return output.Result.Trim();
        }
    }
    public static string Init(bool host) { return Pair("init", Profile(host)); }
    public static void Save(bool host, string address)
    {
        Directory.CreateDirectory(Root);
        var document = new XDocument(new XElement("settings", new XAttribute("host", host), new XAttribute("address", address), new XAttribute("position", Position), Advanced.ToXml(),
            new XElement("layout", Layout.Select(item => new XElement("screen", new XAttribute("fingerprint", item.Key), new XAttribute("x", item.Value.X), new XAttribute("y", item.Value.Y)))),
            new XElement("platforms", Platforms.Select(item => new XElement("peer", new XAttribute("fingerprint", item.Key), new XAttribute("system", item.Value))))));
        string path = Path.Combine(Root, "settings.xml"), temporary = path + ".new";
        document.Save(temporary);
        if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
    }
    public static void Load(out bool host, out string address)
    {
        host = true; address = ""; Position = "right"; Advanced = new ShareAdvanced(); Layout = new Dictionary<string, Point>(); Platforms = new Dictionary<string, string>();
        string path = Path.Combine(Root, "settings.xml");
        if (!File.Exists(path)) return;
        var root = XDocument.Load(path).Root;
        host = (bool)root.Attribute("host"); address = (string)root.Attribute("address") ?? "";
        string position = (string)root.Attribute("position");
        Position = Directions.Contains(position) ? position : "right";
        Advanced = ShareAdvanced.FromXml(root.Element("advanced"));
        var platforms = root.Element("platforms");
        if (platforms != null) foreach (var peer in platforms.Elements("peer")) {
            string fp = (string)peer.Attribute("fingerprint"), system = (string)peer.Attribute("system");
            if (fp != null && (system == "mac" || system == "windows" || system == "linux")) Platforms[fp] = system;
        }
        var layout = root.Element("layout");
        if (layout != null) foreach (var screen in layout.Elements("screen")) {
            int x, y; string fp = (string)screen.Attribute("fingerprint");
            if (fp != null && Int32.TryParse((string)screen.Attribute("x"), out x) && Int32.TryParse((string)screen.Attribute("y"), out y) && Math.Abs(x) <= 2 && Math.Abs(y) <= 2) Layout[fp] = new Point(x, y);
        }
    }
    public static ShareAdvanced Advanced = new ShareAdvanced();
    // Paired receivers (host role) in pairing order, and where each sits relative to this host (0,0)
    // on a 5x5 grid; x grows to the right and y downwards.
    public static List<string> Receivers = new List<string>();
    public static Dictionary<string, Point> Layout = new Dictionary<string, Point>();
    // System of each paired computer as reported by its discovery reply (0.3.9+); unknown means Windows.
    public static Dictionary<string, string> Platforms = new Dictionary<string, string>();
    // Ctrl and Command/Windows are swapped only between a Windows host and a Mac receiver.
    public static bool SwapFor(string screen)
    {
        if (screen == HostName) return false;
        if (Receivers.Count == 0) return true; // the classic two-screen form without pairing data
        string fp = Receivers.FirstOrDefault(r => ScreenName(r) == screen), system;
        return fp != null && Platforms.TryGetValue(fp, out system) && system == "mac";
    }
    public static string OwnFingerprint;
    public const string HostName = "windows-host";
    // Core screen name of a receiver; unique per computer so several can connect at once.
    public static string ScreenName(string fingerprint) { return "r-" + fingerprint.Substring(10, 16); }
    static readonly Point[] Steps = { new Point(1, 0), new Point(-1, 0), new Point(0, -1), new Point(0, 1) };
    public static Point Step(string direction) { return Steps[Array.IndexOf(Directions, direction)]; }
    // Screen name -> grid cell. Without paired receivers this is the classic host + "windows" pair.
    public static Dictionary<string, Point> Cells()
    {
        var cells = new Dictionary<string, Point> { { HostName, Point.Empty } };
        if (Receivers.Count == 0) { cells["windows"] = Step(Position); return cells; }
        // Free spots: the chosen side, the opposite side, above, below, then further out.
        var order = new List<Point> { Step(Position), Step(Opposite(Position)), new Point(0, -1), new Point(0, 1), new Point(1, 0), new Point(-1, 0) };
        foreach (int ring in new[] { 1, 2 }) for (int y = -ring; y <= ring; ++y) for (int x = -ring; x <= ring; ++x) if (Math.Max(Math.Abs(x), Math.Abs(y)) == ring) order.Add(new Point(x, y));
        for (int i = 0; i < Receivers.Count; ++i) {
            Point cell; string fp = Receivers[i];
            if (!Layout.TryGetValue(fp, out cell) || cells.ContainsValue(cell)) cell = i == 0 && !cells.ContainsValue(Step(Position)) ? Step(Position) : order.First(c => !cells.ContainsValue(c) && c != Point.Empty);
            cells[ScreenName(fp)] = cell;
        }
        return cells;
    }
    // Directions in which some screen has a neighbour, the primary direction first.
    static IEnumerable<string> UsedDirections(Dictionary<string, Point> cells)
    {
        var ordered = new List<string> { Position, Opposite(Position) }; ordered.AddRange(Directions.Where(d => !ordered.Contains(d)));
        return ordered.Where(d => cells.Values.Any(c => cells.ContainsValue(new Point(c.X + Step(d).X, c.Y + Step(d).Y))));
    }
    public static string Opposite(string direction) { return new[] { "left", "right", "down", "up" }[Array.IndexOf(Directions, direction)]; }
    static void CopyTree(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (string file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(target, Path.GetFileName(file)), true);
        foreach (string directory in Directory.GetDirectories(source)) {
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("設定資料夾不可使用連結。");
            CopyTree(directory, Path.Combine(target, Path.GetFileName(directory)));
        }
    }
    public static bool Import(string oldPackage, bool host, bool replace)
    {
        string source = Path.Combine(oldPackage, host ? "profile-server" : "profile", "SSL");
        if (!Directory.Exists(source)) source = Path.Combine(oldPackage, "SSL");
        if (!File.Exists(Path.Combine(source, "Barrier.pem"))) return false;
        string target = Path.Combine(Profile(host), "SSL");
        if (Path.GetFullPath(source).TrimEnd('\\').Equals(Path.GetFullPath(target).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return false;
        if (File.Exists(Path.Combine(target, "Barrier.pem")) && !replace) return false;
        Directory.CreateDirectory(Profile(host));
        string staged = target + ".import-" + Guid.NewGuid().ToString("N");
        try {
            CopyTree(source, staged);
            // Validate the imported certificate before replacing any active pairing.
            string validation = Path.Combine(Profile(host), "validate-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(validation);
            try { Directory.Move(staged, Path.Combine(validation, "SSL")); Pair("init", validation); Directory.Move(Path.Combine(validation, "SSL"), staged); }
            finally { Directory.Delete(validation, true); }
            if (Directory.Exists(target)) Directory.Move(target, target + ".backup-" + DateTime.UtcNow.ToString("yyyyMMddHHmmssfff"));
            Directory.Move(staged, target);
            return true;
        } finally { if (Directory.Exists(staged)) Directory.Delete(staged, true); }
    }
    public static string TrustedPath(bool host)
    {
        return Path.Combine(Profile(host), "SSL", "Fingerprints", host ? "TrustedClients.txt" : "TrustedServers.txt");
    }
    public static bool Trusted(bool host, string fingerprint)
    {
        string path = TrustedPath(host);
        return File.Exists(path) && File.ReadAllLines(path).Any(line => line.Trim() == fingerprint);
    }
    public static string Config(bool clipboard)
    {
        if (!Directions.Contains(Position)) throw new IOException("請選擇有效的螢幕位置。");
        var a = Advanced; var cells = Cells(); var b = new StringBuilder("section: screens\n");
        foreach (var screen in cells.Keys) {
            b.Append(" " + screen + ":\n");
            // Swap on the receiving screens: Ctrl acts as Command/Windows there and the other way round.
            if (a.SwapModifiers && SwapFor(screen)) b.Append("  ctrl = super\n  super = ctrl\n");
        }
        // The first receiver also answers to "windows", the name receivers used before 0.3.9.
        if (Receivers.Count > 0) b.Append("end\nsection: aliases\n " + ScreenName(Receivers[0]) + ":\n  windows\n");
        b.Append("end\nsection: links\n");
        foreach (var screen in cells) {
            b.Append(" " + screen.Key + ":\n");
            foreach (string d in new[] { Position, Opposite(Position) }.Concat(Directions).Distinct()) {
                var next = new Point(screen.Value.X + Step(d).X, screen.Value.Y + Step(d).Y);
                foreach (var other in cells) if (other.Value == next) b.Append("  " + d + " = " + other.Key + "\n");
            }
        }
        b.Append("end\nsection: options\n clipboardSharing = " + (clipboard ? "true" : "false") + "\n");
        if (a.SwitchDelay > 0) b.Append(" switchDelay = " + a.SwitchDelay + "\n");
        if (a.DoubleTap > 0) b.Append(" switchDoubleTap = " + a.DoubleTap + "\n");
        if (a.Corners) b.Append(" switchCorners = all\n switchCornerSize = " + a.CornerSize + "\n");
        if (a.RelativeMouse) b.Append(" relativeMouseMoves = true\n");
        b.Append(" screenSaverSync = " + (a.ScreenSaver ? "true" : "false") + "\n");
        if (a.SwitchKeys) foreach (string d in UsedDirections(cells)) b.Append(" keystroke(Control+Alt+" + Char.ToUpperInvariant(d[0]) + d.Substring(1) + ") = switchInDirection(" + d + ")\n");
        if (a.LockKey) b.Append(" keystroke(Control+Alt+L) = lockCursorToScreen(toggle)\n");
        foreach (string line in a.ExtraLines()) b.Append(" " + line + "\n");
        return b.Append("end\n").ToString();
    }
    public static string ReceiverName { get { return OwnFingerprint != null ? ScreenName(OwnFingerprint) : "windows"; } }
    public static ProcessStartInfo Backend(bool host, string address)
    {
        string profile = Profile(host);
        var args = new List<string> { "-f", "--no-tray", "--file-clipboard", "--profile-dir", profile,
            "--log", Path.Combine(profile, host ? "server.log" : "windows.log"), "--name", host ? HostName : ReceiverName };
        if (host) {
            string config = Path.Combine(profile, "windows-windows.conf");
            File.WriteAllText(config, Config(true), new UTF8Encoding(false)); args.Add("-c"); args.Add(config);
        } else {
            IPAddress parsed;
            if (!IPAddress.TryParse(address, out parsed) || parsed.AddressFamily != AddressFamily.InterNetwork)
                throw new IOException("請輸入主控端的區域網路 IPv4 位址，例如 192.168.1.20。");
            args.Add(address);
        }
        return Command(host ? "barriers.exe" : "barrierc.exe", args.ToArray());
    }
}

// Looks up the newest published Windows release; only the public release list is requested, nothing is sent.
static class ShareUpdate
{
    public const string Releases = "https://api.github.com/repos/sunnylinisme/barrier/releases?per_page=30";
    // Shared vX.Y.Z releases carry both platforms; windows-vX.Y.Z is the pre-0.3.9 Windows-only form.
    static readonly string[] Prefixes = { "v", "windows-v" };
    public static Version Current { get { var v = typeof(ShareUpdate).Assembly.GetName().Version; return new Version(v.Major, v.Minor, Math.Max(0, v.Build)); } }
    // CI stamps test builds with the run number as the fourth part and the commit; releases have 0 and "".
    static readonly string BuildCommit = "";
    public static int Build { get { return Math.Max(0, typeof(ShareUpdate).Assembly.GetName().Version.Revision); } }
    // "0.3.9" for a release, "0.3.9.123 測試版" for a test build.
    public static string Label { get { return Build > 0 ? Current + "." + Build + " 測試版" : Current.ToString(); } }
    public static string Details { get { return "版本 " + Label + (BuildCommit.Length > 0 ? "，commit " + BuildCommit : ""); } }
    public sealed class Found { public Version Version; public string Url; }
    // Returns the highest non-draft, non-prerelease Windows release newer than current, or null.
    public static Found Newer(string json, Version current)
    {
        Found best = null;
        var releases = new JavaScriptSerializer().DeserializeObject(json) as object[];
        if (releases == null) return null;
        foreach (var item in releases.OfType<Dictionary<string, object>>()) {
            object tag, url, draft, pre;
            if (!item.TryGetValue("tag_name", out tag) || !item.TryGetValue("html_url", out url)) continue;
            if ((item.TryGetValue("draft", out draft) && true.Equals(draft)) || (item.TryGetValue("prerelease", out pre) && true.Equals(pre))) continue;
            string name = tag as string, link = url as string; Version version;
            string prefix = name == null ? null : Prefixes.FirstOrDefault(p => name.StartsWith(p, StringComparison.Ordinal));
            if (prefix == null || link == null || !Version.TryParse(name.Substring(prefix.Length), out version)) continue;
            if (!link.StartsWith("https://github.com/sunnylinisme/barrier/releases/")) continue;
            version = new Version(version.Major, version.Minor, Math.Max(0, version.Build));
            if (version > current && (best == null || version > best.Version)) best = new Found { Version = version, Url = link };
        }
        return best;
    }
    public static Found Check()
    {
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        var request = (HttpWebRequest)WebRequest.Create(Releases);
        request.UserAgent = "BarrierShare-UpdateCheck"; request.Accept = "application/vnd.github+json"; request.Timeout = 15000;
        using (var response = request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            return Newer(reader.ReadToEnd(), Current);
    }
}

// Host-side Barrier options from the advanced settings dialog; saved in settings.xml.
sealed class ShareAdvanced
{
    public int SwitchDelay, DoubleTap, CornerSize = 16;
    // SwapModifiers defaults on: a Mac keyboard on Windows (and the reverse) then copies with ⌘C / Ctrl+C.
    public bool Corners, SwapModifiers = true, RelativeMouse, ScreenSaver = true, SwitchKeys = true, LockKey;
    public string Extra = "", Targets = "";
    static int Clamp(int value, int max) { return Math.Max(0, Math.Min(max, value)); }
    public XElement ToXml()
    {
        return new XElement("advanced", new XAttribute("switchDelay", SwitchDelay), new XAttribute("doubleTap", DoubleTap), new XAttribute("corners", Corners), new XAttribute("cornerSize", CornerSize),
            new XAttribute("swapModifiers", SwapModifiers), new XAttribute("relativeMouse", RelativeMouse), new XAttribute("screenSaver", ScreenSaver), new XAttribute("switchKeys", SwitchKeys),
            new XAttribute("lockKey", LockKey), new XAttribute("targets", Targets), new XElement("extra", Extra));
    }
    public static ShareAdvanced FromXml(XElement e)
    {
        var a = new ShareAdvanced(); if (e == null) return a;
        Func<string, int, int> number = (name, fallback) => { int v; return Int32.TryParse((string)e.Attribute(name), out v) ? v : fallback; };
        Func<string, bool, bool> flag = (name, fallback) => { bool v; return Boolean.TryParse((string)e.Attribute(name), out v) ? v : fallback; };
        a.SwitchDelay = Clamp(number("switchDelay", 0), 5000); a.DoubleTap = Clamp(number("doubleTap", 0), 2000); a.CornerSize = Clamp(number("cornerSize", 16), 500);
        a.Corners = flag("corners", false); a.SwapModifiers = flag("swapModifiers", true); a.RelativeMouse = flag("relativeMouse", false);
        a.ScreenSaver = flag("screenSaver", true); a.SwitchKeys = flag("switchKeys", true); a.LockKey = flag("lockKey", false);
        a.Targets = (string)e.Attribute("targets") ?? ""; a.Extra = (string)e.Element("extra") ?? "";
        return a;
    }
    // Extra lines go into the options section; section boundaries would break the generated file.
    public IEnumerable<string> ExtraLines()
    {
        foreach (string raw in (Extra ?? "").Replace("\r", "").Split('\n')) {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            if (line.StartsWith("section", StringComparison.OrdinalIgnoreCase) || line.Equals("end", StringComparison.OrdinalIgnoreCase)) throw new IOException("額外設定不可包含 section 或 end：" + line);
            yield return line;
        }
    }
    // Comma separated IPv4 addresses or computer names outside the local network.
    public string TargetList()
    {
        var items = (Targets ?? "").Split(new[] { ',', ' ', ';', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string item in items) if (item.Length > 253 || !Regex.IsMatch(item, "^[A-Za-z0-9.-]+$")) throw new IOException("請輸入 IPv4 位址或電腦名稱，以逗號分隔：" + item);
        if (items.Length > 16) throw new IOException("最多輸入 16 個位址。");
        return String.Join(",", items);
    }
}

// Talks to barrier-service.exe (installed version): the service runs the core with system rights so
// it also works on the sign-in screen, the lock screen and UAC prompts. The portable copy has no service.
static class ShareService
{
    public const string Pipe = "BarrierShare.Service";
    public static bool Installed { get { return File.Exists(Path.Combine(ShareSettings.Bin, "barrier-service.exe")); } }
    public static string[] Request(string line, int timeout = 1500)
    {
        using (var pipe = new System.IO.Pipes.NamedPipeClientStream(".", Pipe, System.IO.Pipes.PipeDirection.InOut)) {
            pipe.Connect(timeout); pipe.ReadMode = System.IO.Pipes.PipeTransmissionMode.Message;
            byte[] request = Encoding.UTF8.GetBytes(line); pipe.Write(request, 0, request.Length); pipe.Flush();
            var reply = new MemoryStream(); var buffer = new byte[4096];
            do { int read = pipe.Read(buffer, 0, buffer.Length); if (read == 0) break; reply.Write(buffer, 0, read); } while (!pipe.IsMessageComplete);
            string[] f = Encoding.UTF8.GetString(reply.ToArray()).Split('\t');
            if (f[0] != "OK" || f.Length != 3) throw new IOException("背景服務：" + (f.Length > 1 ? f[1] : f[0]));
            return f;
        }
    }
    static string File64(string path) { return File.Exists(path) ? Convert.ToBase64String(File.ReadAllBytes(path)) : ""; }
    // The pairing identity and settings travel as data; the service never opens the user's folders.
    public static string StartCommand(bool host, string address)
    {
        return String.Join("\t", new[] { "START", host ? "host" : "receiver", host ? "-" : address, File64(Path.Combine(ShareSettings.Profile(host), "SSL", "Barrier.pem")),
            File64(ShareSettings.TrustedPath(host)), host ? Convert.ToBase64String(new UTF8Encoding(false).GetBytes(ShareSettings.Config(true))) : "",
            host ? ShareSettings.HostName : ShareSettings.ReceiverName,
            // Used only by the core that runs as this user on the normal desktop.
            Path.GetFullPath(ShareSettings.Profile(host)) });
    }
}

// Launch at sign-in through the per-user Run key; the value follows the exe if the app is moved.
static class ShareLogin
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static string Name = "BarrierShare";
    public static string Command { get { return ShareSettings.Quote(Application.ExecutablePath) + " --background"; } }
    public static bool Enabled
    {
        get { using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey)) return key != null && key.GetValue(Name) != null; }
        set {
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey)) {
                if (value) key.SetValue(Name, Command); else key.DeleteValue(Name, false);
            }
        }
    }
    public static void Refresh() { try { if (Enabled && !Command.Equals(ReadValue())) Enabled = true; } catch (Exception) { } }
    public static string ReadValue() { using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey)) return key == null ? null : key.GetValue(Name) as string; }
}

// Turns "file clipboard: progress sent N bytes" log lines into a size and speed for the status card.
sealed class ShareProgress
{
    static readonly Regex Line = new Regex(@"file clipboard: progress (sent|received) (\d+) bytes");
    long lastBytes; DateTime lastTime; double speed;
    public void Reset() { lastBytes = 0; lastTime = DateTime.UtcNow; speed = 0; }
    public string Describe(string line, DateTime now)
    {
        var match = Line.Match(line);
        if (!match.Success) return null;
        long bytes = Int64.Parse(match.Groups[2].Value);
        double seconds = (now - lastTime).TotalSeconds;
        if (seconds > 0.05 && bytes >= lastBytes) { double current = (bytes - lastBytes) / seconds; speed = speed == 0 ? current : speed * 0.6 + current * 0.4; }
        lastBytes = bytes; lastTime = now;
        return (match.Groups[1].Value == "sent" ? "正在傳送檔案… 已傳 " : "正在接收檔案… 已收 ") + Size(bytes) + (speed > 0 ? " · " + Size((long)speed) + "/s" : "");
    }
    public static string Size(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" }; double value = bytes; int unit = 0;
        while (value >= 1024 && unit < units.Length - 1) { value /= 1024; ++unit; }
        return (unit == 0 ? value.ToString("0") : value.ToString(value < 10 ? "0.0" : "0")) + " " + units[unit];
    }
}

static class ShareCursor
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool SystemParametersInfo(uint action, uint param, IntPtr value, uint flags);
    // The host core hides the system cursors while another screen is active and normally
    // restores them itself; reload the user's cursor scheme if it was stopped abruptly.
    public static void Restore() { SystemParametersInfo(0x0057 /* SPI_SETCURSORS */, 0, IntPtr.Zero, 0); }
}

static class ShareStyle
{
    public static readonly Color Background = Color.FromArgb(244, 246, 250), Ink = Color.FromArgb(24, 37, 57), Muted = Color.FromArgb(88, 105, 129), Blue = Color.FromArgb(47, 101, 235);
    public static readonly Color Field = Color.FromArgb(247, 249, 253), Border = Color.FromArgb(219, 226, 237);
    public static readonly Color Tint = Color.FromArgb(232, 240, 253), BlueInk = Color.FromArgb(20, 70, 160), Green = Color.FromArgb(28, 128, 80), GreenTint = Color.FromArgb(226, 244, 233);
    public static readonly Color Faint = Color.FromArgb(128, 140, 158), Danger = Color.FromArgb(190, 55, 45);
    public static GraphicsPath Rounded(RectangleF r, float radius) {
        var path = new GraphicsPath(); float d = radius * 2;
        path.AddArc(r.X, r.Y, d, d, 180, 90); path.AddArc(r.Right-d, r.Y, d, d, 270, 90); path.AddArc(r.Right-d, r.Bottom-d, d, d, 0, 90); path.AddArc(r.X, r.Bottom-d, d, d, 90, 90); path.CloseFigure(); return path;
    }
}
sealed class ShareCard : Panel
{
    public ShareCard() { DoubleBuffered = true; BackColor = ShareStyle.Background; }
    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = ShareStyle.Rounded(new RectangleF(0.5F,0.5F,Width-1,Height-1),14 * e.Graphics.DpiX / 96F)) using (var fill = new SolidBrush(Color.White)) using (var border = new Pen(Color.FromArgb(228,233,242))) { e.Graphics.FillPath(fill,path); e.Graphics.DrawPath(border,path); }
    }
}
sealed class ShareButton : Button
{
    public bool Primary, Quiet;
    bool hover, pressed;
    public ShareButton() { FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand; SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer,true); }
    protected override void OnMouseEnter(EventArgs e) { hover=true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover=false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) pressed=true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { pressed=false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnMouseCaptureChanged(EventArgs e) { pressed=false; Invalidate(); base.OnMouseCaptureChanged(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space) pressed=true; Invalidate(); base.OnKeyDown(e); }
    protected override void OnKeyUp(KeyEventArgs e) { pressed=false; Invalidate(); base.OnKeyUp(e); }
    protected override void OnLostFocus(EventArgs e) { pressed=false; Invalidate(); base.OnLostFocus(e); }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.Clear(BackColor); e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
        float scale=e.Graphics.DpiX/96F;
        if (Quiet) {
            // Toolbar style: no frame until the pointer is over it.
            if (Enabled && (hover || pressed)) using (var path = ShareStyle.Rounded(new RectangleF(0.5F,0.5F,Width-1,Height-1),8*scale)) using (var brush = new SolidBrush(pressed ? Color.FromArgb(218,227,243) : Color.FromArgb(232,238,249))) e.Graphics.FillPath(brush,path);
            if (Focused && ShowFocusCues) using (var path=ShareStyle.Rounded(new RectangleF(2*scale,2*scale,Width-4*scale,Height-4*scale),6*scale)) using (var pen=new Pen(ShareStyle.Blue,scale)) e.Graphics.DrawPath(pen,path);
            TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,!Enabled ? Color.FromArgb(160,170,185) : hover ? ShareStyle.Ink : ShareStyle.Muted,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
            return;
        }
        var fill = !Enabled ? Color.FromArgb(239,242,247) : Primary ? (pressed ? Color.FromArgb(28,69,181) : hover ? Color.FromArgb(36,84,206) : ShareStyle.Blue) : (pressed ? Color.FromArgb(218,227,243) : hover ? Color.FromArgb(232,238,249) : Color.FromArgb(246,248,252));
        using (var path = ShareStyle.Rounded(new RectangleF(0.5F,0.5F,Width-1,Height-1),9*scale)) using (var brush = new SolidBrush(fill)) {
            e.Graphics.FillPath(brush,path);
            if (!Primary && Enabled) using (var pen=new Pen(ShareStyle.Border)) e.Graphics.DrawPath(pen,path);
        }
        if (Focused && ShowFocusCues) using (var path=ShareStyle.Rounded(new RectangleF(3*scale,3*scale,Width-6*scale,Height-6*scale),6*scale)) using (var pen=new Pen(Primary ? Color.White : ShareStyle.Blue,scale)) e.Graphics.DrawPath(pen,path);
        TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,!Enabled ? Color.FromArgb(133,145,163) : Primary ? Color.White : ShareStyle.Ink,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
    }
}
// Keep native keyboard navigation and accessibility while giving the whole field a visible surface.
sealed class ShareComboBox : ComboBox
{
    public ShareComboBox() {
        DropDownStyle=ComboBoxStyle.DropDownList; DrawMode=DrawMode.OwnerDrawFixed;
        FlatStyle=FlatStyle.Standard; BackColor=ShareStyle.Field; ForeColor=ShareStyle.Ink;
        IntegralHeight=false; MaxDropDownItems=8; UpdateItemHeight();
    }
    void UpdateItemHeight() { ItemHeight=(int)Math.Ceiling(Font.Height*1.8F); DropDownHeight=ItemHeight*5; }
    protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); UpdateItemHeight(); }
    protected override void OnDrawItem(DrawItemEventArgs e) {
        bool selected=(e.State & DrawItemState.Selected)!=0 && (e.State & DrawItemState.ComboBoxEdit)==0;
        Color background=selected ? ShareStyle.Blue : BackColor;
        using (var brush=new SolidBrush(background)) e.Graphics.FillRectangle(brush,e.Bounds);
        int inset=Math.Max(8,Font.Height/2);
        var textBounds=new Rectangle(e.Bounds.X+inset,e.Bounds.Y,Math.Max(1,e.Bounds.Width-2*inset),e.Bounds.Height);
        string text=e.Index>=0 ? GetItemText(Items[e.Index]) : Text;
        TextRenderer.DrawText(e.Graphics,text,Font,textBounds,!Enabled ? ShareStyle.Muted : selected ? Color.White : ForeColor,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
        e.DrawFocusRectangle();
    }
}
sealed class ComputerMark : Control
{
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.ScaleTransform(Width/52F,Height/52F);
        using (var path = ShareStyle.Rounded(new RectangleF(0,0,51,51),12)) using (var brush = new SolidBrush(Color.FromArgb(232,239,255))) e.Graphics.FillPath(brush,path);
        using (var pen = new Pen(ShareStyle.Blue,2)) { e.Graphics.DrawRectangle(pen,12,12,28,20); e.Graphics.DrawLine(pen,8,37,44,37); e.Graphics.DrawLine(pen,22,32,22,36); e.Graphics.DrawLine(pen,30,32,30,36); }
    }
}
sealed class NearbyDevice
{
    public string Fingerprint, Name, Address;
    public bool Offline; // a paired computer that discovery does not currently see
    public override string ToString() { return Name + "  ·  " + Address; }
}
// Two-choice switch (主控端／接收端) drawn as one segmented control; arrow keys move between choices.
sealed class ShareSegment : Control
{
    readonly string[] options; int selected;
    public event EventHandler Changed;
    public ShareSegment(params string[] choices) { options = choices; SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable, true); TabStop = true; Cursor = Cursors.Hand; }
    public int Selected { get { return selected; } set { if (value < 0 || value >= options.Length || value == selected) return; selected = value; Invalidate(); var h = Changed; if (h != null) h(this, EventArgs.Empty); } }
    Rectangle Part(int i) { int w = (Width - 6) / options.Length; return new Rectangle(3 + i * w, 3, w, Height - 6); }
    protected override void OnMouseDown(MouseEventArgs e) { Focus(); for (int i = 0; i < options.Length; ++i) if (Part(i).Contains(e.Location)) Selected = i; base.OnMouseDown(e); }
    protected override bool IsInputKey(Keys key) { return key == Keys.Left || key == Keys.Right || base.IsInputKey(key); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Left) Selected = selected - 1; if (e.KeyCode == Keys.Right) Selected = selected + 1; base.OnKeyDown(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override AccessibleObject CreateAccessibilityInstance() { return new SegmentAccessible(this); }
    sealed class SegmentAccessible : ControlAccessibleObject
    {
        readonly ShareSegment owner;
        public SegmentAccessible(ShareSegment segment) : base(segment) { owner = segment; }
        public override AccessibleRole Role { get { return AccessibleRole.ComboBox; } }
        public override string Value { get { return owner.options[owner.selected]; } set { } }
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(BackColor); g.SmoothingMode = SmoothingMode.AntiAlias; float s = g.DpiX / 96F;
        using (var path = ShareStyle.Rounded(new RectangleF(0.5F, 0.5F, Width - 1, Height - 1), 8 * s)) using (var fill = new SolidBrush(Color.FromArgb(232, 236, 243))) g.FillPath(fill, path);
        for (int i = 0; i < options.Length; ++i) {
            var r = Part(i);
            if (i == selected) using (var path = ShareStyle.Rounded(new RectangleF(r.X, r.Y, r.Width, r.Height), 6 * s)) using (var fill = new SolidBrush(Color.White)) using (var edge = new Pen(ShareStyle.Border)) { g.FillPath(fill, path); g.DrawPath(edge, path); }
            TextRenderer.DrawText(g, options[i], Font, r, i == selected ? ShareStyle.Ink : ShareStyle.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
        if (Focused && ShowFocusCues) using (var path = ShareStyle.Rounded(new RectangleF(1, 1, Width - 3, Height - 3), 8 * s)) using (var pen = new Pen(ShareStyle.Blue, s)) g.DrawPath(pen, path);
    }
}
// Small pill with a coloured dot: 已連線, 連線中, 已暫停 …
sealed class ShareBadge : Control
{
    Color ink = ShareStyle.Muted, fill = ShareStyle.Field;
    public ShareBadge() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
    public void Set(string text, Color foreground, Color background) { if (Text == text && ink == foreground) return; Text = text; ink = foreground; fill = background; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(BackColor); g.SmoothingMode = SmoothingMode.AntiAlias; float s = g.DpiX / 96F;
        var size = TextRenderer.MeasureText(g, Text, Font, Size.Empty, TextFormatFlags.NoPadding);
        float w = Math.Min(Width - 1, size.Width + 30 * s);
        using (var path = ShareStyle.Rounded(new RectangleF(0.5F, 0.5F, w, Height - 1), (Height - 1) / 2F)) using (var b = new SolidBrush(fill)) g.FillPath(b, path);
        using (var b = new SolidBrush(ink)) g.FillEllipse(b, 10 * s, Height / 2F - 3 * s, 6 * s, 6 * s);
        TextRenderer.DrawText(g, Text, Font, new Rectangle((int)(20 * s), 0, (int)(w - 20 * s), Height), ink, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);
    }
}
// Miniature of the screen arrangement on the connection card.
sealed class ShareScreenMap : Control
{
    public sealed class Tile { public Point Cell; public string Name; public bool Self, Placeholder; }
    public List<Tile> Tiles = new List<Tile>();
    public ShareScreenMap() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(BackColor); g.SmoothingMode = SmoothingMode.AntiAlias; float s = g.DpiX / 96F;
        using (var path = ShareStyle.Rounded(new RectangleF(0.5F, 0.5F, Width - 1, Height - 1), 10 * s)) using (var b = new SolidBrush(ShareStyle.Background)) g.FillPath(b, path);
        if (Tiles.Count == 0) return;
        int minX = Tiles.Min(t => t.Cell.X), maxX = Tiles.Max(t => t.Cell.X), minY = Tiles.Min(t => t.Cell.Y), maxY = Tiles.Max(t => t.Cell.Y);
        int cols = maxX - minX + 1, rows = maxY - minY + 1; float gap = 8 * s, label = 16 * s;
        float cw = Math.Min(76 * s, (Width - 16 * s - gap * (cols - 1)) / cols), ch = Math.Min(48 * s, (Height - 12 * s - (gap + label) * rows) / rows);
        cw = Math.Min(cw, ch * 1.6F); ch = Math.Min(ch, cw / 1.6F);
        float totalW = cols * cw + (cols - 1) * gap, totalH = rows * (ch + label) + (rows - 1) * gap;
        float x0 = (Width - totalW) / 2, y0 = (Height - totalH) / 2;
        foreach (var t in Tiles) {
            var r = new RectangleF(x0 + (t.Cell.X - minX) * (cw + gap), y0 + (t.Cell.Y - minY) * (ch + label + gap), cw, ch);
            using (var path = ShareStyle.Rounded(r, 5 * s))
            using (var fill = new SolidBrush(t.Self ? ShareStyle.Tint : Color.White))
            using (var edge = new Pen(t.Self ? ShareStyle.Blue : ShareStyle.Border, (t.Self ? 1.5F : 1F) * s) { DashStyle = t.Placeholder ? DashStyle.Dash : DashStyle.Solid }) {
                if (!t.Placeholder) g.FillPath(fill, path); g.DrawPath(edge, path);
            }
            if (t.Self) using (var pen = new Pen(ShareStyle.Blue, 1.5F * s)) {
                // A mouse outline marks the computer whose keyboard and mouse are used.
                float mx = r.X + r.Width / 2, my = r.Y + r.Height / 2;
                g.DrawEllipse(pen, mx - 5 * s, my - 8 * s, 10 * s, 16 * s); g.DrawLine(pen, mx, my - 8 * s, mx, my - 3 * s);
            }
            TextRenderer.DrawText(g, t.Name, Font, Rectangle.Round(new RectangleF(r.X - gap / 2, r.Bottom + 1, r.Width + gap, label)), t.Placeholder ? ShareStyle.Faint : ShareStyle.Muted, TextFormatFlags.HorizontalCenter | TextFormatFlags.Top | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }
}
sealed class ListHeader { public readonly string Text; public ListHeader(string text) { Text = text; } public override string ToString() { return Text; } }
// Nearby computers as rows: icon, name, system and address, and the pairing state or an invite button.
sealed class ShareDeviceList : ListBox
{
    public Func<NearbyDevice, int> State = d => 0;          // 0 available, 1 paired, 2 paired but offline
    public Func<NearbyDevice, string> System = d => "電腦";
    public Func<bool> CanInvite = () => false;
    public event Action<NearbyDevice> InviteRequested;
    float scale = 1;
    public ShareDeviceList() { DrawMode = DrawMode.OwnerDrawVariable; BorderStyle = BorderStyle.FixedSingle; IntegralHeight = false; BackColor = Color.White; }
    protected override void OnHandleCreated(EventArgs e) { using (var g = CreateGraphics()) scale = g.DpiX / 96F; base.OnHandleCreated(e); }
    protected override void OnMeasureItem(MeasureItemEventArgs e) { using (var g = CreateGraphics()) scale = g.DpiX / 96F; e.ItemHeight = (int)((e.Index >= 0 && Items[e.Index] is ListHeader ? 26 : 52) * scale); base.OnMeasureItem(e); }
    Rectangle InviteBounds(Rectangle row) { int w = (int)(92 * scale), h = (int)(28 * scale); return new Rectangle(row.Right - w - (int)(12 * scale), row.Y + (row.Height - h) / 2, w, h); }
    protected override void OnSelectedIndexChanged(EventArgs e)
    {
        // Headers are not selectable; move to the next computer.
        if (SelectedIndex >= 0 && Items[SelectedIndex] is ListHeader) { SelectedIndex = SelectedIndex + 1 < Items.Count ? SelectedIndex + 1 : -1; return; }
        Invalidate(); base.OnSelectedIndexChanged(e);
    }
    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        int index = IndexFromPoint(e.Location); if (index < 0) return;
        var device = Items[index] as NearbyDevice;
        if (device != null && State(device) == 0 && CanInvite() && InviteBounds(GetItemRectangle(index)).Contains(e.Location)) { var h = InviteRequested; if (h != null) h(device); }
    }
    protected override void OnDoubleClick(EventArgs e) { base.OnDoubleClick(e); var device = SelectedItem as NearbyDevice; if (device != null && State(device) == 0 && CanInvite()) { var h = InviteRequested; if (h != null) h(device); } }
    protected override void OnDrawItem(DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        var g = e.Graphics; var row = e.Bounds; g.SmoothingMode = SmoothingMode.AntiAlias; float s = scale;
        var header = Items[e.Index] as ListHeader;
        if (header != null) {
            using (var b = new SolidBrush(ShareStyle.Background)) g.FillRectangle(b, row);
            TextRenderer.DrawText(g, header.Text, new Font(Font.FontFamily, 8.5F), new Rectangle(row.X + (int)(14 * s), row.Y, row.Width, row.Height), ShareStyle.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            return;
        }
        var device = (NearbyDevice)Items[e.Index]; int state = State(device);
        bool selected = (e.State & DrawItemState.Selected) != 0;
        using (var b = new SolidBrush(selected ? Color.FromArgb(243, 247, 255) : Color.White)) g.FillRectangle(b, row);
        if (e.Index + 1 < Items.Count && !(Items[e.Index + 1] is ListHeader)) using (var pen = new Pen(Color.FromArgb(236, 240, 246))) g.DrawLine(pen, row.X + 14 * s, row.Bottom - 1, row.Right - 14 * s, row.Bottom - 1);
        Color ink = state == 2 ? ShareStyle.Faint : ShareStyle.Ink;
        // Screen icon: a Mac gets a thinner bezel and a stand, a Windows PC a laptop base.
        float ix = row.X + 16 * s, iy = row.Y + row.Height / 2F - 9 * s;
        using (var pen = new Pen(state == 2 ? ShareStyle.Faint : ShareStyle.Muted, 1.4F * s)) {
            g.DrawRectangle(pen, ix, iy, 22 * s, 14 * s);
            if (System(device) == "Mac") { g.DrawLine(pen, ix + 11 * s, iy + 14 * s, ix + 11 * s, iy + 18 * s); g.DrawLine(pen, ix + 6 * s, iy + 18 * s, ix + 16 * s, iy + 18 * s); }
            else g.DrawLine(pen, ix - 3 * s, iy + 17 * s, ix + 25 * s, iy + 17 * s);
        }
        int textX = row.X + (int)(52 * s), right = row.Right - (int)(120 * s);
        TextRenderer.DrawText(g, device.Name, Font, new Rectangle(textX, row.Y + (int)(8 * s), right - textX, (int)(20 * s)), ink, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        string detail = System(device) + (device.Address.Length > 0 ? " · " + device.Address : "");
        TextRenderer.DrawText(g, detail, new Font(Font.FontFamily, 8.5F), new Rectangle(textX, row.Y + (int)(28 * s), right - textX, (int)(18 * s)), ShareStyle.Faint, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        var action = InviteBounds(row);
        if (state == 1) TextRenderer.DrawText(g, "✓ 已配對", Font, action, ShareStyle.Green, TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        else if (state == 2) TextRenderer.DrawText(g, "已配對 · 離線", new Font(Font.FontFamily, 8.5F), action, ShareStyle.Faint, TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        else if (CanInvite()) {
            using (var path = ShareStyle.Rounded(action, 7 * s)) using (var b = new SolidBrush(ShareStyle.Blue)) g.FillPath(b, path);
            TextRenderer.DrawText(g, "邀請配對", new Font(Font.FontFamily, 9F), action, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
        }
    }
}
// Six-digit pairing code in two groups of three.
sealed class ShareCode : Control
{
    public ShareCode() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.Clear(BackColor); g.SmoothingMode = SmoothingMode.AntiAlias; float s = g.DpiX / 96F;
        string code = Text ?? ""; if (code.Length == 0) return;
        float gap = 6 * s, group = 14 * s, w = Math.Min(44 * s, (Width - gap * (code.Length - 1) - group) / code.Length), h = Height - 2;
        float total = code.Length * w + (code.Length - 1) * gap + (code.Length > 3 ? group : 0), x = (Width - total) / 2;
        using (var font = new Font("Consolas", 22F, FontStyle.Bold))
            for (int i = 0; i < code.Length; ++i) {
                if (i == 3) x += group;
                var r = new RectangleF(x, 1, w, h);
                using (var path = ShareStyle.Rounded(r, 8 * s)) using (var b = new SolidBrush(ShareStyle.Field)) using (var edge = new Pen(ShareStyle.Border)) { g.FillPath(b, path); g.DrawPath(edge, path); }
                TextRenderer.DrawText(g, code[i].ToString(), font, Rectangle.Round(r), ShareStyle.Blue, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
                x += w + gap;
            }
    }
}
sealed class ShareWindow : Form
{
    readonly ShareComboBox role = new ShareComboBox(), position = new ShareComboBox();
    readonly ShareDeviceList nearby = new ShareDeviceList();
    readonly Label positionHint = new Label(), status = new Label(), peerLabel = new Label(), emptyNearby = new Label(), roleLabel = new Label(), nearbyCount = new Label(), bannerText = new Label();
    readonly Panel body = new Panel(), banner = new Panel();
    readonly ShareSegment segment = new ShareSegment("主控端", "接收端");
    readonly ShareBadge badge = new ShareBadge();
    readonly ShareScreenMap map = new ShareScreenMap();
    readonly TextBox filter = new TextBox();
    readonly ShareButton cancelSend = new ShareButton(), bannerDownload = new ShareButton { Primary = true }, bannerClose = new ShareButton { Quiet = true };
    // dismissedUpdate: the version whose banner was closed; connections: core sessions currently up.
    string dismissedUpdate, nearbyShown; int connections; bool? invitable;
    readonly System.Windows.Forms.Timer updateTimer = new System.Windows.Forms.Timer { Interval = 6 * 60 * 60 * 1000 };
    string updateUrl, announcedUpdate;
    readonly TextBox address = new TextBox(), details = new TextBox();
    readonly ShareButton start = new ShareButton(), stop = new ShareButton(), search = new ShareButton(), pair = new ShareButton { Primary = true }, forget = new ShareButton(), clear = new ShareButton();
    readonly NotifyIcon tray = new NotifyIcon();
    readonly Dictionary<string, NearbyDevice> devices = new Dictionary<string, NearbyDevice>();
    readonly System.Windows.Forms.Timer retry = new System.Windows.Forms.Timer { Interval = 3000 };
    readonly bool testing;
    readonly List<ShareCard> cards = new List<ShareCard>();
    Process backend, link;
    // Set while the service runs the core; its log file is followed instead of the process output.
    // While the service runs the core: its log as the signed-in user (own profile), as SYSTEM
    // (service state folder) and the service's notes on which one runs; all three are followed.
    DateTime serviceSince;
    string serviceLog; readonly Dictionary<string, long> serviceOffsets = new Dictionary<string, long>();
    readonly System.Windows.Forms.Timer serviceTail = new System.Windows.Forms.Timer { Interval = 500 };
    Form consent, diagnostics;
    string consentId, connectedAddress = "";
    // Paired computers: every receiver for a host, the one host for a receiver (fingerprint -> name).
    readonly Dictionary<string, string> peers = new Dictionary<string, string>();
    readonly ShareButton arrange = new ShareButton();
    bool balloonOpensUpdate, manualUpdateCheck, closing, loading = true, enabled = true, discoveryReady, started, transferring, keepServiceCore;
    readonly CheckBox autostart = new CheckBox();
    readonly ShareProgress progress = new ShareProgress();
    ShareTransferPopup popup;
    readonly ShareAutoPaste autoPaste = new ShareAutoPaste();
    // Set by --background (sign-in launch): start in the notification area without showing the window.
    public bool StartHidden;
    bool Host { get { return role.SelectedIndex == 0; } }
    protected override void SetVisibleCore(bool value)
    {
        if (value && StartHidden && !IsHandleCreated) { StartHidden = false; CreateHandle(); base.SetVisibleCore(false); BeginInvoke((Action)Startup); return; }
        base.SetVisibleCore(value);
    }
    // Lets the installer close a running copy cleanly so cursors and both helpers are restored.
    public void Quit() { if (IsHandleCreated) BeginInvoke((Action)delegate { closing = true; Close(); }); }
    void At(Control c, int x, int y, int width, int height)
    {
        var bounds = new Rectangle(x,y,width,height);
        if (!(c is ShareCard)) foreach (var card in cards) if (card.Bounds.Contains(bounds)) {
            c.SetBounds(x-card.Left,y-card.Top,width,height); card.Controls.Add(c); c.BringToFront(); return;
        }
        c.Bounds=bounds; body.Controls.Add(c); c.BringToFront();
        if (c is ShareCard) { c.TabIndex=cards.Count; cards.Add((ShareCard)c); }
    }
    void LabelAt(string text, int x, int y, int width) { At(new Label { Text = text }, x, y, width, 26); }
    public ShareWindow(bool selfTest = false)
    {
        SuspendLayout();
        testing = selfTest; Text = "Barrier Share " + ShareUpdate.Label;
        Font = new Font("Microsoft JhengHei UI", 11F); AutoScaleDimensions=new SizeF(96F,96F); AutoScaleMode=AutoScaleMode.Dpi;
        ClientSize = new Size(720, 608); BackColor = ShareStyle.Background; ForeColor = ShareStyle.Ink;
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen; Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        // An update banner sits above everything; the window grows by its height while it shows.
        banner.Dock = DockStyle.Top; banner.Height = 44; banner.BackColor = ShareStyle.Tint; banner.Visible = false;
        bannerText.ForeColor = ShareStyle.BlueInk; bannerText.TextAlign = ContentAlignment.MiddleLeft; bannerText.Font = new Font(Font.FontFamily,10F); bannerText.AutoEllipsis = true; bannerText.Bounds = new Rectangle(24,0,500,44);
        bannerDownload.Text = "下載更新"; bannerDownload.BackColor = ShareStyle.Tint; bannerDownload.Font = new Font(Font.FontFamily,10F); bannerDownload.Bounds = new Rectangle(560,7,104,30);
        bannerClose.Text = "✕"; bannerClose.BackColor = ShareStyle.Tint; bannerClose.Bounds = new Rectangle(668,7,30,30); bannerClose.AccessibleName = "稍後再說";
        banner.Controls.AddRange(new Control[] { bannerText, bannerDownload, bannerClose });
        bannerDownload.Click += delegate { OpenUpdate(); };
        bannerClose.Click += delegate { dismissedUpdate = announcedUpdate; SetBanner(false); };
        body.Dock = DockStyle.Fill; body.BackColor = ShareStyle.Background; body.AutoScroll = true; body.AutoScrollMinSize = new Size(720, 608);
        Controls.Add(body); Controls.Add(banner);
        // Header: this computer and its role.
        At(new ComputerMark { BackColor = ShareStyle.Background },24,20,44,44);
        At(new Label { Text = Environment.MachineName, Font = new Font(Font.FontFamily,15F,FontStyle.Bold), AutoEllipsis = true },80,16,420,30);
        roleLabel.ForeColor = ShareStyle.Muted; roleLabel.Font = new Font(Font.FontFamily,10F); At(roleLabel,80,46,420,22);
        segment.AccessibleName = "這台電腦的角色"; segment.Font = new Font(Font.FontFamily,10F); segment.TabIndex = 0; At(segment,520,26,176,34);
        role.Visible = false; role.AccessibleName = "這台電腦的角色"; At(role,0,0,10,10);
        role.Items.AddRange(new object[] { "主控端 · 使用這台的鍵盤滑鼠", "接收端 · 等待主控端邀請" });
        segment.Changed += delegate { if (role.SelectedIndex != segment.Selected) role.SelectedIndex = segment.Selected; };
        role.SelectedIndexChanged += delegate { segment.Selected = role.SelectedIndex; roleLabel.Text = role.SelectedIndex == 0 ? "主控端 · 使用這台的鍵盤滑鼠" : "接收端 · 由主控端操作"; };
        // Connection card: state, what to do next, and a small map of the screens.
        At(new ShareCard(),24,84,672,168);
        badge.BackColor = Color.White; At(badge,44,102,120,24);
        status.BackColor = Color.White; status.ForeColor = ShareStyle.Ink; status.Font = new Font(Font.FontFamily,13F,FontStyle.Bold); status.AutoEllipsis = true; At(status,44,130,412,50);
        peerLabel.BackColor = Color.White; peerLabel.ForeColor = ShareStyle.Muted; peerLabel.AutoEllipsis = true; peerLabel.Font = new Font(Font.FontFamily,10F); At(peerLabel,44,180,412,24);
        foreach (var b in new[] { stop, start, arrange, cancelSend }) { b.BackColor = Color.White; b.Font = new Font(Font.FontFamily,10F); }
        stop.Text = "暫停共用"; start.Text = "繼續共用"; arrange.Text = "排列螢幕"; cancelSend.Text = "取消傳送";
        At(stop,44,208,112,32); At(start,44,208,112,32); At(arrange,166,208,112,32); At(cancelSend,288,208,112,32);
        stop.TabIndex = 0; start.TabIndex = 1; arrange.TabIndex = 2; cancelSend.TabIndex = 3; cancelSend.Visible = false;
        arrange.Click += delegate { ShowLayout(); }; cancelSend.Click += delegate { if (transferring) CancelTransfer(); };
        map.BackColor = Color.White; map.Font = new Font(Font.FontFamily,8.5F); At(map,472,100,204,132);
        // Nearby computers: paired ones first, a search box once the list gets long.
        At(new Label { Text = "附近電腦", Font = new Font(Font.FontFamily,11F,FontStyle.Bold) },24,270,100,28);
        nearbyCount.ForeColor = ShareStyle.Muted; nearbyCount.Font = new Font(Font.FontFamily,10F); At(nearbyCount,124,272,120,24);
        filter.AccessibleName = "搜尋名稱或 IP"; filter.Font = new Font(Font.FontFamily,10F); filter.Visible = false; At(filter,352,270,234,28);
        filter.HandleCreated += delegate { SendMessage(filter.Handle, 0x1501 /* EM_SETCUEBANNER */, new IntPtr(1), "搜尋名稱或 IP"); };
        filter.TextChanged += delegate { RebuildNearby(); };
        search.Text = "重新搜尋"; search.Quiet = true; search.BackColor = ShareStyle.Background; search.Font = new Font(Font.FontFamily,10F); At(search,596,268,100,32); search.TabIndex = 1;
        nearby.AccessibleName = "附近的電腦"; nearby.Font = new Font(Font.FontFamily,10F); nearby.TabIndex = 2; At(nearby,24,306,672,236);
        nearby.State = d => d.Offline ? 2 : peers.ContainsKey(d.Fingerprint) ? 1 : 0;
        nearby.System = d => { string system; return ShareSettings.Platforms.TryGetValue(d.Fingerprint, out system) ? (system == "mac" ? "Mac" : "Windows") : "電腦"; };
        nearby.CanInvite = () => Host && link != null && consent == null;
        nearby.InviteRequested += device => { nearby.SelectedItem = device; DoPair(); };
        emptyNearby.BackColor = Color.White; emptyNearby.ForeColor = ShareStyle.Muted; emptyNearby.TextAlign = ContentAlignment.MiddleCenter; emptyNearby.BorderStyle = BorderStyle.FixedSingle; At(emptyNearby,24,306,672,236);
        // Footer: everyday switches; the rarely used actions sit under 更多.
        At(new Panel { BackColor = ShareStyle.Border },0,556,720,1);
        autostart.Text = "登入時自動啟動"; autostart.BackColor = ShareStyle.Background; autostart.Font = new Font(Font.FontFamily,10F); autostart.TabIndex = 5; At(autostart,24,568,200,28);
        try { autostart.Checked = !selfTest && ShareLogin.Enabled; } catch (Exception) { }
        autostart.CheckedChanged += delegate { if (!testing) try { ShareLogin.Enabled = autostart.Checked; } catch (Exception e) { Error(e); } };
        var advancedButton = new ShareButton { Text = "進階設定", Quiet = true, BackColor = ShareStyle.Background, Font = new Font(Font.FontFamily,10F), TabIndex = 6 }; At(advancedButton,412,566,96,32); advancedButton.Click += delegate { ShowAdvanced(); };
        var diagnosticButton = new ShareButton { Text = "診斷紀錄", Quiet = true, BackColor = ShareStyle.Background, Font = new Font(Font.FontFamily,10F), TabIndex = 7 }; At(diagnosticButton,512,566,96,32); diagnosticButton.Click += delegate { ShowDiagnostics(); };
        var more = new ShareButton { Text = "更多  ▾", Quiet = true, BackColor = ShareStyle.Background, Font = new Font(Font.FontFamily,10F), TabIndex = 8 }; At(more,612,566,84,32);
        more.Click += delegate { BuildMoreMenu().Show(more, new Point(more.Width - 1, more.Height), ToolStripDropDownDirection.BelowLeft); };
        forget.Text = "解除配對"; clear.Text = "清除暫存"; pair.Text = "邀請配對";
        details.Multiline=true; details.ReadOnly=true; details.ScrollBars=ScrollBars.Vertical; details.Font=new Font("Consolas",9F); details.BackColor=Color.FromArgb(249,251,255); details.BorderStyle=BorderStyle.None;
        // A multiline TextBox has no Ctrl+A of its own.
        details.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.Control && e.KeyCode == Keys.A) { details.SelectAll(); e.SuppressKeyPress = true; } };
        // Tray menu: status and the everyday actions without opening the window.
        var menu = new ContextMenuStrip();
        var trayStatus = new ToolStripMenuItem { Enabled = false };
        var trayPause = new ToolStripMenuItem();
        var trayLogin = new ToolStripMenuItem("登入時自動啟動") { CheckOnClick = false };
        var trayArrange = new ToolStripMenuItem("排列螢幕…", null, delegate { ShowWindow(); ShowLayout(); });
        menu.Items.Add(trayStatus); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("開啟視窗", null, delegate { ShowWindow(); });
        menu.Items.Add(trayPause); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(trayArrange);
        menu.Items.Add("進階設定…", null, delegate { ShowWindow(); ShowAdvanced(); });
        menu.Items.Add(trayLogin); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("診斷紀錄", null, delegate { ShowWindow(); ShowDiagnostics(); });
        menu.Items.Add("檢查更新", null, delegate { manualUpdateCheck = true; CheckUpdate(); });
        menu.Items.Add(new ToolStripSeparator());
        trayPause.Click += delegate { if (enabled) stop.PerformClick(); else start.PerformClick(); };
        trayLogin.Click += delegate { autostart.Checked = !autostart.Checked; };
        menu.Opening += delegate {
            string text = status.Text; trayStatus.Text = text.Length > 40 ? text.Substring(0, 40) + "…" : text;
            trayPause.Text = enabled ? "暫停共用" : "繼續共用"; trayLogin.Checked = autostart.Checked;
            trayArrange.Visible = Host; trayArrange.Enabled = peers.Count > 0;
        };
        menu.Items.Add("結束", null, delegate { closing = true; Close(); }); tray.Icon = Icon; tray.Text = "Barrier Share " + ShareUpdate.Label; tray.ContextMenuStrip = menu; tray.Visible = !testing;
        tray.DoubleClick += delegate { ShowWindow(); };
        tray.BalloonTipClicked += delegate { if (balloonOpensUpdate) OpenUpdate(); };
        start.Click += delegate {
            // While a file is moving the same button cancels it: restarting the connection drops the partial copy on both sides.
            if (transferring) { CancelTransfer(); return; }
            enabled = true; StartLink(); UpdateControls();
        };
        popup = new ShareTransferPopup(Font); popup.CancelRequested += delegate { if (transferring) CancelTransfer(); else popup.Dismiss(); };
        // The popup appears only once a paste is pressed while files are still arriving.
        autoPaste.Requested += delegate { popup.ShowForPaste(); status.Text = "正在接收檔案… 傳完會自動貼上"; };
        autoPaste.Note += Diagnose;
        stop.Click += delegate { enabled = false; StopLink(); StopBackend(); status.Text = "已暫停；不接受邀請，也不會自動重連。"; UpdateControls(); };
        search.Click += delegate { Send("SEARCH"); status.Text = "正在搜尋同一區網的電腦…"; };
        pair.Click += delegate { DoPair(); };
        clear.Click += delegate { ClearCache(); };
        role.SelectedIndexChanged += delegate { if (!loading) { try { StopLink(); StopBackend(); RefreshRole(); if (enabled) StartLink(); } catch (Exception e) { Error(e); } } };
        position.SelectedIndexChanged += delegate {
            if (loading || position.SelectedIndex < 0) return;
            // The simple choice places the only receiver; a custom arrangement of it is dropped.
            ShareSettings.Position = ShareSettings.Directions[position.SelectedIndex]; foreach (string fp in peers.Keys) ShareSettings.Layout.Remove(fp);
            Save(); if (backend != null) StopBackend();
        };
        nearby.SelectedIndexChanged += delegate { UpdateControls(); };
        retry.Tick += delegate { if (enabled && link == null && !testing && !closing) StartLink(); };
        updateTimer.Tick += delegate { CheckUpdate(); };
        serviceTail.Tick += delegate { FollowServiceLog(); };
        ResumeLayout(false);
        Shown += delegate {
            var available=Screen.FromControl(this).WorkingArea;
            if (Width>available.Width || Height>available.Height) { Size=new Size(Math.Min(Width,available.Width),Math.Min(Height,available.Height)); Location=available.Location; }
            Startup();
        };
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            // On sign-out or shutdown the service keeps the core running for the sign-in screen.
            if (e.CloseReason == CloseReason.WindowsShutDown) { closing = true; keepServiceCore = true; }
            if (!closing && !testing) { e.Cancel = true; Hide(); Balloon(1500, "Barrier Share", "程式已收至系統匣；可從圖示開啟或結束。", ToolTipIcon.Info); return; }
            closing = true; retry.Stop(); updateTimer.Stop(); StopLink(); StopBackend(); autoPaste.Dispose(); popup.Dismiss(); popup.Dispose(); tray.Dispose();
        };
    }
    // Runs once, on first show or right away for a hidden sign-in launch.
    void Startup()
    {
        if (started) return; started = true; Diagnose(ShareUpdate.Details);
        Diagnose("權限：" + ShareElevation.Describe());
        if (!testing) { ShareCursor.Restore(); ShareLogin.Refresh(); }
        try {
            ShareSettings.Import(ShareSettings.Bin, true, false); ShareSettings.Import(ShareSettings.Bin, false, false);
            bool host; string ip; ShareSettings.Load(out host, out ip); role.SelectedIndex = host ? 0 : 1; address.Text = ip;
            loading = false; RefreshRole(); if (!testing) { StartLink(); retry.Start(); CheckUpdate(); updateTimer.Start(); }
        } catch (Exception e) { loading = false; Error(e); }
    }
    // Exercise the same window and startup path as a normal launch, including both live roles.
    public void CheckProductionStartup(string directory)
    {
        var timer = new System.Windows.Forms.Timer { Interval = 150 };
        var deadline = DateTime.UtcNow.AddSeconds(25); Task probe = null; bool receiverChecked = false;
        Directory.CreateDirectory(directory);
        timer.Tick += delegate {
            try {
                if (testing) throw new Exception("Production window started in interface-test mode");
                if (DateTime.UtcNow > deadline) throw new Exception("Production discovery did not start: " + status.Text);
                if (probe == null && discoveryReady && link != null && !link.HasExited) {
                    string expectedRole = Host ? "H" : "R";
                    probe = Task.Factory.StartNew(delegate {
                        using (var udp = new UdpClient(AddressFamily.InterNetwork)) {
                            udp.Client.ReceiveTimeout = 3000;
                            string nonce = Guid.NewGuid().ToString("N"); byte[] query = Encoding.ASCII.GetBytes("BSEARCH1\t" + nonce);
                            udp.Send(query, query.Length, new IPEndPoint(IPAddress.Loopback, 24801));
                            var sender = new IPEndPoint(IPAddress.Any, 0);
                            string[] reply = Encoding.UTF8.GetString(udp.Receive(ref sender)).Split('\t');
                            if (reply.Length != 5 || reply[0] != "BHERE1" || reply[1] != expectedRole || reply[4] != nonce || sender.Port != 24801)
                                throw new Exception("Production discovery response invalid");
                        }
                    });
                }
                if (probe != null && probe.IsCompleted) {
                    probe.GetAwaiter().GetResult();
                    if (!receiverChecked) { receiverChecked = true; probe = null; role.SelectedIndex = 1; return; }
                    using (var bitmap = new Bitmap(Width, Height)) { DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size)); bitmap.Save(Path.Combine(directory, "gui-startup.png")); }
                    using (var bitmap = Icon.ToBitmap()) bitmap.Save(Path.Combine(directory, "app-icon.png"));
                    File.WriteAllText(Path.Combine(directory, "STARTUP-PASS.txt"), "Normal GUI starts discovery on UDP/TCP 24801; host and receiver both answer nonce queries; role switching restarts service; app icon loads.");
                    timer.Stop(); closing = true; Close();
                }
            } catch (Exception e) {
                File.WriteAllText(Path.Combine(directory, "STARTUP-FAIL.txt"), e.ToString());
                Environment.ExitCode = 1; timer.Stop(); closing = true; Close();
            }
        };
        FormClosed += delegate { timer.Dispose(); };
        Shown += delegate { timer.Start(); };
    }
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, string lParam);
    NearbyDevice SelectedDevice { get { return nearby.SelectedItem as NearbyDevice; } }
    void DoPair()
    {
        var peer = SelectedDevice;
        if (peer == null || peer.Offline || peers.ContainsKey(peer.Fingerprint) || !Host || link == null || consent != null) return;
        StopBackend(); Send("PAIR\t" + peer.Fingerprint); status.Text = "正在發出邀請…";
    }
    // Paired computers first (offline ones greyed), then the others by name, filtered by the search box.
    void RebuildNearby()
    {
        string keep = SelectedDevice != null ? SelectedDevice.Fingerprint : null, query = filter.Text.Trim().ToLowerInvariant();
        Func<NearbyDevice, bool> match = d => query.Length == 0 || d.Name.ToLowerInvariant().Contains(query) || d.Address.Contains(query);
        var paired = peers.Select(p => { NearbyDevice d; return devices.TryGetValue(p.Key, out d) ? d : new NearbyDevice { Fingerprint = p.Key, Name = p.Value, Address = "", Offline = true }; }).Where(match).ToList();
        var others = devices.Values.Where(d => !peers.ContainsKey(d.Fingerprint)).Where(match).OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        // Discovery repeats every few seconds; redraw only when something shown has changed.
        string shown = String.Join("\n", paired.Concat(others).Select(d => (d.Offline ? "-" : peers.ContainsKey(d.Fingerprint) ? "+" : " ") + d.Fingerprint + "\t" + d.Name + "\t" + d.Address + "\t" + nearby.System(d)));
        if (shown == nearbyShown && nearby.Items.Count > 0 == paired.Count + others.Count > 0) { UpdateControls(); return; }
        nearbyShown = shown;
        int top = nearby.TopIndex; nearby.BeginUpdate(); nearby.Items.Clear();
        if (paired.Count > 0) { nearby.Items.Add(new ListHeader("已配對")); foreach (var d in paired) nearby.Items.Add(d); }
        if (others.Count > 0) { if (paired.Count > 0) nearby.Items.Add(new ListHeader("其他電腦")); foreach (var d in others) nearby.Items.Add(d); }
        var all = nearby.Items.OfType<NearbyDevice>().ToList();
        var chosen = all.FirstOrDefault(d => d.Fingerprint == keep) ?? all.FirstOrDefault(d => !d.Offline && !peers.ContainsKey(d.Fingerprint)) ?? all.FirstOrDefault();
        if (chosen != null) nearby.SelectedItem = chosen;
        if (nearby.Items.Count > 0) nearby.TopIndex = Math.Min(top, nearby.Items.Count - 1);
        nearby.EndUpdate(); UpdateControls();
    }
    internal int DeviceCount { get { return nearby.Items.OfType<NearbyDevice>().Count(d => !d.Offline); } }
    ContextMenuStrip BuildMoreMenu()
    {
        var menu = new ContextMenuStrip { Font = new Font(Font.FontFamily, 10F) };
        menu.Items.Add("清除暫存檔案", null, delegate { ClearCache(); }).Enabled = clear.Enabled;
        menu.Items.Add("關於 Barrier Share", null, delegate { MessageBox.Show(this, "Barrier Share\r\n" + ShareUpdate.Details + "\r\n\r\n以 Barrier 為基礎，在區域網路共用鍵盤、滑鼠與剪貼簿。", "關於 Barrier Share"); });
        menu.Items.Add(new ToolStripSeparator());
        var unpair = new ToolStripMenuItem("解除配對…") { ForeColor = ShareStyle.Danger, Enabled = forget.Enabled };
        if (peers.Count > 1) {
            foreach (var peer in peers.ToList()) { string fp = peer.Key; unpair.DropDownItems.Add("解除「" + peer.Value + "」", null, delegate { Forget("FORGET\t" + fp, "解除與「" + peers[fp] + "」的配對？"); }); }
            unpair.DropDownItems.Add(new ToolStripSeparator());
            unpair.DropDownItems.Add(new ToolStripMenuItem("全部解除", null, delegate { Forget("FORGET", "解除所有配對？"); }) { ForeColor = ShareStyle.Danger });
        } else unpair.Click += delegate { Forget("FORGET", "解除後不會自動連線，需要重新邀請並經對方同意。"); };
        menu.Items.Add(unpair);
        menu.Closed += delegate { BeginInvoke((Action)menu.Dispose); };
        return menu;
    }
    void OpenUpdate() { if (updateUrl != null) try { Process.Start(new ProcessStartInfo(updateUrl) { UseShellExecute = true }); } catch (Exception e) { Error(e); } }
    void SetBanner(bool show)
    {
        if (banner.Visible == show) return;
        int height = banner.Height; banner.Visible = show;
        ClientSize = new Size(ClientSize.Width, ClientSize.Height + (show ? height : -height));
    }
    // The connection card's badge and screen map follow the role, pairing and connection.
    void UpdateCard()
    {
        if (!enabled) badge.Set("已暫停", ShareStyle.Muted, ShareStyle.Field);
        else if (connections > 0) badge.Set("已連線", ShareStyle.Green, ShareStyle.GreenTint);
        else if (peers.Count > 0) badge.Set("連線中", ShareStyle.Blue, ShareStyle.Tint);
        else badge.Set(Host ? "尚未配對" : "等待邀請", ShareStyle.Muted, ShareStyle.Field);
        var tiles = new List<ShareScreenMap.Tile> { new ShareScreenMap.Tile { Cell = Point.Empty, Name = "這台", Self = true } };
        if (Host) {
            foreach (var cell in ShareSettings.Cells()) {
                string fp = peers.Keys.FirstOrDefault(k => ShareSettings.ScreenName(k) == cell.Key);
                if (fp != null) tiles.Add(new ShareScreenMap.Tile { Cell = cell.Value, Name = peers[fp] });
            }
            if (peers.Count == 0) tiles.Add(new ShareScreenMap.Tile { Cell = ShareSettings.Step(ShareSettings.Position), Name = "接收端", Placeholder = true });
        } else tiles.Add(new ShareScreenMap.Tile { Cell = new Point(-1, 0), Name = peers.Count > 0 ? peers.Values.First() : "主控端", Placeholder = peers.Count == 0 });
        map.Tiles = tiles; map.Invalidate();
    }
    void Balloon(int timeout, string title, string text, ToolTipIcon icon) { balloonOpensUpdate = false; tray.ShowBalloonTip(timeout, title, text, icon); }
    void ShowWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    void Error(Exception e) { status.Text = "操作未完成：" + e.Message; }
    // Offline or rate-limited checks stay silent; the local network connection never depends on them.
    void CheckUpdate()
    {
        Task.Factory.StartNew(() => ShareUpdate.Check()).ContinueWith(task => {
            if (closing || !IsHandleCreated) return;
            try { BeginInvoke((Action)delegate { bool manual = manualUpdateCheck; manualUpdateCheck = false;
                if (task.Status == TaskStatus.RanToCompletion) { if (manual) announcedUpdate = null; ShowUpdate(task.Result); if (manual && task.Result == null) Balloon(3000, "Barrier Share", "已是最新版本（" + ShareUpdate.Label + "）。", ToolTipIcon.Info); }
                else { LogLine("檢查更新失敗：" + task.Exception.GetBaseException().Message); if (manual) Balloon(3000, "Barrier Share", "無法檢查更新，請確認網路連線。", ToolTipIcon.Warning); } }); }
            catch (InvalidOperationException) { }
        });
    }
    internal void ShowUpdate(ShareUpdate.Found found)
    {
        if (found == null) { SetBanner(false); return; }
        updateUrl = found.Url; string version = found.Version.ToString();
        bannerText.Text = "有新版 " + version + " · 安裝時會自動關閉並重新開啟 Barrier Share";
        SetBanner(dismissedUpdate != version);
        if (announcedUpdate != version && !testing) {
            announcedUpdate = version;
            tray.ShowBalloonTip(5000, "Barrier Share 有新版 " + version, "點這裡下載更新，安裝時會自動重新開啟。", ToolTipIcon.Info); balloonOpensUpdate = true;
        }
    }
    void Save() { try { ShareSettings.Save(Host, address.Text.Trim()); } catch (Exception e) { Error(e); } }
    void UpdateControls()
    {
        transferring &= backend != null;
        bool linkDown = enabled && link == null;
        stop.Visible = enabled && !linkDown; start.Visible = !stop.Visible; start.Text = enabled ? "恢復連線" : "繼續共用";
        start.Enabled = !enabled || link == null; stop.Enabled = enabled; cancelSend.Visible = transferring;
        arrange.Visible = Host; arrange.Enabled = peers.Count > 0;
        status.ForeColor = enabled ? ShareStyle.Ink : ShareStyle.Muted;
        emptyNearby.Text = filter.TextLength > 0 && devices.Count > 0 ? "找不到符合的電腦" : !enabled ? "搜尋已暫停\r\n繼續共用後，會重新尋找附近電腦。" : Host ? "正在尋找接收端…\r\n請在另一台選擇「接收端」，保持程式開啟。" : "尚未找到主控端。\r\n請在另一台選擇「主控端」，發出配對邀請。";
        nearby.Visible = nearby.Items.Count > 0; emptyNearby.Visible = !nearby.Visible;
        nearbyCount.Text = devices.Count > 0 ? devices.Count + " 台" : "";
        filter.Visible = devices.Count > 6 || filter.TextLength > 0;
        var selected = SelectedDevice;
        search.Enabled = link != null; pair.Enabled = Host && link != null && selected != null && !selected.Offline && !peers.ContainsKey(selected.Fingerprint) && consent == null;
        forget.Enabled = link != null && peers.Count != 0; clear.Enabled = !enabled && backend == null;
        bool canInvite = nearby.CanInvite(); if (invitable != canInvite) { invitable = canInvite; nearby.Invalidate(); }
        UpdateCard();
    }
    void RefreshRole()
    {
        peers.Clear(); devices.Clear(); PeersChanged(); Save();
        ShareSettings.Init(Host);
        status.Text = enabled ? "正在啟用區網搜尋…" : "已暫停"; UpdateControls();
    }
    void StartLink()
    {
        if (link != null || testing || closing || !enabled) return;
        try {
            ShareSettings.Init(Host);
            var info = ShareSettings.Command("barrier-link.exe", ShareSettings.Profile(Host), Host ? "host" : "receiver", Environment.MachineName);
            info.RedirectStandardInput = true;
            var process = new Process { StartInfo = info, EnableRaisingEvents = true }; link = process;
            process.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { Post(process, e.Data, true); };
            process.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { Post(process, e.Data, false); };
            process.Exited += delegate { if (!closing && IsHandleCreated) BeginInvoke((Action)delegate { if (link == process) { StopLink(); status.Text = "搜尋服務已停止，正在重試…"; } }); };
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine(); UpdateControls();
        } catch (Exception e) { StopLink(); Error(e); }
    }
    void Send(string command) { try { if (link != null && !link.HasExited) { link.StandardInput.WriteLine(command); link.StandardInput.Flush(); } } catch (Exception e) { Error(e); } }
    void StopLink()
    {
        CloseConsent(); var process = link; link = null; discoveryReady = false;
        if (process != null) {
            try { if (!process.HasExited) { process.StandardInput.WriteLine("QUIT"); process.StandardInput.Flush(); if (!process.WaitForExit(2000)) process.Kill(); } } catch (InvalidOperationException) { } catch (IOException) { }
            process.Dispose();
        }
        devices.Clear(); RebuildNearby();
    }
    static string Decode(string value) { return Encoding.UTF8.GetString(Convert.FromBase64String(value)); }
    void Post(Process process, string line, bool protocol)
    {
        if (String.IsNullOrEmpty(line) || closing || !IsHandleCreated) return;
        try { BeginInvoke((Action)delegate {
            if (process == link && protocol) { try { LinkLine(line); } catch (Exception e) { Error(e); } }
            else if (process == backend || process == link) LogLine(line);
        }); } catch (InvalidOperationException) { }
    }
    void LinkLine(string line)
    {
        string[] f = line.Split('\t');
        if (f[0] == "READY") { LogLine("區網搜尋已啟動 · UDP/TCP 24801"); discoveryReady = true; if (f.Length == 2) ShareSettings.OwnFingerprint = f[1]; SendTargets(); status.Text = Host ? "正在搜尋接收端…" : "可被搜尋，等待主控端邀請…"; }
        else if (f[0] == "DEVICE" && f.Length == 6) {
            NearbyDevice device;
            if (!devices.TryGetValue(f[1], out device)) { device = new NearbyDevice { Fingerprint = f[1] }; devices[f[1]] = device; }
            device.Name = Decode(f[2]); device.Address = f[3]; RebuildNearby();
        } else if (f[0] == "PLATFORM" && f.Length == 3) {
            // A receiver's system decides the key mapping; restart the host core when it changes.
            string known;
            if (!ShareSettings.Platforms.TryGetValue(f[1], out known) || known != f[2]) {
                ShareSettings.Platforms[f[1]] = f[2]; Save(); LogLine("對方系統：" + f[2] + " · " + f[1].Substring(10, 16));
                if (Host && peers.ContainsKey(f[1]) && backend != null) StopBackend();
            }
        } else if (f[0] == "GONE" && f.Length == 2) { if (devices.Remove(f[1])) RebuildNearby(); }
        else if ((f[0] == "SAVED" || f[0] == "PAIRED") && f.Length == 3) {
            // A receiver has one host; a host's new receiver needs the core restarted with the new screen list.
            if (f[0] == "PAIRED") { StopBackend(); if (!Host) peers.Clear(); }
            peers[f[1]] = Decode(f[2]); PeersChanged();
        }
        else if ((f[0] == "VERIFY" || f[0] == "REQUEST") && f.Length == 5) ShowConsent(f);
        else if (f[0] == "CLOSED" && f.Length == 2 && f[1] == consentId) CloseConsent();
        else if (f[0] == "CONNECT" && f.Length == 4) {
            if (peers.ContainsKey(f[1]) && (backend == null || (!Host && connectedAddress != f[3]))) { StopBackend(); address.Text = f[3]; Save(); StartBackend(); }
        } else if (f[0] == "REMOVED") {
            StopBackend(); if (f.Length == 2) { peers.Remove(f[1]); ShareSettings.Layout.Remove(f[1]); } else peers.Clear();
            PeersChanged(); if (peers.Count == 0) peerLabel.Text = "已解除配對。"; Save();
            status.Text = peers.Count > 0 ? "已解除一台；其餘的會自動重新連線。" : Host ? "可以選擇接收端重新邀請。" : "等待新的配對邀請。";
        }
        else if (f[0] == "UNAVAILABLE" && f.Length == 3 && backend == null) { status.Text = "正在重新尋找並驗證已配對的電腦…"; LogLine(Decode(f[2])); }
        else if ((f[0] == "ERROR" || f[0] == "FATAL") && f.Length == 2) { if (f[0] == "FATAL") StopLink(); status.Text = Decode(f[1]); LogLine(status.Text); }
        UpdateControls();
    }
    void ShowConsent(string[] message)
    {
        CloseConsent(); Show(); Activate(); consentId = message[1]; string id = consentId;
        bool request = message[0] == "REQUEST";
        var dialog = new Form { Text = request ? "收到配對邀請" : "核對配對碼", ClientSize = new Size(440, 372), BackColor = Color.White, ForeColor = ShareStyle.Ink, Font = new Font(Font.FontFamily, 10F), FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false, AutoScaleDimensions=new SizeF(96F,96F), AutoScaleMode=AutoScaleMode.Dpi };
        consent = dialog;
        var left = new ComputerMark { BackColor = Color.White, Bounds = new Rectangle(150, 22, 44, 44) };
        var joint = new Label { Text = "⟷", ForeColor = ShareStyle.Faint, Font = new Font(Font.FontFamily, 14F), TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(198, 28, 44, 32) };
        var right = new ComputerMark { BackColor = Color.White, Bounds = new Rectangle(246, 22, 44, 44) };
        var title = new Label { Text = request ? "收到配對邀請" : "核對配對碼", Font = new Font(Font.FontFamily, 14F, FontStyle.Bold), TextAlign = ContentAlignment.MiddleCenter, Bounds = new Rectangle(24, 78, 392, 32) };
        var explanation = new Label { Text = Decode(message[2]) + "\r\n請確認另一台顯示相同的 6 位數配對碼。", ForeColor = ShareStyle.Muted, TextAlign = ContentAlignment.TopCenter, Bounds = new Rectangle(24, 112, 392, 48) };
        var code = new ShareCode { Text = message[4], BackColor = Color.White, Bounds = new Rectangle(40, 168, 360, 60) };
        var permission = new Label { Text = "同意後允許共用鍵盤滑鼠及雙向同步剪貼簿。\r\n配對會被記住，之後自動連線。", ForeColor = ShareStyle.Faint, Font = new Font(Font.FontFamily, 9F), TextAlign = ContentAlignment.TopCenter, Bounds = new Rectangle(24, 240, 392, 44) };
        var reject = new ShareButton { Text = "拒絕", BackColor=Color.White, Bounds = new Rectangle(24, 304, 128, 42), DialogResult = DialogResult.Cancel };
        var accept = new ShareButton { Text = "相同，同意配對", Primary=true, BackColor=Color.White, Bounds = new Rectangle(164, 304, 252, 42), DialogResult = DialogResult.OK };
        // Enter rejects: agreeing always takes a deliberate click.
        dialog.Controls.AddRange(new Control[] { left, joint, right, title, explanation, code, permission, reject, accept }); dialog.CancelButton = reject; dialog.AcceptButton = reject;
        UpdateControls(); var result = dialog.ShowDialog(this);
        if (consentId == id) { Send((result == DialogResult.OK ? "ACCEPT\t" : "REJECT\t") + id); consent = null; consentId = null; status.Text = result == DialogResult.OK ? "已同意，等待對方確認…" : "已拒絕配對。"; }
        dialog.Dispose(); UpdateControls();
    }
    void CloseConsent() { var dialog = consent; consent = null; consentId = null; if (dialog != null) dialog.Close(); }
    void StartBackend()
    {
        if (backend != null || !enabled) return;
        if (!testing && ShareService.Installed) {
            try {
                ShareSettings.Backend(Host, address.Text); // validates the address and settings
                serviceSince = DateTime.Now.AddSeconds(-1);
                var reply = ShareService.Request(ShareService.StartCommand(Host, address.Text), 5000);
                backend = new Process(); serviceLog = reply[2]; serviceOffsets.Clear();
                foreach (string path in new[] { Path.Combine(ShareSettings.Profile(Host), Host ? "server.log" : "windows.log"), serviceLog, Path.Combine(Path.GetDirectoryName(serviceLog), "service.log") }) {
                    long length = 0; try { length = new FileInfo(path).Length; } catch (Exception) { }
                    // The service notes which account runs the core as it starts it, before this reply;
                    // read its notes from the start and skip only those older than this request.
                    serviceOffsets[path] = path.EndsWith("service.log", StringComparison.OrdinalIgnoreCase) ? 0 : length;
                }
                serviceTail.Start(); LogLine("背景服務已啟動核心：平常以你的身分執行，登入、鎖定、UAC 畫面時改用系統身分 · " + Path.GetDirectoryName(serviceLog));
                connectedAddress = address.Text; status.Text = "配對已驗證，正在連線…"; UpdateControls();
                return;
            } catch (Exception e) { backend = null; serviceLog = null; LogLine("背景服務無法使用，改由這個程式啟動：" + e.Message); }
        }
        try {
            var process = new Process { StartInfo = ShareSettings.Backend(Host, address.Text), EnableRaisingEvents = true }; backend = process;
            process.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { Post(process, e.Data, false); }; process.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { Post(process, e.Data, false); };
            process.Exited += delegate { if (!closing && IsHandleCreated) BeginInvoke((Action)delegate { if (backend == process) { StopBackend(); status.Text = "連線暫停，會自動重試；詳情見診斷紀錄。"; } }); };
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine(); connectedAddress = address.Text; status.Text = "配對已驗證，正在連線…"; UpdateControls();
        } catch (Exception e) { StopBackend(); Error(e); }
    }
    void StopBackend()
    {
        var process = backend; backend = null; connections = 0;
        if (serviceLog != null) {
            serviceTail.Stop(); serviceLog = null;
            if (!keepServiceCore) try { ShareService.Request("STOP", 5000); } catch (Exception e) { LogLine("停止背景服務核心失敗：" + e.Message); }
        }
        if (process != null) { try { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } } catch (InvalidOperationException) { } process.Dispose(); ShareCursor.Restore(); }
        UpdateControls();
    }
    void LogLine(string line)
    {
        if (details.TextLength > 24000) details.Text = details.Text.Substring(details.TextLength - 12000); details.AppendText(line + Environment.NewLine);
        if (line.Contains("connected to server") || line.Contains("has connected")) { status.Text = "已連線 · 雙向複製貼上已啟用"; ++connections; UpdateControls(); }
        if (line.Contains("disconnected from server") || line.Contains("has disconnected")) { connections = Math.Max(0, connections - 1); UpdateControls(); }
        bool wasTransferring = transferring;
        if (line.Contains("file clipboard: sending")) { status.Text = "正在傳送檔案… 可繼續操作滑鼠與鍵盤"; transferring = true; progress.Reset(); }
        if (line.Contains("file clipboard: receiving")) { status.Text = "正在接收檔案… 完成後即可貼上"; transferring = true; progress.Reset(); popup.Prepare(); if (!testing) autoPaste.Start(); }
        string moved = progress.Describe(line, DateTime.UtcNow);
        if (moved != null && transferring) { status.Text = moved; int cut = moved.IndexOf("… "); popup.Progress(cut >= 0 ? moved.Substring(cut + 2) : moved); }
        if (line.Contains("file clipboard: sent ")) { status.Text = "檔案已送出 · 可在另一台貼上"; transferring = false; }
        if (line.Contains("received and verified") && line.Contains("clipboard")) {
            transferring = false; autoPaste.Stop(); Diagnose("自動貼上：" + autoPaste.Decision());
            if (autoPaste.Ready()) {
                // The core has just put the files on the clipboard; give it a moment, then paste where the user asked.
                status.Text = "已收到檔案，已自動貼上"; popup.Finish("已收到檔案", "已自動貼上");
                var delay = new System.Windows.Forms.Timer { Interval = 300 };
                delay.Tick += delegate {
                    delay.Stop(); delay.Dispose();
                    if (autoPaste.Ready()) { ShareAutoPaste.SendPaste(); Diagnose("自動貼上：已送出 Ctrl+V"); } else Diagnose("自動貼上：300 毫秒內前景改變，略過");
                    autoPaste.Clear();
                };
                delay.Start();
            } else {
                // A paste pressed in another window is not repeated; without any paste the popup never appeared.
                bool asked = autoPaste.Target != IntPtr.Zero; autoPaste.Clear();
                status.Text = "已收到檔案，可在資料夾按 Ctrl+V（Mac 鍵盤按 ⌘V）貼上";
                if (asked) popup.Finish("已收到檔案", "請在資料夾再按一次 Ctrl+V（Mac 鍵盤按 ⌘V）"); else popup.Dismiss();
            }
        }
        if (line.Contains("WARNING") && line.Contains("file clipboard:")) { status.Text = "檔案複製未完成；請查看診斷紀錄。"; transferring = false; autoPaste.Clear(); popup.Finish("檔案複製未完成", "詳情見「診斷紀錄」"); }
        if (line.Contains("disconnected") || line.Contains("server is dead")) {
            status.Text = "連線中斷，正在自動重連…"; transferring = false;
            autoPaste.Clear(); if (wasTransferring) popup.Finish("連線中斷", "檔案沒有傳完，請重新複製"); else popup.Dismiss();
        }
        if (wasTransferring != transferring) UpdateControls();
    }
    // Diagnostic note that is not parsed for status, unlike core log lines.
    void Diagnose(string text) { if (details.TextLength > 24000) details.Text = details.Text.Substring(details.TextLength - 12000); details.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + text + Environment.NewLine); }
    void ShowDiagnostics()
    {
        if (diagnostics == null) {
            diagnostics = new Form { Text="Barrier Share · 診斷紀錄", ClientSize=new Size(760,400), Font=Font, StartPosition=FormStartPosition.CenterParent, Padding=new Padding(18), BackColor=Color.White, AutoScaleDimensions=new SizeF(96F,96F), AutoScaleMode=AutoScaleMode.Dpi };
            details.Dock=DockStyle.Fill; diagnostics.Controls.Add(details);
            var copyAll = new ShareButton { Text="全部複製", BackColor=Color.White, Font=new Font(Font.FontFamily,10F), Dock=DockStyle.Bottom, Height=36 };
            copyAll.Click += delegate { if (details.TextLength > 0) { Clipboard.SetText(details.Text); copyAll.Text = "已複製"; } };
            details.TextChanged += delegate { copyAll.Text = "全部複製"; };
            diagnostics.Controls.Add(copyAll);
            diagnostics.FormClosing += delegate(object sender, FormClosingEventArgs e) { if (!closing) { e.Cancel=true; diagnostics.Hide(); } };
        }
        diagnostics.Show(this); diagnostics.Activate();
    }
    internal void TestDiscovery(string directory)
    {
        Action<string> capture = delegate(string filename) {
            Application.DoEvents(); Refresh();
            if (String.IsNullOrWhiteSpace(segment.AccessibilityObject.Name) || segment.AccessibilityObject.Value != (Host ? "主控端" : "接收端")) throw new Exception("Role switch is missing its accessible name or value");
            foreach (var container in new Control[] { body }.Concat(cards.Cast<Control>())) {
                var visible = container.Controls.Cast<Control>().Where(control => control.Visible).ToArray();
                for (int i = 0; i < visible.Length; ++i) {
                    if (!container.DisplayRectangle.Contains(visible[i].Bounds)) throw new Exception("Container clips control: " + visible[i].Text);
                    for (int j = i + 1; j < visible.Length; ++j)
                        if (visible[i].Bounds.IntersectsWith(visible[j].Bounds)) throw new Exception("Visible controls overlap: " + visible[i].Text + " / " + visible[j].Text);
                }
            }
            using (var bitmap = new Bitmap(Width, Height)) {
                DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size)); bitmap.Save(Path.Combine(directory, filename));
            }
        };
        role.SelectedIndex = 0;
        if (role.Items.Count != 2 || segment.Selected != 0) throw new Exception("Role choices are incomplete or out of step with the switch");
        // UI-only discovery fixture: no input capture or network service starts here.
        link = new Process(); LinkLine("READY");
        if (nearby.Visible || !emptyNearby.Visible || pair.Enabled) throw new Exception("Empty discovery state offers an unavailable peer");
        capture("gui-empty.png");
        string fp = "v2:sha256:" + new string('a', 64), name = Convert.ToBase64String(Encoding.UTF8.GetBytes("另一台電腦"));
        LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.2\t24801\tR");
        LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.3\t24801\tR");
        if (DeviceCount != 1 || SelectedDevice == null || SelectedDevice.Address != "192.168.1.3") throw new Exception("Discovery list update failed");
        LinkLine("SAVED\t" + fp + "\t" + name);
        if (!(nearby.Items[0] is ListHeader) || SelectedDevice == null || pair.Enabled) throw new Exception("Paired computer is not listed under 已配對 or can be invited again");
        using (var timer = new System.Windows.Forms.Timer { Interval = 250 }) {
            timer.Tick += delegate {
                timer.Stop();
                using (var bitmap = new Bitmap(consent.Width, consent.Height)) { consent.DrawToBitmap(bitmap, new Rectangle(Point.Empty, consent.Size)); bitmap.Save(Path.Combine(directory, "gui-pairing.png")); }
                LinkLine("CLOSED\ttest-request");
            };
            timer.Start(); LinkLine("VERIFY\ttest-request\t" + name + "\t" + fp + "\t123456");
        }
        if (consent != null || consentId != null) throw new Exception("Expired pairing dialog remained open");
        LinkLine("GONE\t" + fp);
        if (DeviceCount != 0 || !nearby.Items.OfType<NearbyDevice>().Any(d => d.Offline)) throw new Exception("Offline paired computer is not shown as offline");
        capture("gui-paired-offline.png");
        peers.Clear(); PeersChanged(); LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.3\t24801\tR");
        status.Text="找到附近電腦，可以發出配對邀請";
        if (!nearby.Visible || emptyNearby.Visible || !pair.Enabled) throw new Exception("Available peer cannot be invited");
        capture("gui-available.png");
        // A long list: the search box appears and filters by name or address.
        for (int i = 0; i < 9; ++i) LinkLine("DEVICE\tv2:sha256:" + new string((char)('0' + i), 64) + "\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes("PC-" + i)) + "\t10.0.0." + (10 + i) + "\t24801\tR");
        if (!filter.Visible || DeviceCount != 10) throw new Exception("Long list did not offer a search box");
        capture("gui-many.png");
        filter.Text = "10.0.0.13"; if (DeviceCount != 1 || ((NearbyDevice)nearby.Items[0]).Name != "PC-3") throw new Exception("Search did not filter by address");
        filter.Text = "zzz"; if (nearby.Visible || emptyNearby.Text != "找不到符合的電腦") throw new Exception("Empty search result not explained");
        filter.Text = "";
        for (int i = 0; i < 9; ++i) LinkLine("GONE\tv2:sha256:" + new string((char)('0' + i), 64));
        if (filter.Visible || DeviceCount != 1) throw new Exception("Search box stayed for a short list");
        string longName = Convert.ToBase64String(Encoding.UTF8.GetBytes("工作室的 Windows 11 筆記型電腦 — Design review and shared files workstation"));
        LinkLine("DEVICE\t" + fp + "\t" + longName + "\t192.168.1.3\t24801\tR");
        capture("gui-long-name.png");
        role.SelectedIndex = 1; link = new Process(); LinkLine("READY");
        if (segment.Selected != 1 || arrange.Visible || pair.Enabled) throw new Exception("Receiver offers host-only actions");
        capture("gui-receiver.png");
        stop.PerformClick();
        if (!start.Enabled || !start.Visible || stop.Visible || pair.Enabled || !clear.Enabled) throw new Exception("Paused state exposes active connection controls");
        capture("gui-paused.png");
        role.SelectedIndex = 0; enabled = true; link = new Process(); LinkLine("READY");
        LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.3\t24801\tR");
        status.Text="找到附近電腦，可以發出配對邀請";
        using (var graphics = CreateGraphics()) File.WriteAllText(Path.Combine(directory, "LAYOUT-PASS.txt"),
            "Empty, paired-offline, available, long list with search, long-name, receiver and paused states rendered with no clipped or overlapping visible controls. Actual render DPI: " + graphics.DpiX + " x " + graphics.DpiY + ". No simulated or physical multi-DPI claim.");
    }
    void FollowServiceLog()
    {
        if (serviceLog == null) return;
        foreach (string path in serviceOffsets.Keys.ToList()) {
            try {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                    long offset = serviceOffsets[path]; if (stream.Length < offset) offset = 0;
                    stream.Seek(offset, SeekOrigin.Begin);
                    var bytes = new byte[Math.Min(1 << 20, stream.Length - offset)]; int read = stream.Read(bytes, 0, bytes.Length);
                    int end = Array.LastIndexOf(bytes, (byte)'\n', Math.Max(0, read - 1));
                    if (read == 0 || end < 0) continue;
                    serviceOffsets[path] = offset + end + 1;
                    bool notes = path.EndsWith("service.log", StringComparison.OrdinalIgnoreCase);
                    foreach (string line in Encoding.UTF8.GetString(bytes, 0, end + 1).Split('\n')) {
                        string text = line.TrimEnd('\r');
                        DateTime stamp;
                        if (notes && text.Length > 21 && DateTime.TryParseExact(text.Substring(1, 19), "yyyy-MM-ddTHH:mm:ss", null, System.Globalization.DateTimeStyles.None, out stamp) && stamp < serviceSince) continue;
                        if (text.Length > 0) { if (notes) Diagnose("背景服務：" + text); else LogLine(text); }
                    }
                }
            } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
    // Restarting the connection drops the partial copy on both sides.
    void CancelTransfer() { transferring = false; autoPaste.Clear(); popup.Dismiss(); StopBackend(); StartBackend(); status.Text = "已取消檔案傳送，正在重新連線…"; }
    void Forget(string command, string question)
    {
        if (MessageBox.Show(this, question, "解除配對", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        StopBackend(); Send(command);
    }
    // Keeps the screen list, the paired label and the position controls in step with the paired computers.
    void PeersChanged()
    {
        ShareSettings.Receivers = Host ? peers.Keys.ToList() : new List<string>();
        var names = peers.Values.ToList();
        if (names.Count == 1 && Host) {
            Point cell; string where = ShareSettings.Cells().TryGetValue(ShareSettings.ScreenName(peers.Keys.First()), out cell) ? new Dictionary<Point, string> { { new Point(1, 0), "右" }, { new Point(-1, 0), "左" }, { new Point(0, -1), "上" }, { new Point(0, 1), "下" } }.FirstOrDefault(d => d.Key == cell).Value : null;
            peerLabel.Text = where != null ? "滑鼠往" + where + "移到 " + names[0] : "已配對 · " + names[0];
        }
        else if (names.Count == 1) peerLabel.Text = "已配對主控端 · " + names[0];
        else if (names.Count > 1) peerLabel.Text = "已配對 " + names.Count + " 台 · " + String.Join("、", names);
        else peerLabel.Text = Host ? "在下方選擇接收端，按「邀請配對」。" : "等待主控端邀請；首次需要你同意。";
        position.Visible = false; positionHint.Visible = false;
        RebuildNearby();
    }
    internal ShareLayoutEditor BuildLayout() { return new ShareLayoutEditor(peers, Font); }
    void ShowLayout()
    {
        using (var editor = BuildLayout()) {
            if (editor.ShowDialog(this) != DialogResult.OK) return;
            foreach (var item in editor.Placement) ShareSettings.Layout[item.Key] = item.Value;
            Save(); PeersChanged(); if (backend != null) StopBackend(); status.Text = "已儲存螢幕排列。";
        }
    }
    void SendTargets() { try { string list = ShareSettings.Advanced.TargetList(); if (list.Length > 0 || link != null) Send("TARGETS\t" + list); } catch (Exception e) { Error(e); } }
    // Host-side Barrier options plus direct addresses for computers on another subnet or VPN.
    // Grouped rows: a name and a short explanation on the left, the control on the right.
    internal Form BuildAdvanced(ShareAdvanced a, out Func<ShareAdvanced> read)
    {
        var dialog = new Form { Text = "進階設定", ClientSize = new Size(568, 600), AutoScroll = true, BackColor = Color.White, ForeColor = ShareStyle.Ink, Font = new Font(Font.FontFamily, 10F), FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false, AutoScaleDimensions = new SizeF(96F, 96F), AutoScaleMode = AutoScaleMode.Dpi };
        const int W = 520; int y = 16;
        dialog.Controls.Add(new Label { Text = "進階設定", Font = new Font(Font.FontFamily, 13F, FontStyle.Bold), Bounds = new Rectangle(24, y, W, 28) }); y += 30;
        dialog.Controls.Add(new Label { Text = Host ? "由這台（主控端）套用到所有螢幕；儲存後自動重新連線。" : "切換設定只在主控端生效；這台目前是接收端。", ForeColor = ShareStyle.Muted, Bounds = new Rectangle(24, y, W, 22) }); y += 32;
        ShareCard group = null; int rowY = 0;
        Action<string> section = text => {
            dialog.Controls.Add(new Label { Text = text, ForeColor = ShareStyle.Muted, Font = new Font(Font.FontFamily, 9F, FontStyle.Bold), Bounds = new Rectangle(24, y, W, 20) }); y += 22;
            group = new ShareCard { BackColor = Color.White, Bounds = new Rectangle(24, y, W, 10) }; dialog.Controls.Add(group); rowY = 0;
        };
        Action<string, string, Control> row = (title, detail, control) => {
            int h = detail == null ? 44 : 56;
            if (rowY > 0) group.Controls.Add(new Panel { BackColor = Color.FromArgb(236, 240, 246), Bounds = new Rectangle(14, rowY, W - 28, 1) });
            group.Controls.Add(new Label { Text = title, BackColor = Color.White, Bounds = new Rectangle(14, rowY + (detail == null ? 11 : 8), W - 180, 22) });
            if (detail != null) group.Controls.Add(new Label { Text = detail, BackColor = Color.White, ForeColor = ShareStyle.Faint, Font = new Font(Font.FontFamily, 8.5F), Bounds = new Rectangle(14, rowY + 30, W - 180, 18) });
            control.Location = new Point(W - 14 - control.Width, rowY + (h - control.Height) / 2); control.AccessibleName = title; group.Controls.Add(control);
            rowY += h; group.Height = rowY + 1; y = group.Bottom;
        };
        Func<bool, CheckBox> check = value => new CheckBox { Checked = value, BackColor = Color.White, Size = new Size(20, 20) };
        Func<int[], Func<int, string>, int, ShareComboBox> choice = (values, label, current) => {
            var list = values.ToList(); if (!list.Contains(current)) { list.Add(current); list.Sort(); }
            var box = new ShareComboBox { Font = new Font(Font.FontFamily, 9.5F), Size = new Size(132, 30), Tag = list };
            foreach (int v in list) box.Items.Add(label(v)); box.SelectedIndex = list.IndexOf(current); return box;
        };
        Func<ShareComboBox, int> picked = box => ((List<int>)box.Tag)[Math.Max(0, box.SelectedIndex)];
        section("切換螢幕");
        var delay = choice(new[] { 0, 250, 500, 1000 }, v => v == 0 ? "立即" : v % 1000 == 0 ? v / 1000 + " 秒" : (v / 1000.0).ToString("0.##") + " 秒", a.SwitchDelay);
        row("停留多久才切換", "避免滑鼠擦過邊緣就跑到另一台", delay);
        var tap = choice(new[] { 0, 250, 400 }, v => v == 0 ? "關閉" : (v / 1000.0).ToString("0.##") + " 秒內", a.DoubleTap);
        row("連碰兩下邊緣才切換", null, tap);
        var corners = check(a.Corners); row("螢幕角落不切換", "方便點角落的開始按鈕或關閉鈕", corners);
        var keys = check(a.SwitchKeys); row("快速鍵切換", "Ctrl+Alt+方向鍵", keys);
        y += 16; section("鍵盤與滑鼠");
        var swap = check(a.SwapModifiers); row("Mac 上對調 Ctrl 與 Command", "Windows 鍵盤在 Mac 上可按 Ctrl+C／V", swap);
        var lockKey = check(a.LockKey); row("鎖定游標在目前螢幕", "Ctrl+Alt+L 切換", lockKey);
        var relative = check(a.RelativeMouse); row("相對滑鼠移動", "全螢幕遊戲用", relative);
        var saver = check(a.ScreenSaver); row("同步螢幕保護程式", null, saver);
        y += 16; section("連線");
        var targets = new TextBox { Text = String.Join(Environment.NewLine, (a.Targets ?? "").Split(new[] { ',', ' ', ';', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)), Multiline = true, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9.5F), Size = new Size(200, 44) };
        row("手動位址", "跨網段或 VPN 時填入對方 IP，一行一個", targets);
        y += 12;
        var expertToggle = new LinkLabel { Text = "▸ 自訂 Barrier 選項（專家）", LinkColor = ShareStyle.Muted, ActiveLinkColor = ShareStyle.Blue, LinkBehavior = LinkBehavior.HoverUnderline, Bounds = new Rectangle(24, y, W, 24) };
        dialog.Controls.Add(expertToggle); y += 28;
        var extra = new TextBox { Text = (a.Extra ?? "").Replace("\r\n", "\n").Replace("\n", "\r\n"), Multiline = true, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9.5F), Bounds = new Rectangle(24, y, W, 70), AccessibleName = "自訂 Barrier 選項" };
        dialog.Controls.Add(extra); int expertHeight = 80;
        int buttonsY = y + 8;
        var reset = new ShareButton { Text = "恢復預設", Quiet = true, BackColor = Color.White, Bounds = new Rectangle(24, buttonsY, 100, 38) };
        var cancel = new ShareButton { Text = "取消", BackColor = Color.White, Bounds = new Rectangle(W + 24 - 232, buttonsY, 108, 38), DialogResult = DialogResult.Cancel };
        var ok = new ShareButton { Text = "儲存", Primary = true, BackColor = Color.White, Bounds = new Rectangle(W + 24 - 112, buttonsY, 112, 38) };
        dialog.Controls.AddRange(new Control[] { reset, cancel, ok }); dialog.CancelButton = cancel;
        // The expert box opens on demand (or when it already holds something) and moves the buttons below it.
        Action<bool> expert = open => {
            extra.Visible = open; expertToggle.Text = (open ? "▾" : "▸") + " 自訂 Barrier 選項（專家）";
            float k = dialog.IsHandleCreated ? dialog.CurrentAutoScaleDimensions.Height / 96F : 1F; int top = buttonsY + (open ? expertHeight : 0);
            foreach (var b in new Control[] { reset, cancel, ok }) b.Top = (int)(top * k);
            // Short screens get a scrolling dialog instead of one Windows squeezes and cuts off.
            int full = (int)((top + 56) * k), room = Screen.FromPoint(Cursor.Position).WorkingArea.Height - (dialog.Height - dialog.ClientSize.Height) - 40;
            dialog.AutoScrollMinSize = new Size(0, full);
            dialog.ClientSize = new Size((int)(568 * k) + (full > room ? SystemInformation.VerticalScrollBarWidth : 0), Math.Min(full, room));
        };
        expertToggle.LinkClicked += delegate { expert(!extra.Visible); };
        reset.Click += delegate {
            var d = new ShareAdvanced();
            delay.SelectedIndex = ((List<int>)delay.Tag).IndexOf(d.SwitchDelay); tap.SelectedIndex = ((List<int>)tap.Tag).IndexOf(d.DoubleTap);
            corners.Checked = d.Corners; keys.Checked = d.SwitchKeys; swap.Checked = d.SwapModifiers; lockKey.Checked = d.LockKey; relative.Checked = d.RelativeMouse; saver.Checked = d.ScreenSaver;
        };
        read = () => new ShareAdvanced { SwitchDelay = picked(delay), DoubleTap = picked(tap), Corners = corners.Checked, CornerSize = a.CornerSize, SwapModifiers = swap.Checked,
            RelativeMouse = relative.Checked, ScreenSaver = saver.Checked, SwitchKeys = keys.Checked, LockKey = lockKey.Checked, Targets = String.Join(", ", targets.Lines.Select(l => l.Trim()).Where(l => l.Length > 0)), Extra = extra.Text };
        var reader = read;
        ok.Click += delegate {
            try { var value = reader(); value.TargetList(); value.ExtraLines().ToList(); dialog.DialogResult = DialogResult.OK; }
            catch (IOException e) { MessageBox.Show(dialog, e.Message, "進階設定"); }
        };
        expert(a.Extra.Trim().Length > 0);
        return dialog;
    }
    void ShowAdvanced()
    {
        Func<ShareAdvanced> read;
        using (var dialog = BuildAdvanced(ShareSettings.Advanced, out read)) {
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            ShareSettings.Advanced = read(); Save(); SendTargets();
            // The host core reads options at start; the saved pairing reconnects it right away.
            if (Host && backend != null) StopBackend();
            status.Text = "已儲存進階設定。";
        }
    }
    void ClearCache()
    {
        if (MessageBox.Show(this, "清除尚未貼上的接收檔案暫存？已貼出的檔案不受影響。", "清除暫存", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        try {
            if (Clipboard.ContainsFileDropList() && Clipboard.GetFileDropList().Cast<string>().Any(p => p.StartsWith(ShareSettings.Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))) Clipboard.Clear();
            foreach (bool host in new[] { true, false }) foreach (string name in new[] { "ClipboardCache", "FileClipboardCache" }) { string cache = Path.Combine(ShareSettings.Profile(host), name); if (Directory.Exists(cache)) Directory.Delete(cache, true); }
            status.Text = "已清除接收檔案暫存。";
        } catch (Exception e) { Error(e); }
    }
}

// A paste pressed while files are still arriving is remembered and done once they are verified.
// A low-level keyboard hook (installed only while receiving) sees Ctrl+V, including keys the core
// injects for the other computer, and records the window that had the focus.
sealed class ShareAutoPaste : IDisposable
{
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    readonly HookProc proc; IntPtr hook;
    // Modifier state followed from the hook's own events: the async key state can lag behind injected input.
    bool ctrl, alt, shift, win;
    public IntPtr Target { get; private set; }
    public event Action Requested;
    public event Action<string> Note;
    public ShareAutoPaste() { proc = Hook; }
    void Log(string text) { var h = Note; if (h != null) h("自動貼上：" + text); }
    public static string Describe(IntPtr window)
    {
        if (window == IntPtr.Zero) return "無";
        var name = new StringBuilder(128); GetClassName(window, name, name.Capacity);
        return "0x" + window.ToInt64().ToString("X") + "，類別 " + name;
    }
    static bool Own(IntPtr window) { uint process; GetWindowThreadProcessId(window, out process); return process == (uint)Process.GetCurrentProcess().Id; }
    IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0) {
            int vk = System.Runtime.InteropServices.Marshal.ReadInt32(lParam), flags = System.Runtime.InteropServices.Marshal.ReadInt32(lParam, 8);
            bool down = wParam == (IntPtr)0x0100 || wParam == (IntPtr)0x0104, up = wParam == (IntPtr)0x0101 || wParam == (IntPtr)0x0105;
            if (down || up) {
                if (vk == 0x11 || vk == 0xA2 || vk == 0xA3) ctrl = down;
                else if (vk == 0x12 || vk == 0xA4 || vk == 0xA5) alt = down;
                else if (vk == 0x10 || vk == 0xA0 || vk == 0xA1) shift = down;
                else if (vk == 0x5B || vk == 0x5C) win = down;
                // V with Ctrl only; keys injected for the other computer count too.
                else if (vk == 0x56 && down && ctrl) {
                    if (alt || shift || win) Log("偵測到 Ctrl+V 但同時按了其他修飾鍵，略過");
                    else { var foreground = GetForegroundWindow(); Log("偵測到 Ctrl+V（前景 " + Describe(foreground) + (((flags & 0x10) != 0) ? "，注入" : "") + "）"); Record(foreground); }
                }
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }
    // Only the first paste counts; the target is the top-level window that had the focus.
    internal void Record(IntPtr window)
    {
        if (Target != IntPtr.Zero || window == IntPtr.Zero) return;
        var root = GetAncestor(window, 2 /* GA_ROOT */); if (root != IntPtr.Zero) window = root;
        if (Own(window)) { Log("前景是 Barrier Share 自己的視窗，略過"); return; }
        Target = window; var h = Requested; if (h != null) h();
    }
    public void Start()
    {
        Stop(); Target = IntPtr.Zero; ctrl = alt = shift = win = false;
        hook = SetWindowsHookEx(13 /* WH_KEYBOARD_LL */, proc, GetModuleHandle(null), 0);
        Log(hook != IntPtr.Zero ? "已安裝鍵盤 hook" : "鍵盤 hook 安裝失敗，錯誤碼 " + System.Runtime.InteropServices.Marshal.GetLastWin32Error());
    }
    public void Stop() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
    public void Clear() { Stop(); Target = IntPtr.Zero; }
    // Paste again only into the window that asked, and only if it still has the focus.
    public static bool ShouldPaste(IntPtr recorded, IntPtr foreground) { return recorded != IntPtr.Zero && recorded == foreground; }
    public bool Ready() { var f = GetForegroundWindow(); var root = GetAncestor(f, 2); return ShouldPaste(Target, root != IntPtr.Zero ? root : f); }
    // One diagnostic line for the decision when the files have arrived.
    public string Decision()
    {
        var f = GetForegroundWindow();
        if (Target == IntPtr.Zero) return "傳完，傳輸中沒有偵測到 Ctrl+V，不自動貼上";
        return "傳完，記錄的視窗 " + Describe(Target) + "，目前前景 " + Describe(f) + (Ready() ? "；將送出 Ctrl+V" : "；前景已改變，略過");
    }
    public static void SendPaste()
    {
        keybd_event(0x11, 0, 0, UIntPtr.Zero); keybd_event(0x56, 0, 0, UIntPtr.Zero);
        keybd_event(0x56, 0, 2 /* KEYUP */, UIntPtr.Zero); keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
    public void Dispose() { Stop(); }
}

// Small always-on-top window above the taskbar while files are copied; never takes the focus.
// Same behaviour as the Mac app: shown only if a transfer is still running after a second,
// marquee bar (the total size is not known), cancel button, result shown for 5 seconds.
sealed class ShareTransferPopup : Form
{
    readonly Label title = new Label(), detail = new Label();
    readonly ProgressBar bar = new ProgressBar { Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30 };
    readonly ShareButton cancel = new ShareButton { Text = "取消傳送" };
    readonly System.Windows.Forms.Timer showTimer = new System.Windows.Forms.Timer { Interval = 1000 }, closeTimer = new System.Windows.Forms.Timer { Interval = 5000 };
    public event Action CancelRequested;
    public ShareTransferPopup(Font font)
    {
        // Not Form.TopMost: setting it calls SetWindowPos without SWP_NOACTIVATE and can take the focus,
        // so a paste pressed during the transfer would land in this window. WS_EX_TOPMOST is set instead.
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
        BackColor = Color.White; ForeColor = ShareStyle.Ink; Font = new Font(font.FontFamily, 10F);
        AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi; ClientSize = new Size(340, 96);
        title.Font = new Font(font.FontFamily, 11F, FontStyle.Bold); title.Bounds = new Rectangle(16, 10, 308, 24);
        detail.ForeColor = ShareStyle.Muted; detail.Bounds = new Rectangle(16, 36, 308, 22); detail.AutoEllipsis = true;
        bar.Bounds = new Rectangle(16, 66, 196, 14);
        cancel.BackColor = Color.White; cancel.Bounds = new Rectangle(224, 58, 100, 30); cancel.Click += delegate { var handler = CancelRequested; if (handler != null) handler(); };
        Controls.AddRange(new Control[] { title, detail, bar, cancel });
        showTimer.Tick += delegate { showTimer.Stop(); ShowQuietly(); };
        closeTimer.Tick += delegate { closeTimer.Stop(); Hide(); };
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST: no focus, no taskbar button, above other windows.
        get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; return p; }
    }
    protected override void OnPaint(PaintEventArgs e) { base.OnPaint(e); using (var pen = new Pen(ShareStyle.Border)) e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1); }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
    void Place() { var area = Screen.PrimaryScreen.WorkingArea; Location = new Point(area.Right - Width - 12, area.Bottom - Height - 12); }
    // Shown above other windows without activation (SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE).
    void ShowQuietly() { Place(); Show(); SetWindowPos(Handle, new IntPtr(-1) /* HWND_TOPMOST */, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
    internal bool Topmost { get { return IsHandleCreated && (GetWindowLong(Handle, -20 /* GWL_EXSTYLE */) & 0x8) != 0; } }
    // A transfer started; the window appears only if it is still running a second later.
    // Receiving started: ready the popup without showing it.
    public void Prepare() { Begin(false); }
    // A paste was pressed while receiving: show at once with the latest progress.
    public void ShowForPaste() { MarkAutoPaste(); if (!Visible) ShowQuietly(); }
    public void Begin(bool sending)
    {
        closeTimer.Stop(); title.Text = sending ? "正在傳送檔案…" : "正在接收檔案…"; detail.Text = sending ? "準備中" : "準備中";
        bar.Visible = cancel.Visible = true;
    }
    public void Progress(string text) { detail.Text = text; }
    // The title keeps this note for the rest of the transfer; Begin starts without it.
    public void MarkAutoPaste() { const string note = "（傳完自動貼上）"; if (!title.Text.EndsWith(note)) title.Text += note; }
    // Results are shown only when the window is already up, then it closes after 5 seconds.
    public void Finish(string heading, string text)
    {
        showTimer.Stop();
        if (!Visible) return;
        title.Text = heading; detail.Text = text; bar.Visible = cancel.Visible = false; closeTimer.Stop(); closeTimer.Start();
    }
    public void Dismiss() { showTimer.Stop(); closeTimer.Stop(); Hide(); }
    internal void ShowNow() { showTimer.Stop(); ShowQuietly(); }
    internal bool Busy { get { return bar.Visible && cancel.Visible; } }
    internal string Heading { get { return title.Text; } }
    internal string Detail { get { return detail.Text; } }
}

// Drag the paired receivers around this host on a 5x5 grid. Neighbouring cells are linked edges;
// every screen must touch the group, or the cursor could never reach it.
sealed class ShareLayoutEditor : Form
{
    const int Cell = 96, Tall = 60, Span = 2;
    static readonly Color[] Palette = { Color.FromArgb(29, 158, 117), Color.FromArgb(127, 119, 221), Color.FromArgb(216, 90, 48), Color.FromArgb(212, 83, 126), Color.FromArgb(186, 117, 23) };
    public readonly Dictionary<string, Point> Placement = new Dictionary<string, Point>();
    readonly Dictionary<string, string> names = new Dictionary<string, string>();
    readonly List<string> order = new List<string>();
    readonly Panel canvas = new Panel(), legend = new Panel();
    readonly Label warning = new Label();
    readonly ShareButton save = new ShareButton { Text = "儲存", Primary = true };
    string dragging; Point pointer;
    public ShareLayoutEditor(Dictionary<string, string> peers, Font font)
    {
        Text = "排列螢幕"; Font = new Font(font.FontFamily, 10F); BackColor = Color.White; ForeColor = ShareStyle.Ink;
        FormBorderStyle = FormBorderStyle.FixedDialog; StartPosition = FormStartPosition.CenterParent; MaximizeBox = MinimizeBox = false;
        AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
        int width = Cell * (Span * 2 + 1), height = Tall * (Span * 2 + 1);
        ClientSize = new Size(width + 248, height + 160);
        Controls.Add(new Label { Text = "排列螢幕", Font = new Font(Font.FontFamily, 13F, FontStyle.Bold), Bounds = new Rectangle(24, 14, width, 28) });
        Controls.Add(new Label { Text = "拖曳接收端到這台的上下左右；滑鼠從相鄰的邊移過去。", Bounds = new Rectangle(24, 42, width + 200, 22), ForeColor = ShareStyle.Muted });
        canvas.Bounds = new Rectangle(24, 74, width, height); canvas.BackColor = ShareStyle.Background;
        typeof(Panel).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).SetValue(canvas, true, null);
        Controls.Add(canvas);
        legend.Bounds = new Rectangle(width + 40, 74, 184, height); legend.BackColor = Color.White;
        typeof(Panel).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).SetValue(legend, true, null);
        Controls.Add(legend);
        warning.Bounds = new Rectangle(24, 80 + height, width + 200, 24); warning.ForeColor = ShareStyle.Danger; Controls.Add(warning);
        var reset = new ShareButton { Text = "恢復預設", Quiet = true, BackColor = Color.White, Bounds = new Rectangle(24, 110 + height, 100, 36) };
        var cancel = new ShareButton { Text = "取消", BackColor = Color.White, Bounds = new Rectangle(width + 224 - 224, 110 + height, 108, 36), DialogResult = DialogResult.Cancel };
        save.BackColor = Color.White; save.Bounds = new Rectangle(width + 224 - 104, 110 + height, 128, 36); save.DialogResult = DialogResult.OK;
        Controls.Add(reset); Controls.Add(cancel); Controls.Add(save); CancelButton = cancel;
        var cells = ShareSettings.Cells();
        foreach (var peer in peers) {
            names[peer.Key] = peer.Value; order.Add(peer.Key);
            Point cell; if (cells.TryGetValue(ShareSettings.ScreenName(peer.Key), out cell)) Placement[peer.Key] = cell;
        }
        reset.Click += delegate {
            // The automatic placement: the saved arrangement set aside for a moment.
            var saved = ShareSettings.Layout; ShareSettings.Layout = new Dictionary<string, Point>();
            try { var auto = ShareSettings.Cells(); foreach (var fp in order) { Point c; if (auto.TryGetValue(ShareSettings.ScreenName(fp), out c)) Placement[fp] = c; } }
            finally { ShareSettings.Layout = saved; }
            Check(); canvas.Invalidate();
        };
        canvas.Paint += (sender, e) => Draw(e.Graphics);
        legend.Paint += (sender, e) => DrawLegend(e.Graphics);
        canvas.MouseDown += (sender, e) => { dragging = Placement.Where(p => CellBounds(p.Value).Contains(Unscale(e.Location))).Select(p => p.Key).FirstOrDefault(); pointer = Unscale(e.Location); canvas.Cursor = dragging != null ? Cursors.SizeAll : Cursors.Default; };
        canvas.MouseMove += (sender, e) => {
            var at = Unscale(e.Location);
            if (dragging != null) { pointer = at; canvas.Invalidate(); }
            else canvas.Cursor = Placement.Any(p => CellBounds(p.Value).Contains(at)) ? Cursors.Hand : Cursors.Default;
        };
        canvas.MouseUp += (sender, e) => {
            if (dragging == null) return;
            var at = Unscale(e.Location); var target = new Point(at.X / Cell - Span, at.Y / Tall - Span);
            if (Math.Abs(target.X) <= Span && Math.Abs(target.Y) <= Span && target != Point.Empty && !Placement.Any(p => p.Key != dragging && p.Value == target)) Placement[dragging] = target;
            dragging = null; canvas.Cursor = Cursors.Default; Check(); canvas.Invalidate();
        };
        Check();
    }
    // Drawing works in 96-dpi units; the canvas itself is scaled with the dialog.
    float Zoom { get { return canvas.Width / (float)(Cell * (Span * 2 + 1)); } }
    Point Unscale(Point p) { float k = Zoom; return new Point((int)(p.X / k), (int)(p.Y / k)); }
    Rectangle CellBounds(Point cell) { return new Rectangle((cell.X + Span) * Cell + 5, (cell.Y + Span) * Tall + 5, Cell - 10, Tall - 10); }
    Color ColorOf(string fp) { return Palette[Math.Max(0, order.IndexOf(fp)) % Palette.Length]; }
    static Color Light(Color c) { return Color.FromArgb(232 + (c.R * 23 / 255), 232 + (c.G * 23 / 255), 232 + (c.B * 23 / 255)); }
    static string Direction(Point c)
    {
        if (c == new Point(1, 0)) return "右"; if (c == new Point(-1, 0)) return "左"; if (c == new Point(0, -1)) return "上"; if (c == new Point(0, 1)) return "下";
        return "經由其他螢幕";
    }
    // Every receiver must be connected to the host through neighbouring cells.
    public bool Reachable()
    {
        var seen = new HashSet<Point> { Point.Empty }; var queue = new Queue<Point>(seen); var all = new HashSet<Point>(Placement.Values);
        while (queue.Count > 0) {
            var c = queue.Dequeue();
            foreach (var n in new[] { new Point(c.X + 1, c.Y), new Point(c.X - 1, c.Y), new Point(c.X, c.Y + 1), new Point(c.X, c.Y - 1) })
                if (all.Contains(n) && seen.Add(n)) queue.Enqueue(n);
        }
        return all.All(seen.Contains);
    }
    void Check()
    {
        bool ok = Reachable(); save.Enabled = ok;
        warning.Text = ok ? "" : "有電腦沒有和其他螢幕相鄰，滑鼠到不了；請把它移到相鄰的位置。";
        legend.Invalidate();
    }
    void Draw(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias; float k = Zoom; g.ScaleTransform(k, k);
        using (var grid = new Pen(ShareStyle.Border) { DashStyle = DashStyle.Dash })
            for (int y = -Span; y <= Span; ++y) for (int x = -Span; x <= Span; ++x) using (var path = ShareStyle.Rounded(CellBounds(new Point(x, y)), 6)) g.DrawPath(grid, path);
        Action<Rectangle, string, Color, Color, bool> tile = (r, text, fill, edge, host) => {
            using (var path = ShareStyle.Rounded(r, 7)) using (var b = new SolidBrush(fill)) using (var pen = new Pen(edge, 1.5F)) { g.FillPath(b, path); g.DrawPath(pen, path); }
            var label = new Rectangle(r.X + 4, r.Y + (host ? 22 : 4), r.Width - 8, r.Height - (host ? 24 : 8));
            if (host) using (var pen = new Pen(edge, 1.5F)) { float mx = r.X + r.Width / 2F, my = r.Y + 14; g.DrawEllipse(pen, mx - 4, my - 7, 8, 13); g.DrawLine(pen, mx, my - 7, mx, my - 3); }
            using (var f = new Font(Font.FontFamily, 9F)) TextRenderer.DrawText(g, text, f, label, edge, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        };
        tile(CellBounds(Point.Empty), "這台", ShareStyle.Tint, ShareStyle.Blue, true);
        foreach (var p in Placement.OrderBy(p => p.Key == dragging)) {
            var r = CellBounds(p.Value);
            if (p.Key == dragging) r.Offset(pointer.X - r.X - r.Width / 2, pointer.Y - r.Y - r.Height / 2);
            var c = ColorOf(p.Key); tile(r, names[p.Key], Light(c), Color.FromArgb(c.R * 7 / 10, c.G * 7 / 10, c.B * 7 / 10), false);
        }
    }
    void DrawLegend(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias; float k = Zoom; g.ScaleTransform(k, k);
        using (var f = new Font(Font.FontFamily, 8.5F)) TextRenderer.DrawText(g, "已配對", f, new Point(0, 0), ShareStyle.Faint);
        int y = 24;
        foreach (var fp in order) {
            var r = new Rectangle(0, y, 180, 34);
            using (var path = ShareStyle.Rounded(r, 7)) using (var pen = new Pen(ShareStyle.Border)) g.DrawPath(pen, path);
            using (var b = new SolidBrush(ColorOf(fp))) g.FillRectangle(b, 10, y + 13, 8, 8);
            using (var f = new Font(Font.FontFamily, 9F)) {
                TextRenderer.DrawText(g, names[fp], f, new Rectangle(26, y, 100, 34), ShareStyle.Ink, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                Point c; string where = Placement.TryGetValue(fp, out c) ? Direction(c) : "";
                TextRenderer.DrawText(g, where, f, new Rectangle(110, y, 62, 34), ShareStyle.Faint, TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            }
            y += 40;
        }
        using (var f = new Font(Font.FontFamily, 8.5F)) TextRenderer.DrawText(g, "每台都要能從這台一路走到；斜角不相連。", f, new Rectangle(0, y + 6, 180, 48), ShareStyle.Faint, TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
    }
    // Test hook: place a receiver as a drag would.
    internal bool Place(string fingerprint, Point cell)
    {
        if (cell == Point.Empty || Placement.Any(p => p.Key != fingerprint && p.Value == cell)) return false;
        Placement[fingerprint] = cell; Check(); canvas.Invalidate(); return true;
    }
}

// UAC elevation of this process. Only a split (UAC) token counts: with UAC off every process is "full".
static class ShareElevation
{
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returned);
    // TOKEN_ELEVATION_TYPE: 1 default (no UAC split), 2 full (elevated), 3 limited.
    public static int Type
    {
        get {
            int type, returned;
            using (var identity = System.Security.Principal.WindowsIdentity.GetCurrent())
                return GetTokenInformation(identity.Token, 18 /* TokenElevationType */, out type, 4, out returned) ? type : 0;
        }
    }
    public static string Describe()
    {
        int type = Type;
        return type == 2 ? "以系統管理員身分執行（另一台的滑鼠無法操作這個視窗）" : type == 3 ? "一般使用者" : type == 1 ? "未啟用 UAC" : "未知";
    }
    // Started elevated (for example by an installer run as administrator): ask the shell to start a normal
    // copy and quit. A marker stops a loop when the shell itself is elevated.
    public static bool Relaunch()
    {
        try {
            if (Type != 2) return false;
            string marker = Path.Combine(Path.GetTempPath(), "BarrierShare.unelevated");
            if (File.Exists(marker) && DateTime.UtcNow - File.GetLastWriteTimeUtc(marker) < TimeSpan.FromSeconds(30)) return false;
            File.WriteAllText(marker, "");
            // explorer.exe hands the path to the running (unelevated) shell, which starts it with normal rights.
            Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), "\"" + Application.ExecutablePath + "\"") { UseShellExecute = false });
            return true;
        } catch (Exception) { return false; }
    }
}

static class ShareProgram
{
    // windows-setup.iss signals this before replacing files; keep the name in sync.
    public const string QuitEvent = "Local\\BarrierShare.Quit";
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 2 && args[0] == "--self-test") return SelfTest(args[1]);
        // An elevated window cannot be controlled by the other computer: the core injects input with the
        // user's normal rights and Windows blocks that for higher-integrity windows. Start again unelevated.
        if (args.Length == 0 && ShareElevation.Relaunch()) return 0;
        bool created;
        using (var mutex = new Mutex(true, "Local\\BarrierShare.Desktop", out created)) {
            if (!created) { MessageBox.Show("Barrier Share 已在執行，請從右下角圖示開啟。", "Barrier Share"); return 0; }
            using (var quit = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEvent))
            using (var window = new ShareWindow()) {
                if (args.Length == 2 && args[0] == "--startup-test") {
                    ShareSettings.Root = Path.Combine(Path.GetFullPath(args[1]), "startup-profile");
                    window.CheckProductionStartup(Path.GetFullPath(args[1]));
                }
                window.StartHidden = args.Length == 1 && args[0] == "--background";
                var wait = ThreadPool.RegisterWaitForSingleObject(quit, delegate { window.Quit(); }, null, Timeout.Infinite, true);
                Application.Run(window);
                wait.Unregister(null);
            }
        }
        return Environment.ExitCode;
    }
    static int SelfTest(string directory)
    {
        try {
            ShareSettings.Root = Path.Combine(directory, "新設定");
            ShareSettings.Position = "up"; ShareSettings.Save(false, "192.168.7.4");
            bool host; string address; ShareSettings.Load(out host, out address);
            if (host || address != "192.168.7.4" || ShareSettings.Position != "up") throw new Exception("Settings roundtrip failed");
            string old = Path.Combine(directory, "舊版本"), oldProfile = Path.Combine(old, "profile");
            string peer = ShareSettings.Pair("init", oldProfile);
            ShareSettings.Pair("trust", oldProfile, "server", peer);
            if (!ShareSettings.Import(old, false, false) || ShareSettings.Init(false) != peer || !ShareSettings.Trusted(false, peer)) throw new Exception("Pairing import failed");
            if (ShareSettings.Import(old, false, false)) throw new Exception("Existing pairing overwritten");
            // Paths with spaces and a trailing slash must survive native argv parsing.
            string spaced = Path.Combine(directory, "path with spaces") + Path.DirectorySeparatorChar;
            ShareSettings.Pair("init", spaced);
            if (!File.Exists(Path.Combine(spaced, "SSL", "Barrier.pem"))) throw new Exception("Argument quoting failed");
            bool rejected = false;
            try { ShareSettings.Backend(false, "host & command"); } catch (IOException) { rejected = true; }
            if (!rejected) throw new Exception("Invalid server address accepted");
            string oldHost = Path.Combine(old, "profile-server");
            string hostFingerprint = ShareSettings.Pair("init", oldHost);
            ShareSettings.Pair("trust", oldHost, "client", peer);
            if (!ShareSettings.Import(old, true, false) || ShareSettings.Init(true) != hostFingerprint || !ShareSettings.Trusted(true, peer)) throw new Exception("Host pairing import failed");
            foreach (string direction in ShareSettings.Directions) {
                ShareSettings.Position = direction;
                string config = ShareSettings.Config(true);
                string opposite = new[] { "left", "right", "down", "up" }[Array.IndexOf(ShareSettings.Directions, direction)];
                if (!config.Contains(direction + " = windows\n") || !config.Contains(opposite + " = windows-host\n")) throw new Exception("Screen position mapping failed");
                if (!config.Contains("= switchInDirection(" + direction + ")\n") || !config.Contains("= switchInDirection(" + opposite + ")\n") || Regex.Matches(config, "keystroke").Count != 2) throw new Exception("Switch hotkeys missing for " + direction);
            }
            ShareSettings.Position = "right";
            if (!ShareSettings.Config(true).Contains(" keystroke(Control+Alt+Right) = switchInDirection(right)\n keystroke(Control+Alt+Left) = switchInDirection(left)\nend\n")) throw new Exception("Hotkey syntax changed");
            var meter = new ShareProgress(); meter.Reset(); var t0 = DateTime.UtcNow;
            string first = meter.Describe("[2026-11-12T10:00:00] INFO: file clipboard: progress sent 1048576 bytes", t0.AddSeconds(1));
            string second = meter.Describe("[2026-11-12T10:00:01] INFO: file clipboard: progress received 3145728 bytes", t0.AddSeconds(2));
            if (first == null || !first.Contains("1.0 MB") || second == null || !second.StartsWith("正在接收") || !second.Contains("3.0 MB") || !second.Contains("MB/s") || meter.Describe("file clipboard: sent 5 bytes", t0) != null)
                throw new Exception("Transfer progress parsing failed: " + first + " / " + second);
            ShareLogin.Name = "BarrierShare-SelfTest-" + Guid.NewGuid().ToString("N");
            try {
                ShareLogin.Enabled = true;
                if (!ShareLogin.Enabled || ShareLogin.ReadValue() != ShareLogin.Command || !ShareLogin.Command.EndsWith("\" --background")) throw new Exception("Launch-at-login entry not written");
                ShareLogin.Enabled = false;
                if (ShareLogin.Enabled) throw new Exception("Launch-at-login entry not removed");
            } finally { ShareLogin.Enabled = false; ShareLogin.Name = "BarrierShare"; }
            // Every advanced option at once; the hidden backend below must accept the resulting file.
            ShareSettings.Advanced = new ShareAdvanced { SwitchDelay = 250, DoubleTap = 300, Corners = true, CornerSize = 24, SwapModifiers = true, RelativeMouse = true, ScreenSaver = false, SwitchKeys = true, LockKey = true,
                Targets = "10.8.0.5, office-pc.local", Extra = "# comment\r\nkeystroke(Control+Alt+F12) = switchToScreen(windows)\r\n" };
            string full = ShareSettings.Config(true);
            foreach (string expected in new[] { " windows:\n  ctrl = super\n  super = ctrl\n", " switchDelay = 250\n", " switchDoubleTap = 300\n", " switchCorners = all\n switchCornerSize = 24\n", " relativeMouseMoves = true\n", " screenSaverSync = false\n", " keystroke(Control+Alt+L) = lockCursorToScreen(toggle)\n", " keystroke(Control+Alt+F12) = switchToScreen(windows)\nend\n" })
                if (!full.Contains(expected)) throw new Exception("Advanced option missing from config: " + expected.Trim() + "\n" + full);
            if (full.Contains("# comment") || ShareSettings.Advanced.TargetList() != "10.8.0.5,office-pc.local") throw new Exception("Advanced extras were not normalized");
            if (!ShareAdvanced.FromXml(null).SwapModifiers || !ShareAdvanced.FromXml(new XElement("advanced")).SwapModifiers || ShareAdvanced.FromXml(new XElement("advanced", new XAttribute("swapModifiers", false))).SwapModifiers) throw new Exception("Ctrl/Command swap is not on by default or ignores a saved choice");
            ShareSettings.Save(true, ""); var savedAdvanced = ShareSettings.Advanced; ShareSettings.Load(out host, out address);
            if (ShareSettings.Advanced.SwitchDelay != 250 || !ShareSettings.Advanced.LockKey || ShareSettings.Advanced.ScreenSaver || ShareSettings.Advanced.Extra != savedAdvanced.Extra.Replace("\r\n", "\n") && ShareSettings.Advanced.Extra != savedAdvanced.Extra) throw new Exception("Advanced settings roundtrip failed");
            foreach (string bad in new[] { "end", "section: links" }) {
                bool refused = false; try { new ShareAdvanced { Extra = bad }.ExtraLines().ToList(); } catch (IOException) { refused = true; }
                if (!refused) throw new Exception("Section boundary accepted in extra settings: " + bad);
            }
            bool badTarget = false; try { new ShareAdvanced { Targets = "1.2.3.4 & calc" }.TargetList(); } catch (IOException) { badTarget = true; }
            if (!badTarget) throw new Exception("Invalid direct address accepted");
            // Three receivers: one in the default spot, one placed on the grid, one placed automatically.
            string fa = "v2:sha256:" + new string('a', 64), fb = "v2:sha256:" + new string('b', 64), fc = "v2:sha256:" + new string('c', 64);
            ShareSettings.Receivers = new List<string> { fa, fb, fc }; ShareSettings.Layout = new Dictionary<string, Point> { { fb, new Point(0, -1) } };
            ShareSettings.Platforms = new Dictionary<string, string> { { fb, "mac" }, { fa, "windows" } };
            string multi = ShareSettings.Config(true); string na = ShareSettings.ScreenName(fa), nb = ShareSettings.ScreenName(fb), nc = ShareSettings.ScreenName(fc);
            foreach (string expected in new[] { " windows-host:\n  right = " + na + "\n  left = " + nc + "\n  up = " + nb + "\n", " " + na + ":\n  left = windows-host\n", " " + nb + ":\n  down = windows-host\n",
                "section: aliases\n " + na + ":\n  windows\nend\n", " " + nb + ":\n  ctrl = super\n  super = ctrl\n", "switchInDirection(up)", "switchInDirection(down)" })
                if (!multi.Contains(expected)) throw new Exception("Multi-screen config missing: " + expected + "\n" + multi);
            // A Windows receiver (fa) and one of unknown system (fc) keep their keys.
            if (multi.Contains(" " + na + ":\n  ctrl = super") || multi.Contains(" " + nc + ":\n  ctrl = super")) throw new Exception("Ctrl/Command swapped for a Windows receiver\n" + multi);
            ShareSettings.Save(true, ""); ShareSettings.Load(out host, out address);
            if (ShareSettings.Layout.Count != 1 || ShareSettings.Layout[fb] != new Point(0, -1)) throw new Exception("Screen layout roundtrip failed");
            ShareSettings.OwnFingerprint = fc;
            if (!String.Join(" ", ShareSettings.Backend(false, "192.168.1.2").Arguments).Contains("\"--name\" \"" + nc + "\"")) throw new Exception("Receiver does not use its own screen name");
            ShareSettings.OwnFingerprint = null;
            using (var core = Process.Start(ShareSettings.Backend(true, ""))) {
                Thread.Sleep(1500);
                if (core.HasExited) throw new Exception("Hidden backend failed: " + core.StandardError.ReadToEnd());
                if (core.MainWindowHandle != IntPtr.Zero) throw new Exception("Backend opened a console");
                core.Kill(); core.WaitForExit(5000);
            }
            string releases = "[{\"tag_name\":\"mac-v9.0.0\",\"html_url\":\"https://github.com/sunnylinisme/barrier/releases/tag/mac-v9.0.0\",\"draft\":false,\"prerelease\":false}," +
                "{\"tag_name\":\"windows-v0.4.0\",\"html_url\":\"https://github.com/sunnylinisme/barrier/releases/tag/windows-v0.4.0\",\"draft\":true,\"prerelease\":false}," +
                "{\"tag_name\":\"windows-v0.3.9\",\"html_url\":\"https://github.com/sunnylinisme/barrier/releases/tag/windows-v0.3.9\",\"draft\":false,\"prerelease\":false}," +
                "{\"tag_name\":\"windows-v0.3.8\",\"html_url\":\"https://github.com/sunnylinisme/barrier/releases/tag/windows-v0.3.8\",\"draft\":false,\"prerelease\":false}," +
                "{\"tag_name\":\"windows-v0.3.10\",\"html_url\":\"https://example.com/elsewhere\",\"draft\":false,\"prerelease\":false}," +
                "{\"tag_name\":\"v0.5.0\",\"html_url\":\"https://github.com/sunnylinisme/barrier/releases/tag/v0.5.0\",\"draft\":true,\"prerelease\":false}," +
                "{\"tag_name\":\"v0.3.11\",\"html_url\":\"https://github.com/sunnylinisme/barrier/releases/tag/v0.3.11\",\"draft\":false,\"prerelease\":false}]";
            var found = ShareUpdate.Newer(releases, new Version(0, 3, 7));
            if (found == null || found.Version != new Version(0, 3, 11) || !found.Url.EndsWith("/v0.3.11")) throw new Exception("Update selection ignored platform, draft or origin rules");
            var legacy = ShareUpdate.Newer(releases.Replace("\"v0.3.11\"", "\"x0.3.11\""), new Version(0, 3, 7));
            if (legacy == null || !legacy.Url.EndsWith("/windows-v0.3.9")) throw new Exception("Update selection dropped legacy Windows releases");
            if (ShareUpdate.Newer(releases, new Version(0, 3, 11)) != null || ShareUpdate.Newer("{\"message\":\"rate limited\"}", ShareUpdate.Current) != null) throw new Exception("Update reported without a newer release");
            using (var window = new ShareWindow(true)) {
                window.Show(); Application.DoEvents(); window.TestDiscovery(directory);
                window.ShowUpdate(found); Application.DoEvents();
                using (var bitmap = new Bitmap(window.Width, window.Height)) { window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size)); bitmap.Save(Path.Combine(directory, "gui-update.png")); }
                Func<ShareAdvanced> readAdvanced;
                using (var advanced = window.BuildAdvanced(ShareSettings.Advanced, out readAdvanced)) {
                    advanced.Show(); Application.DoEvents();
                    var shown = advanced.Controls.Cast<Control>().Where(c => c.Visible).ToArray();
                    for (int i = 0; i < shown.Length; ++i) {
                        if (!advanced.DisplayRectangle.Contains(shown[i].Bounds)) throw new Exception("Advanced dialog clips: " + shown[i].Text);
                        for (int j = i + 1; j < shown.Length; ++j) if (shown[i].Bounds.IntersectsWith(shown[j].Bounds)) throw new Exception("Advanced dialog overlaps: " + shown[i].Text + " / " + shown[j].Text);
                    }
                    if (readAdvanced().SwitchDelay != 250 || !readAdvanced().SwapModifiers) throw new Exception("Advanced dialog lost values");
                    using (var bitmap = new Bitmap(advanced.Width, advanced.Height)) { advanced.DrawToBitmap(bitmap, new Rectangle(Point.Empty, advanced.Size)); bitmap.Save(Path.Combine(directory, "gui-advanced.png")); }
                    advanced.Close();
                }
                ShareSettings.Receivers = new List<string> { fa, fb, fc }; ShareSettings.Layout = new Dictionary<string, Point> { { fb, new Point(0, -1) } };
                using (var layout = new ShareLayoutEditor(new Dictionary<string, string> { { fa, "書房 Windows" }, { fb, "MacBook Air" }, { fc, "客廳電腦" } }, window.Font)) {
                    layout.Show(); Application.DoEvents();
                    if (!layout.Reachable() || layout.Placement[fb] != new Point(0, -1)) throw new Exception("Layout editor did not start from the saved arrangement");
                    if (layout.Place(fc, new Point(1, 0)) || !layout.Place(fc, new Point(2, 2)) || layout.Reachable()) throw new Exception("Layout editor accepted an occupied cell or a detached screen");
                    if (!layout.Place(fc, new Point(-1, 0)) || !layout.Reachable()) throw new Exception("Layout editor rejected a valid arrangement");
                    using (var bitmap = new Bitmap(layout.Width, layout.Height)) { layout.DrawToBitmap(bitmap, new Rectangle(Point.Empty, layout.Size)); bitmap.Save(Path.Combine(directory, "gui-layout.png")); }
                    layout.Close();
                }
                ShareSettings.Receivers = new List<string>(); ShareSettings.Layout = new Dictionary<string, Point>();
                using (var transfer = new ShareTransferPopup(window.Font)) {
                    transfer.Begin(false); Application.DoEvents();
                    if (transfer.Visible) throw new Exception("Transfer window appeared before one second");
                    transfer.ShowNow(); transfer.Progress("已收 3.0 MB · 1.4 MB/s"); Application.DoEvents();
                    if (!transfer.Visible || !transfer.Busy || transfer.Heading != "正在接收檔案…" || transfer.Detail != "已收 3.0 MB · 1.4 MB/s" || !transfer.Topmost || transfer.ShowInTaskbar || Form.ActiveForm == transfer) throw new Exception("Transfer window progress state wrong (or it took the focus)");
                    using (var bitmap = new Bitmap(transfer.Width, transfer.Height)) { transfer.DrawToBitmap(bitmap, new Rectangle(Point.Empty, transfer.Size)); bitmap.Save(Path.Combine(directory, "gui-transfer.png")); }
                    transfer.Finish("已收到檔案", "已自動貼上"); Application.DoEvents();
                    if (!transfer.Visible || transfer.Busy || transfer.Heading != "已收到檔案") throw new Exception("Transfer window result state wrong");
                    using (var bitmap = new Bitmap(transfer.Width, transfer.Height)) { transfer.DrawToBitmap(bitmap, new Rectangle(Point.Empty, transfer.Size)); bitmap.Save(Path.Combine(directory, "gui-transfer-done.png")); }
                    transfer.Begin(false); transfer.MarkAutoPaste(); transfer.Progress("已收 4.0 MB"); transfer.MarkAutoPaste();
                    if (transfer.Heading != "正在接收檔案…（傳完自動貼上）") throw new Exception("Auto-paste note missing or repeated: " + transfer.Heading);
                    // Receiving alone never shows the popup; a paste shows it at once with the latest progress.
                    transfer.Dismiss(); transfer.Prepare(); transfer.Progress("已收 5.0 MB · 2.0 MB/s"); Application.DoEvents();
                    if (transfer.Visible) throw new Exception("Transfer popup shown without a paste");
                    transfer.ShowForPaste(); Application.DoEvents();
                    if (!transfer.Visible || transfer.Heading != "正在接收檔案…（傳完自動貼上）" || transfer.Detail != "已收 5.0 MB · 2.0 MB/s") throw new Exception("Paste did not show the popup with the latest progress");
                    transfer.Dismiss(); transfer.Begin(true); transfer.Finish("檔案已送出", "可在另一台貼上"); Application.DoEvents();
                    if (transfer.Visible) throw new Exception("Result shown for a transfer whose window never appeared");
                }
                // Auto-paste: nothing pressed -> no paste; same window still focused -> paste; focus moved -> no paste.
                IntPtr explorer = new IntPtr(0x1234), other = new IntPtr(0x5678);
                if (ShareAutoPaste.ShouldPaste(IntPtr.Zero, explorer) || !ShareAutoPaste.ShouldPaste(explorer, explorer) || ShareAutoPaste.ShouldPaste(explorer, other)) throw new Exception("Auto-paste decision wrong");
                using (var paste = new ShareAutoPaste()) {
                    int requests = 0; paste.Requested += delegate { ++requests; };
                    paste.Record(explorer); paste.Record(other);
                    if (paste.Target != explorer || requests != 1) throw new Exception("Auto-paste did not keep only the first paste");
                    paste.Clear(); if (paste.Target != IntPtr.Zero) throw new Exception("Auto-paste record not cleared");
                    // The real hook must see an injected Ctrl+V, the way keys from the other computer arrive.
                    using (var target = new Form { Text = "auto-paste target", ShowInTaskbar = false }) {
                        target.Show(); target.Activate(); Application.DoEvents();
                        var notes = new List<string>(); paste.Note += notes.Add;
                        paste.Start(); ShareAutoPaste.SendPaste();
                        var until = DateTime.UtcNow.AddSeconds(2);
                        while (!notes.Any(n => n.Contains("偵測到 Ctrl+V") || n.Contains("自己的視窗")) && DateTime.UtcNow < until) { Application.DoEvents(); Thread.Sleep(20); }
                        paste.Stop();
                        if (!notes.Any(n => n.Contains("已安裝鍵盤 hook")) || !notes.Any(n => n.Contains("偵測到 Ctrl+V"))) throw new Exception("Keyboard hook did not see an injected Ctrl+V: " + String.Join(" | ", notes));
                        // The test window belongs to this process; a paste into Barrier Share's own windows is never repeated.
                        if (notes.Any(n => n.Contains(target.Handle.ToInt64().ToString("X"))) && paste.Target != IntPtr.Zero) throw new Exception("Own window recorded as paste target");
                        File.WriteAllText(Path.Combine(directory, "AUTOPASTE.txt"), String.Join(Environment.NewLine, notes));
                        target.Close();
                    }
                }
                window.ShowUpdate(null);
                using (var bitmap = new Bitmap(window.Width, window.Height)) { window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size)); bitmap.Save(Path.Combine(directory, "gui.png")); }
                window.Close();
            }
            File.WriteAllText(Path.Combine(directory, "PASS.txt"), "Settings persist; old pairing and trust preserved; hidden backend starts/stops; GUI states render with accessible, unclipped controls; update notice selects only newer published Windows releases; switch hotkeys, transfer progress and the launch-at-login entry work.");
            return 0;
        } catch (Exception e) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "FAIL.txt"), e.ToString()); return 1; }
    }
}
