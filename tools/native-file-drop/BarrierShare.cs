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

[assembly: System.Reflection.AssemblyVersion("0.3.9.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.3.9.0")]

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
    public bool Primary;
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
    public override string ToString() { return Name + "  ·  " + Address; }
}
sealed class ShareWindow : Form
{
    readonly ShareComboBox role = new ShareComboBox(), position = new ShareComboBox(), nearby = new ShareComboBox();
    readonly Label positionHint = new Label(), status = new Label(), peerLabel = new Label(), emptyNearby = new Label(), network = new Label();
    readonly LinkLabel update = new LinkLabel();
    readonly System.Windows.Forms.Timer updateTimer = new System.Windows.Forms.Timer { Interval = 24 * 60 * 60 * 1000 };
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
    bool closing, loading = true, enabled = true, discoveryReady, started, transferring, keepServiceCore;
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
        c.Bounds=bounds; Controls.Add(c); c.BringToFront();
        if (c is ShareCard) { c.TabIndex=cards.Count; cards.Add((ShareCard)c); }
    }
    void LabelAt(string text, int x, int y, int width) { At(new Label { Text = text }, x, y, width, 26); }
    public ShareWindow(bool selfTest = false)
    {
        SuspendLayout();
        testing = selfTest; Text = "Barrier Share " + ShareUpdate.Label;
        Font = new Font("Microsoft JhengHei UI", 11F); AutoScaleDimensions=new SizeF(96F,96F); AutoScaleMode=AutoScaleMode.Dpi;
        ClientSize = new Size(800, 654); BackColor = ShareStyle.Background; ForeColor = ShareStyle.Ink;
        AutoScroll=true; AutoScrollMinSize=ClientSize;
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen; Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        At(new Label { Text = "Barrier Share", Font = new Font("Segoe UI", 24F, FontStyle.Bold), ForeColor = ShareStyle.Ink }, 24, 20, 520, 44);
        At(new Label { Text = "同一張桌面，連上兩台電腦。", ForeColor = ShareStyle.Muted }, 26, 68, 600, 26);
        network.Text = "●  區域網路"; network.ForeColor = ShareStyle.Blue; network.Font = new Font(Font.FontFamily,10F); network.TextAlign = ContentAlignment.MiddleRight; At(network, 620, 34, 156, 30);
        update.Font = new Font(Font.FontFamily,10F,FontStyle.Bold); update.TextAlign = ContentAlignment.MiddleRight; update.LinkColor = update.ActiveLinkColor = ShareStyle.Blue; update.Visible = false; update.TabIndex = 7; At(update, 552, 34, 224, 30);
        update.LinkClicked += delegate { if (updateUrl != null) try { Process.Start(new ProcessStartInfo(updateUrl) { UseShellExecute = true }); } catch (Exception e) { Error(e); } };
        foreach (var bounds in new[] { new Rectangle(24,108,752,108), new Rectangle(24,232,444,244), new Rectangle(484,232,292,244), new Rectangle(24,492,752,92) }) At(new ShareCard(),bounds.X,bounds.Y,bounds.Width,bounds.Height);
        At(new ComputerMark { BackColor = Color.White },44,138,48,48);
        At(new Label { Text = "這台電腦", BackColor = Color.White, ForeColor = ShareStyle.Muted, Font = new Font(Font.FontFamily,10F) },108,125,280,24);
        At(new Label { Text = Environment.MachineName, BackColor = Color.White, Font = new Font(Font.FontFamily,16F,FontStyle.Bold), AutoEllipsis = true },108,153,288,36);
        At(new Label { Text = "角色", BackColor = Color.White, ForeColor = ShareStyle.Muted, Font=new Font(Font.FontFamily,10F) },432,125,320,24);
        At(role,432,151,320,42); role.AccessibleName="這台電腦的角色"; role.TabIndex=0;
        role.Items.AddRange(new object[] { "主控端 · 使用這台的鍵盤滑鼠", "接收端 · 等待主控端邀請" });
        At(new Label { Text = "附近電腦", BackColor = Color.White, Font = new Font(Font.FontFamily,13F,FontStyle.Bold) },44,252,260,30);
        search.Text = "重新搜尋"; search.BackColor = Color.White; search.Font=new Font(Font.FontFamily,10F); At(search,336,248,108,36); search.TabIndex=0;
        At(nearby,44,305,400,42); nearby.AccessibleName="附近的電腦"; nearby.TabIndex=1; nearby.DropDownWidth=500;
        emptyNearby.Text = "正在尋找附近的電腦…\r\n請在另一台開啟程式，並選擇另一個角色。"; emptyNearby.BackColor=Color.White; emptyNearby.ForeColor=ShareStyle.Muted; At(emptyNearby,44,303,400,64);
        At(new Label { Text = "首次連線需核對短碼，並由雙方同意。", BackColor = Color.White, ForeColor = ShareStyle.Muted, Font=new Font(Font.FontFamily,10F) },44,375,400,26);
        pair.Text = "邀請配對  →"; pair.BackColor=Color.White; pair.Font = new Font(Font.FontFamily,11F,FontStyle.Bold); At(pair,44,416,400,40); pair.TabIndex=2;
        At(new Label { Text = "連線狀態", BackColor = Color.White, Font = new Font(Font.FontFamily,13F,FontStyle.Bold) },504,252,252,30);
        status.BackColor = Color.White; status.ForeColor = ShareStyle.Blue; status.Font = new Font(Font.FontFamily,12F,FontStyle.Bold); At(status,504,305,252,76);
        peerLabel.BackColor=Color.White; peerLabel.ForeColor=ShareStyle.Muted; peerLabel.AutoEllipsis=true; peerLabel.Font=new Font(Font.FontFamily,10F); At(peerLabel,504,382,252,38);
        start.Text = "恢復連線"; stop.Text = "暫停"; start.BackColor=stop.BackColor=Color.White; At(start,504,422,148,34); At(stop,664,422,92,34); start.TabIndex=0; stop.TabIndex=1;
        At(new Label { Text="螢幕位置", BackColor=Color.White, Font=new Font(Font.FontFamily,13F,FontStyle.Bold) },44,511,184,30);
        At(new Label { Text="游標從哪一側移過去", BackColor=Color.White, ForeColor=ShareStyle.Muted, Font=new Font(Font.FontFamily,10F) },44,544,200,24);
        At(position,260,516,340,42); position.AccessibleName="接收端的螢幕位置"; position.TabIndex=0;
        arrange.Text="排列螢幕…"; arrange.BackColor=Color.White; arrange.Font=new Font(Font.FontFamily,10F); arrange.TabIndex=1; At(arrange,612,516,140,42); arrange.Click += delegate { ShowLayout(); };
        position.Items.AddRange(new object[] { "接收端在右邊  →", "接收端在左邊  ←", "接收端在上方  ↑", "接收端在下方  ↓" }); position.SelectedIndex=0;
        positionHint.Text="由主控端設定兩台螢幕的相對位置"; positionHint.BackColor=Color.White; positionHint.ForeColor=ShareStyle.Muted; At(positionHint,260,522,340,42);
        forget.Text="解除配對"; clear.Text="清除暫存"; forget.BackColor=clear.BackColor=ShareStyle.Background; forget.Font=clear.Font=new Font(Font.FontFamily,10F); At(forget,24,602,108,36); At(clear,144,602,108,36); forget.TabIndex=4; clear.TabIndex=5;
        var diagnosticButton = new ShareButton { Text="診斷紀錄", BackColor=ShareStyle.Background, Font=new Font(Font.FontFamily,10F), TabIndex=6 }; At(diagnosticButton,656,602,120,36); diagnosticButton.Click += delegate { ShowDiagnostics(); };
        autostart.Text="登入時自動啟動"; autostart.BackColor=ShareStyle.Background; autostart.Font=new Font(Font.FontFamily,10F); autostart.TabIndex=5; At(autostart,272,602,170,36);
        try { autostart.Checked = !selfTest && ShareLogin.Enabled; } catch (Exception) { }
        autostart.CheckedChanged += delegate { if (!testing) try { ShareLogin.Enabled = autostart.Checked; } catch (Exception e) { Error(e); } };
        var advancedButton = new ShareButton { Text="進階設定", BackColor=ShareStyle.Background, Font=new Font(Font.FontFamily,10F), TabIndex=6 }; At(advancedButton,524,602,120,36); advancedButton.Click += delegate { ShowAdvanced(); };
        details.Multiline=true; details.ReadOnly=true; details.ScrollBars=ScrollBars.Vertical; details.Font=new Font("Consolas",9F); details.BackColor=Color.FromArgb(249,251,255); details.BorderStyle=BorderStyle.None;
        var menu = new ContextMenuStrip(); menu.Items.Add("開啟視窗", null, delegate { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("結束", null, delegate { closing = true; Close(); }); tray.Icon = Icon; tray.Text = "Barrier Share " + ShareUpdate.Label; tray.ContextMenuStrip = menu; tray.Visible = !testing;
        tray.DoubleClick += delegate { Show(); WindowState = FormWindowState.Normal; Activate(); };
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
        pair.Click += delegate { var peer = nearby.SelectedItem as NearbyDevice; if (peer != null) { StopBackend(); Send("PAIR\t" + peer.Fingerprint); status.Text = "正在發出邀請…"; } };
        forget.Click += delegate {
            if (peers.Count > 1) {
                // Several receivers: choose one, or all of them.
                var choices = new ContextMenuStrip();
                foreach (var peer in peers.ToList()) { string fp = peer.Key; choices.Items.Add("解除「" + peer.Value + "」", null, delegate { Forget("FORGET\t" + fp, "解除與「" + peers[fp] + "」的配對？"); }); }
                choices.Items.Add(new ToolStripSeparator()); choices.Items.Add("全部解除", null, delegate { Forget("FORGET", "解除所有配對？"); });
                choices.Show(forget, new Point(0, forget.Height)); return;
            }
            Forget("FORGET", "解除後不會自動連線，需要重新邀請並經對方同意。");
        };
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
            if (!closing && !testing) { e.Cancel = true; Hide(); tray.ShowBalloonTip(1500, "Barrier Share", "程式已收至系統匣；可從圖示開啟或結束。", ToolTipIcon.Info); return; }
            closing = true; retry.Stop(); updateTimer.Stop(); StopLink(); StopBackend(); autoPaste.Dispose(); popup.Dismiss(); popup.Dispose(); tray.Dispose();
        };
    }
    // Runs once, on first show or right away for a hidden sign-in launch.
    void Startup()
    {
        if (started) return; started = true; Diagnose(ShareUpdate.Details);
        if (!testing) { ShareCursor.Restore(); ShareLogin.Refresh(); }
        try {
            ShareSettings.Import(ShareSettings.Bin, true, false); ShareSettings.Import(ShareSettings.Bin, false, false);
            bool host; string ip; ShareSettings.Load(out host, out ip); role.SelectedIndex = host ? 0 : 1; address.Text = ip; position.SelectedIndex = Array.IndexOf(ShareSettings.Directions, ShareSettings.Position);
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
    void Error(Exception e) { status.Text = "操作未完成：" + e.Message; }
    // Offline or rate-limited checks stay silent; the local network connection never depends on them.
    void CheckUpdate()
    {
        Task.Factory.StartNew(() => ShareUpdate.Check()).ContinueWith(task => {
            if (closing || !IsHandleCreated) return;
            try { BeginInvoke((Action)delegate { if (task.Status == TaskStatus.RanToCompletion) ShowUpdate(task.Result); else LogLine("檢查更新失敗：" + task.Exception.GetBaseException().Message); }); }
            catch (InvalidOperationException) { }
        });
    }
    internal void ShowUpdate(ShareUpdate.Found found)
    {
        update.Visible = found != null; network.Visible = found == null;
        if (found == null) return;
        updateUrl = found.Url; update.Text = "有新版 " + found.Version + "，前往下載 ↗";
        string version = found.Version.ToString();
        if (announcedUpdate != version && !testing) { announcedUpdate = version; tray.ShowBalloonTip(5000, "Barrier Share 有新版", "版本 " + version + " 已發布。從視窗右上角前往下載；安裝程式會自動關閉並重新開啟 Barrier Share。", ToolTipIcon.Info); }
    }
    void Save() { try { ShareSettings.Save(Host, address.Text.Trim()); } catch (Exception e) { Error(e); } }
    void UpdateControls()
    {
        transferring &= backend != null; start.Text = transferring ? "取消傳送" : "恢復連線";
        start.Enabled = transferring || !enabled || link == null; stop.Enabled = enabled;
        status.ForeColor = enabled ? ShareStyle.Blue : ShareStyle.Muted;
        emptyNearby.Text = !enabled ? "搜尋已暫停\r\n恢復連線後，會重新尋找附近電腦。" : Host ? "正在尋找接收端…\r\n請在另一台選擇「接收端」，保持程式開啟。" : "尚未找到主控端。\r\n請在另一台選擇「主控端」，發出配對邀請。";
        nearby.Visible = nearby.Items.Count > 0; emptyNearby.Visible = !nearby.Visible; pair.Text = Host ? "邀請配對  →" : "等待主控端邀請";
        search.Enabled = link != null; pair.Enabled = Host && link != null && nearby.SelectedItem != null && consent == null;
        forget.Enabled = link != null && peers.Count != 0; clear.Enabled = !enabled && backend == null;
    }
    void RefreshRole()
    {
        peers.Clear(); PeersChanged(); devices.Clear(); nearby.Items.Clear(); Save();
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
        devices.Clear(); nearby.Items.Clear(); UpdateControls();
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
            NearbyDevice device; string selected = nearby.SelectedItem is NearbyDevice ? ((NearbyDevice)nearby.SelectedItem).Fingerprint : "";
            if (!devices.TryGetValue(f[1], out device)) { device = new NearbyDevice { Fingerprint = f[1] }; devices[f[1]] = device; }
            device.Name = Decode(f[2]); device.Address = f[3]; nearby.Items.Clear();
            foreach (var value in devices.Values) nearby.Items.Add(value);
            if (devices.ContainsKey(selected)) nearby.SelectedItem = devices[selected]; else if (nearby.Items.Count > 0) nearby.SelectedIndex = 0;
        } else if (f[0] == "PLATFORM" && f.Length == 3) {
            // A receiver's system decides the key mapping; restart the host core when it changes.
            string known;
            if (!ShareSettings.Platforms.TryGetValue(f[1], out known) || known != f[2]) {
                ShareSettings.Platforms[f[1]] = f[2]; Save(); LogLine("對方系統：" + f[2] + " · " + f[1].Substring(10, 16));
                if (Host && peers.ContainsKey(f[1]) && backend != null) StopBackend();
            }
        } else if (f[0] == "GONE" && f.Length == 2) { NearbyDevice device; if (devices.TryGetValue(f[1], out device)) { nearby.Items.Remove(device); devices.Remove(f[1]); } }
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
        var dialog = new Form { Text = message[0] == "REQUEST" ? "收到配對邀請" : "核對配對碼", ClientSize = new Size(500, 310), BackColor = Color.White, ForeColor = ShareStyle.Ink, Font = Font, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false, AutoScaleDimensions=new SizeF(96F,96F), AutoScaleMode=AutoScaleMode.Dpi };
        consent = dialog;
        var explanation = new Label { Text = Decode(message[2]) + "\r\n請確認另一台顯示相同的 6 位數配對碼。", Bounds = new Rectangle(24, 18, 452, 58) };
        var code = new Label { Text = message[4], ForeColor = ShareStyle.Blue, Font = new Font("Consolas", 34F, FontStyle.Bold), Bounds = new Rectangle(24, 82, 452, 60), TextAlign = ContentAlignment.MiddleCenter };
        var permission = new Label { Text = "同意後允許共用鍵盤滑鼠及雙向同步剪貼簿。\r\n配對會被記住，之後自動連線。", Bounds = new Rectangle(24, 150, 452, 55) };
        var reject = new ShareButton { Text = "拒絕", BackColor=Color.White, Bounds = new Rectangle(24, 248, 140, 40), DialogResult = DialogResult.Cancel };
        var accept = new ShareButton { Text = "相同，同意", Primary=true, BackColor=Color.White, Bounds = new Rectangle(176, 248, 300, 40), DialogResult = DialogResult.OK };
        dialog.Controls.AddRange(new Control[] { explanation, code, permission, reject, accept }); dialog.CancelButton = reject; dialog.AcceptButton = reject;
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
        var process = backend; backend = null;
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
        if (line.Contains("connected to server") || line.Contains("has connected")) status.Text = "已連線 · 雙向複製貼上已啟用";
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
            diagnostics.FormClosing += delegate(object sender, FormClosingEventArgs e) { if (!closing) { e.Cancel=true; diagnostics.Hide(); } };
        }
        diagnostics.Show(this); diagnostics.Activate();
    }
    internal void TestDiscovery(string directory)
    {
        Action<string> capture = delegate(string filename) {
            Application.DoEvents(); Refresh();
            foreach (var selector in new ComboBox[] { role, position, nearby }) {
                if (String.IsNullOrWhiteSpace(selector.AccessibilityObject.Name) || selector.DropDownStyle != ComboBoxStyle.DropDownList)
                    throw new Exception("Native selector is missing its accessible name or list behavior");
                if (selector.Height < selector.Font.Height + selector.Font.Height / 2 || selector.ItemHeight < selector.Font.Height)
                    throw new Exception("Selector clips its text or has insufficient vertical spacing: " + selector.AccessibleName);
                if (!(selector.Parent is ShareCard) || !selector.Parent.ClientRectangle.Contains(selector.Bounds))
                    throw new Exception("Selector extends beyond its visible card: " + selector.AccessibleName);
            }
            foreach (var container in new Control[] { this }.Concat(cards.Cast<Control>())) {
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
        if (role.Items.Count != 2 || position.Items.Count != ShareSettings.Directions.Length) throw new Exception("Role or position choices are incomplete");
        // UI-only discovery fixture: no input capture or network service starts here.
        link = new Process(); LinkLine("READY");
        if (nearby.Visible || !emptyNearby.Visible || pair.Enabled) throw new Exception("Empty discovery state offers an unavailable peer");
        capture("gui-empty.png");
        string fp = "v2:sha256:" + new string('a', 64), name = Convert.ToBase64String(Encoding.UTF8.GetBytes("另一台電腦"));
        LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.2\t24801\tR");
        LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.3\t24801\tR");
        if (nearby.Items.Count != 1 || ((NearbyDevice)nearby.Items[0]).Address != "192.168.1.3") throw new Exception("Discovery list update failed");
        LinkLine("SAVED\t" + fp + "\t" + name);
        using (var timer = new System.Windows.Forms.Timer { Interval = 250 }) {
            timer.Tick += delegate {
                timer.Stop();
                using (var bitmap = new Bitmap(consent.Width, consent.Height)) { consent.DrawToBitmap(bitmap, new Rectangle(Point.Empty, consent.Size)); bitmap.Save(Path.Combine(directory, "gui-pairing.png")); }
                LinkLine("CLOSED\ttest-request");
            };
            timer.Start(); LinkLine("VERIFY\ttest-request\t" + name + "\t" + fp + "\t123456");
        }
        if (consent != null || consentId != null) throw new Exception("Expired pairing dialog remained open");
        LinkLine("GONE\t" + fp); if (nearby.Items.Count != 0) throw new Exception("Offline peer remained listed");
        peers.Clear(); PeersChanged(); LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.3\t24801\tR");
        peerLabel.Text="對方同意後，會記住這台電腦。"; status.Text="找到附近電腦\r\n可以發出配對邀請";
        if (!nearby.Visible || emptyNearby.Visible || !pair.Enabled) throw new Exception("Available peer cannot be invited");
        capture("gui-available.png");
        string longName = Convert.ToBase64String(Encoding.UTF8.GetBytes("工作室的 Windows 11 筆記型電腦 — Design review and shared files workstation"));
        LinkLine("DEVICE\t" + fp + "\t" + longName + "\t192.168.1.3\t24801\tR");
        capture("gui-long-name.png");
        role.SelectedIndex = 1; link = new Process(); LinkLine("READY");
        if (position.Visible || !positionHint.Visible || pair.Enabled) throw new Exception("Receiver offers host-only actions");
        capture("gui-receiver.png");
        stop.PerformClick();
        if (!start.Enabled || stop.Enabled || pair.Enabled || !clear.Enabled) throw new Exception("Paused state exposes active connection controls");
        capture("gui-paused.png");
        role.SelectedIndex = 0; enabled = true; link = new Process(); LinkLine("READY");
        LinkLine("DEVICE\t" + fp + "\t" + name + "\t192.168.1.3\t24801\tR");
        peerLabel.Text="對方同意後，會記住這台電腦。"; status.Text="找到附近電腦\r\n可以發出配對邀請";
        using (var graphics = CreateGraphics()) File.WriteAllText(Path.Combine(directory, "LAYOUT-PASS.txt"),
            "Empty, available, long-name, receiver and paused states rendered; accessible native selectors fit their cards with no visible sibling overlap. Actual render DPI: " + graphics.DpiX + " x " + graphics.DpiY + ". No simulated or physical multi-DPI claim.");
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
        if (names.Count == 1) peerLabel.Text = "已配對 · " + names[0] + "\r\n重新開啟後會自動連線";
        else if (names.Count > 1) peerLabel.Text = "已配對 " + names.Count + " 台 · " + String.Join("、", names);
        else peerLabel.Text = Host ? "選擇接收端，按「邀請配對」。" : "等待主控端邀請；首次需要你同意。";
        // Receivers are placed only through 排列螢幕, also when there is just one, so no second control can disagree with it.
        position.Visible = false; arrange.Visible = Host; arrange.Enabled = peers.Count > 0; positionHint.Visible = true;
        positionHint.Text = !Host ? "由主控端設定螢幕的相對位置" : peers.Count == 0 ? "配對接收端後，按「排列螢幕」設定位置" : "已配對 " + peers.Count + " 台；按「排列螢幕」調整位置";
        UpdateControls();
    }
    internal ShareLayoutEditor BuildLayout() { return new ShareLayoutEditor(peers, Font); }
    void ShowLayout()
    {
        using (var editor = BuildLayout()) {
            if (editor.ShowDialog(this) != DialogResult.OK) return;
            foreach (var item in editor.Placement) ShareSettings.Layout[item.Key] = item.Value;
            Save(); if (backend != null) StopBackend(); status.Text = "已儲存螢幕排列。";
        }
    }
    void SendTargets() { try { string list = ShareSettings.Advanced.TargetList(); if (list.Length > 0 || link != null) Send("TARGETS\t" + list); } catch (Exception e) { Error(e); } }
    // Host-side Barrier options plus direct addresses for computers on another subnet or VPN.
    internal Form BuildAdvanced(ShareAdvanced a, out Func<ShareAdvanced> read)
    {
        var dialog = new Form { Text = "進階設定", ClientSize = new Size(560, 600), BackColor = Color.White, ForeColor = ShareStyle.Ink, Font = new Font(Font.FontFamily, 10F), FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false, AutoScaleDimensions = new SizeF(96F, 96F), AutoScaleMode = AutoScaleMode.Dpi };
        int y = 18;
        Func<string, Label> note = text => { var l = new Label { Text = text, ForeColor = ShareStyle.Muted, Bounds = new Rectangle(24, y, 512, 24) }; dialog.Controls.Add(l); y += 28; return l; };
        Func<string, bool, CheckBox> check = (text, value) => { var c = new CheckBox { Text = text, Checked = value, Bounds = new Rectangle(24, y, 512, 28) }; dialog.Controls.Add(c); y += 32; return c; };
        Func<string, int, int, NumericUpDown> number = (text, value, max) => {
            dialog.Controls.Add(new Label { Text = text, Bounds = new Rectangle(24, y + 3, 380, 26) });
            var n = new NumericUpDown { Minimum = 0, Maximum = max, Value = Math.Min(max, Math.Max(0, value)), Increment = 50, Bounds = new Rectangle(416, y, 120, 28) }; dialog.Controls.Add(n); y += 36; return n;
        };
        note(Host ? "以下切換設定由這台（主控端）套用到兩台。" : "切換設定只在主控端生效；這台目前是接收端。");
        var delay = number("游標停在邊緣多久才切換（毫秒，0 = 立即）", a.SwitchDelay, 5000);
        var tap = number("輕敲兩下邊緣才切換（兩次間隔毫秒，0 = 關閉）", a.DoubleTap, 2000);
        var corners = check("螢幕四個角落不切換", a.Corners);
        var cornerSize = number("　角落範圍（像素）", a.CornerSize, 500); cornerSize.Increment = 4;
        var swap = check("Mac 接收端的 Ctrl 與 Command 鍵對調（兩台都是 Windows 時不會對調）", a.SwapModifiers);
        var relative = check("相對滑鼠移動（全螢幕遊戲用）", a.RelativeMouse);
        var saver = check("螢幕保護程式同步", a.ScreenSaver);
        var keys = check("Ctrl+Alt+方向鍵切換到另一台", a.SwitchKeys);
        var lockKey = check("Ctrl+Alt+L 把游標鎖在目前這台（再按一次解除）", a.LockKey);
        dialog.Controls.Add(new Label { Text = "其他網段或 VPN 的電腦（IP 或名稱，以逗號分隔）", Bounds = new Rectangle(24, y, 512, 24) }); y += 26;
        var targets = new TextBox { Text = a.Targets, Bounds = new Rectangle(24, y, 512, 28), AccessibleName = "其他網段的電腦" }; dialog.Controls.Add(targets); y += 38;
        dialog.Controls.Add(new Label { Text = "額外設定（Barrier 設定檔 options 語法，例如自訂快捷鍵）", Bounds = new Rectangle(24, y, 512, 24) }); y += 26;
        var extra = new TextBox { Text = a.Extra, Multiline = true, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9.5F), Bounds = new Rectangle(24, y, 512, 70), AccessibleName = "額外設定" }; dialog.Controls.Add(extra); y += 80;
        var cancel = new ShareButton { Text = "取消", BackColor = Color.White, Bounds = new Rectangle(24, y, 140, 38), DialogResult = DialogResult.Cancel };
        var ok = new ShareButton { Text = "儲存並套用", Primary = true, BackColor = Color.White, Bounds = new Rectangle(176, y, 360, 38) };
        dialog.Controls.AddRange(new Control[] { cancel, ok }); dialog.CancelButton = cancel; dialog.ClientSize = new Size(560, y + 56);
        read = () => new ShareAdvanced { SwitchDelay = (int)delay.Value, DoubleTap = (int)tap.Value, Corners = corners.Checked, CornerSize = (int)cornerSize.Value, SwapModifiers = swap.Checked,
            RelativeMouse = relative.Checked, ScreenSaver = saver.Checked, SwitchKeys = keys.Checked, LockKey = lockKey.Checked, Targets = targets.Text.Trim(), Extra = extra.Text };
        var reader = read;
        ok.Click += delegate {
            try { var value = reader(); value.TargetList(); value.ExtraLines().ToList(); dialog.DialogResult = DialogResult.OK; }
            catch (IOException e) { MessageBox.Show(dialog, e.Message, "進階設定"); }
        };
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
    const int Cell = 112, Tall = 68, Span = 2;
    public readonly Dictionary<string, Point> Placement = new Dictionary<string, Point>();
    readonly Dictionary<string, string> names = new Dictionary<string, string>();
    readonly Panel canvas = new Panel();
    readonly Label warning = new Label();
    readonly ShareButton save = new ShareButton { Text = "儲存排列", Primary = true };
    string dragging; Point pointer;
    public ShareLayoutEditor(Dictionary<string, string> peers, Font font)
    {
        Text = "排列螢幕"; Font = new Font(font.FontFamily, 10F); BackColor = Color.White; ForeColor = ShareStyle.Ink;
        FormBorderStyle = FormBorderStyle.FixedDialog; StartPosition = FormStartPosition.CenterParent; MaximizeBox = MinimizeBox = false;
        AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
        int width = Cell * (Span * 2 + 1), height = Tall * (Span * 2 + 1);
        ClientSize = new Size(width + 48, height + 168);
        Controls.Add(new Label { Text = "拖曳電腦到這台的上下左右；相鄰的邊就是游標可以移過去的地方。", Bounds = new Rectangle(24, 16, width, 40), ForeColor = ShareStyle.Muted });
        canvas.Bounds = new Rectangle(24, 60, width, height); canvas.BackColor = ShareStyle.Background;
        typeof(Panel).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).SetValue(canvas, true, null);
        Controls.Add(canvas);
        warning.Bounds = new Rectangle(24, 64 + height, width, 40); warning.ForeColor = Color.FromArgb(180, 60, 40); Controls.Add(warning);
        var cancel = new ShareButton { Text = "取消", BackColor = Color.White, Bounds = new Rectangle(24, 110 + height, 140, 38), DialogResult = DialogResult.Cancel };
        save.BackColor = Color.White; save.Bounds = new Rectangle(176, 110 + height, width - 152, 38); save.DialogResult = DialogResult.OK;
        Controls.Add(cancel); Controls.Add(save); CancelButton = cancel;
        var cells = ShareSettings.Cells();
        foreach (var peer in peers) {
            names[peer.Key] = peer.Value;
            Point cell; if (cells.TryGetValue(ShareSettings.ScreenName(peer.Key), out cell)) Placement[peer.Key] = cell;
        }
        canvas.Paint += (sender, e) => Draw(e.Graphics);
        canvas.MouseDown += (sender, e) => { dragging = Placement.Where(p => CellBounds(p.Value).Contains(e.Location)).Select(p => p.Key).FirstOrDefault(); pointer = e.Location; };
        canvas.MouseMove += (sender, e) => { if (dragging != null) { pointer = e.Location; canvas.Invalidate(); } };
        canvas.MouseUp += (sender, e) => {
            if (dragging == null) return;
            var target = new Point(e.X / Cell - Span, e.Y / Tall - Span);
            if (Math.Abs(target.X) <= Span && Math.Abs(target.Y) <= Span && target != Point.Empty && !Placement.Any(p => p.Key != dragging && p.Value == target)) Placement[dragging] = target;
            dragging = null; Check(); canvas.Invalidate();
        };
        Check();
    }
    Rectangle CellBounds(Point cell) { return new Rectangle((cell.X + Span) * Cell + 6, (cell.Y + Span) * Tall + 6, Cell - 12, Tall - 12); }
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
        warning.Text = ok ? "" : "有電腦沒有和其他螢幕相鄰，游標到不了；請把它移到相鄰的位置。";
    }
    void Draw(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var grid = new Pen(ShareStyle.Border) { DashStyle = DashStyle.Dash })
            for (int y = -Span; y <= Span; ++y) for (int x = -Span; x <= Span; ++x) g.DrawRectangle(grid, CellBounds(new Point(x, y)));
        Action<Rectangle, string, bool> tile = (r, text, host) => {
            using (var path = ShareStyle.Rounded(r, 10)) using (var fill = new SolidBrush(host ? ShareStyle.Blue : Color.White)) using (var edge = new Pen(ShareStyle.Blue, 1.5F)) { g.FillPath(fill, path); g.DrawPath(edge, path); }
            TextRenderer.DrawText(g, text, Font, r, host ? Color.White : ShareStyle.Ink, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis);
        };
        tile(CellBounds(Point.Empty), "這台（主控端）", true);
        foreach (var p in Placement) {
            var r = CellBounds(p.Value);
            if (p.Key == dragging) r.Offset(pointer.X - r.X - r.Width / 2, pointer.Y - r.Y - r.Height / 2);
            tile(r, names[p.Key], false);
        }
    }
    // Test hook: place a receiver as a drag would.
    internal bool Place(string fingerprint, Point cell)
    {
        if (cell == Point.Empty || Placement.Any(p => p.Key != fingerprint && p.Value == cell)) return false;
        Placement[fingerprint] = cell; Check(); canvas.Invalidate(); return true;
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
                    var shown = advanced.Controls.Cast<Control>().ToArray();
                    for (int i = 0; i < shown.Length; ++i) {
                        if (!advanced.ClientRectangle.Contains(shown[i].Bounds)) throw new Exception("Advanced dialog clips: " + shown[i].Text);
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
