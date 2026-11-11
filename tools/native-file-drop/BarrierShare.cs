// SPDX-License-Identifier: GPL-2.0-or-later
// Portable desktop frontend; the existing Barrier processes own the connection.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Xml.Linq;

static class ShareSettings
{
    public static string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BarrierShare");
    public static string Bin = AppDomain.CurrentDomain.BaseDirectory;
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
        var document = new XDocument(new XElement("settings", new XAttribute("host", host), new XAttribute("address", address)));
        string path = Path.Combine(Root, "settings.xml"), temporary = path + ".new";
        document.Save(temporary);
        if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
    }
    public static void Load(out bool host, out string address)
    {
        host = true; address = "";
        string path = Path.Combine(Root, "settings.xml");
        if (!File.Exists(path)) return;
        var root = XDocument.Load(path).Root;
        host = (bool)root.Attribute("host"); address = (string)root.Attribute("address") ?? "";
    }
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
        return "section: screens\n windows-host:\n windows:\nend\nsection: links\n windows-host:\n  right = windows\n windows:\n  left = windows-host\nend\nsection: options\n clipboardSharing = " + (clipboard ? "true" : "false") + "\nend\n";
    }
    public static ProcessStartInfo Backend(bool host, string address)
    {
        string profile = Profile(host);
        var args = new List<string> { "-f", "--no-tray", "--file-clipboard", "--profile-dir", profile,
            "--log", Path.Combine(profile, host ? "server.log" : "windows.log"), "--name", host ? "windows-host" : "windows" };
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

sealed class ShareWindow : Form
{
    readonly ComboBox role = new ComboBox();
    readonly TextBox address = new TextBox(), fingerprint = new TextBox(), details = new TextBox();
    readonly Label status = new Label(), addresses = new Label();
    readonly Button start = new Button(), stop = new Button(), import = new Button(), clear = new Button();
    readonly NotifyIcon tray = new NotifyIcon();
    readonly HashSet<string> prompted = new HashSet<string>();
    Process backend;
    bool closing, loading = true;
    bool Host { get { return role.SelectedIndex == 0; } }
    void At(Control c, int x, int y, int width, int height) { c.SetBounds(x, y, width, height); Controls.Add(c); }
    void LabelAt(string text, int x, int y, int width) { var l = new Label { Text = text }; At(l, x, y, width, 26); }
    public ShareWindow()
    {
        Text = "Barrier Share · 雙向檔案複製（測試版）";
        Font = new Font("Microsoft JhengHei UI", 10F); ClientSize = new Size(680, 615);
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
        Icon = SystemIcons.Application;
        LabelAt("兩台電腦，共用鍵鼠與複製貼上", 24, 20, 620);
        LabelAt("這台電腦", 24, 63, 120); At(role, 150, 58, 502, 32);
        role.DropDownStyle = ComboBoxStyle.DropDownList;
        role.Items.AddRange(new object[] { "主控端 — 滑鼠與鍵盤接在這台", "接收端 — 位於主控端螢幕右邊" });
        LabelAt("主控端 IP", 24, 106, 120); At(address, 150, 101, 502, 30);
        At(addresses, 24, 144, 628, 45);
        At(status, 24, 197, 628, 30); status.ForeColor = Color.FromArgb(20, 80, 145);
        start.Text = "開始連線"; stop.Text = "停止"; import.Text = "沿用舊版配對"; clear.Text = "清除檔案暫存";
        At(start, 24, 234, 140, 40); At(stop, 176, 234, 100, 40);
        At(import, 288, 234, 176, 40); At(clear, 476, 234, 176, 40); stop.Enabled = false;
        LabelAt("本機識別碼（首次配對時供另一台核對）", 24, 292, 620);
        At(fingerprint, 24, 322, 628, 60); fingerprint.Multiline = true; fingerprint.ReadOnly = true;
        fingerprint.Font = new Font("Consolas", 10); fingerprint.BackColor = SystemColors.Window;
        LabelAt("檔案：選取一個檔案 → Ctrl+C → 移到另一台 → 在資料夾 Ctrl+V", 24, 396, 635);
        LabelAt("主 ↔ 副皆可。每次一個檔案，最大 16 MiB；保留原檔。", 24, 423, 635);
        LabelAt("目前不含資料夾／多檔；此介面預設不啟用拖曳。", 24, 450, 635);
        At(details, 24, 485, 628, 106); details.Multiline = true; details.ReadOnly = true; details.ScrollBars = ScrollBars.Vertical;
        details.Font = new Font("Consolas", 8); details.BackColor = Color.FromArgb(247, 248, 250);
        var menu = new ContextMenuStrip(); menu.Items.Add("開啟視窗", null, delegate { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("結束", null, delegate { closing = true; Close(); });
        tray.Icon = Icon; tray.Text = "Barrier Share"; tray.ContextMenuStrip = menu; tray.Visible = true;
        tray.DoubleClick += delegate { Show(); WindowState = FormWindowState.Normal; Activate(); };
        start.Click += delegate { StartBackend(); }; stop.Click += delegate { StopBackend(); };
        import.Click += delegate { ImportPairing(); }; clear.Click += delegate { ClearCache(); };
        role.SelectedIndexChanged += delegate { if (!loading) RefreshRole(); };
        address.TextChanged += delegate { if (!loading) Save(); };
        Shown += delegate {
            try {
                ShareSettings.Import(ShareSettings.Bin, true, false); ShareSettings.Import(ShareSettings.Bin, false, false);
                bool host; string ip; ShareSettings.Load(out host, out ip); role.SelectedIndex = host ? 0 : 1; address.Text = ip;
                loading = false; RefreshRole();
            } catch (Exception e) { loading = false; role.SelectedIndex = 0; Error(e); }
        };
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (!closing && backend != null) { e.Cancel = true; Hide(); tray.ShowBalloonTip(2000, "Barrier Share", "仍在連線。從右下角圖示可開啟視窗或結束。", ToolTipIcon.Info); return; }
            closing = true; StopBackend(); tray.Dispose();
        };
    }
    void Error(Exception e) { status.Text = "操作未完成"; MessageBox.Show(this, e.Message, "Barrier Share", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    void Save() { try { ShareSettings.Save(Host, address.Text.Trim()); } catch (Exception e) { status.Text = "無法儲存設定：" + e.Message; } }
    void RefreshRole()
    {
        address.Enabled = !Host; Save();
        try {
            string fp = ShareSettings.Init(Host); fingerprint.Text = fp;
            string[] ips = Dns.GetHostAddresses(Dns.GetHostName()).Where(ip => ip.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ip)).Select(ip => ip.ToString()).ToArray();
            addresses.Text = Host ? "接收端請填這台的區網 IP：" + String.Join("、", ips) + "\r\n接收端固定放在螢幕右邊。" : "填好主控端 IP 後連線；兩台需在同一個區域網路。";
            status.Text = File.Exists(ShareSettings.TrustedPath(Host)) ? "已保留配對資料，按「開始連線」即可。" : "尚未配對；連線時會顯示對方識別碼供核對。";
        } catch (Exception e) { Error(e); }
    }
    void StartBackend()
    {
        if (backend != null) return;
        try {
            ShareSettings.Init(Host); Save(); prompted.Clear();
            var process = new Process { StartInfo = ShareSettings.Backend(Host, address.Text.Trim()), EnableRaisingEvents = true };
            process.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { PostLine(process, e.Data); };
            process.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { PostLine(process, e.Data); };
            process.Exited += delegate { if (!closing && IsHandleCreated) BeginInvoke((Action)delegate { if (backend == process) { StopBackend(); status.Text = "連線程式已停止，請查看下方紀錄。"; } }); };
            backend = process; status.Text = Host ? "等待接收端連線…" : "正在連線…";
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
            start.Enabled = role.Enabled = address.Enabled = import.Enabled = clear.Enabled = false; stop.Enabled = true;
        } catch (Exception e) { StopBackend(); Error(e); }
    }
    void PostLine(Process process, string line)
    {
        if (String.IsNullOrEmpty(line) || closing || !IsHandleCreated) return;
        try { BeginInvoke((Action)delegate { if (backend == process) LogLine(line); }); } catch (InvalidOperationException) { }
    }
    void LogLine(string line)
    {
        if (details.TextLength > 24000) details.Text = details.Text.Substring(details.TextLength - 12000);
        details.AppendText(line + Environment.NewLine);
        if (line.Contains("connected to server") || line.Contains("has connected")) status.Text = "已連線 · 雙向複製貼上已啟用";
        if (line.Contains("received and verified") && line.Contains("clipboard")) status.Text = "已收到檔案，可在資料夾 Ctrl+V 貼上";
        if (line.Contains("WARNING") && line.Contains("file clipboard:")) status.Text = "檔案無法複製：請確認是單一檔案、16 MiB 以內。詳細原因見下方。";
        if (line.Contains("disconnected") || line.Contains("server is dead")) status.Text = "連線中斷，正在重連…";
        var match = Regex.Match(line, @"\(SHA256\):\s*([0-9A-Fa-f:]{95})");
        if (!match.Success) return;
        string peer = "v2:sha256:" + match.Groups[1].Value.Replace(":", "").ToLowerInvariant();
        if (ShareSettings.Trusted(Host, peer) || !prompted.Add(peer)) return;
        if (!Visible) Show(); Activate();
        string question = "首次連線：請核對另一台視窗的「本機識別碼」是否完全相同。\r\n\r\n" + peer + "\r\n\r\n相同才按「是」；不相同請按「否」。之後會記住配對，不必重新輸入。";
        if (MessageBox.Show(this, question, "確認對方電腦", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes) {
            try { ShareSettings.Pair("trust", ShareSettings.Profile(Host), Host ? "client" : "server", peer); status.Text = "已記住對方，等待自動重連…"; }
            catch (Exception e) { Error(e); }
        }
    }
    void StopBackend()
    {
        var process = backend; backend = null;
        if (process != null) {
            try { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } } catch (InvalidOperationException) { }
            process.Dispose();
        }
        start.Enabled = role.Enabled = import.Enabled = clear.Enabled = true; address.Enabled = !Host; stop.Enabled = false;
        status.Text = "已停止；設定與配對已保留。";
    }
    void ImportPairing()
    {
        using (var folder = new FolderBrowserDialog { Description = "選擇之前能連線的測試包資料夾（裡面有 profile 或 profile-server）" }) {
            if (folder.ShowDialog(this) != DialogResult.OK) return;
            try {
                if (!ShareSettings.Import(folder.SelectedPath, Host, true)) throw new IOException("找不到這個角色的舊配對資料。請選原本的測試包資料夾。");
                RefreshRole(); status.Text = "已沿用舊版配對，不必重貼 v2 識別碼。";
            } catch (Exception e) { Error(e); }
        }
    }
    void ClearCache()
    {
        if (MessageBox.Show(this, "清除尚未貼上的接收檔案暫存？已貼到資料夾的檔案不受影響。", "清除暫存", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
        try {
            if (Clipboard.ContainsFileDropList()) {
                var paths = Clipboard.GetFileDropList();
                if (paths.Cast<string>().Any(p => p.StartsWith(ShareSettings.Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))) Clipboard.Clear();
            }
            foreach (bool host in new[] { true, false }) {
                string cache = Path.Combine(ShareSettings.Profile(host), "ClipboardCache");
                if (Directory.Exists(cache)) Directory.Delete(cache, true);
            }
            status.Text = "已清除接收檔案暫存。";
        } catch (Exception e) { Error(e); }
    }
}

static class ShareProgram
{
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 2 && args[0] == "--self-test") return SelfTest(args[1]);
        bool created;
        using (var mutex = new Mutex(true, "Local\\BarrierShare.Desktop", out created)) {
            if (!created) { MessageBox.Show("Barrier Share 已在執行，請從右下角圖示開啟。", "Barrier Share"); return 0; }
            Application.Run(new ShareWindow());
        }
        return 0;
    }
    static int SelfTest(string directory)
    {
        try {
            ShareSettings.Root = Path.Combine(directory, "新設定");
            ShareSettings.Save(false, "192.168.7.4");
            bool host; string address; ShareSettings.Load(out host, out address);
            if (host || address != "192.168.7.4") throw new Exception("Settings roundtrip failed");
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
            using (var core = Process.Start(ShareSettings.Backend(true, ""))) {
                Thread.Sleep(1500);
                if (core.HasExited) throw new Exception("Hidden backend failed: " + core.StandardError.ReadToEnd());
                if (core.MainWindowHandle != IntPtr.Zero) throw new Exception("Backend opened a console");
                core.Kill(); core.WaitForExit(5000);
            }
            using (var window = new ShareWindow()) {
                window.Show(); Application.DoEvents();
                using (var bitmap = new Bitmap(window.Width, window.Height)) { window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size)); bitmap.Save(Path.Combine(directory, "gui.png")); }
                window.Close();
            }
            File.WriteAllText(Path.Combine(directory, "PASS.txt"), "Settings persist; old pairing and trust preserved; hidden backend starts/stops; GUI renders.");
            return 0;
        } catch (Exception e) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "FAIL.txt"), e.ToString()); return 1; }
    }
}
