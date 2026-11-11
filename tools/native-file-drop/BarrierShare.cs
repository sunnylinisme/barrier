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
        var document = new XDocument(new XElement("settings", new XAttribute("host", host), new XAttribute("address", address), new XAttribute("position", Position)));
        string path = Path.Combine(Root, "settings.xml"), temporary = path + ".new";
        document.Save(temporary);
        if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
    }
    public static void Load(out bool host, out string address)
    {
        host = true; address = ""; Position = "right";
        string path = Path.Combine(Root, "settings.xml");
        if (!File.Exists(path)) return;
        var root = XDocument.Load(path).Root;
        host = (bool)root.Attribute("host"); address = (string)root.Attribute("address") ?? "";
        string position = (string)root.Attribute("position");
        Position = Directions.Contains(position) ? position : "right";
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
        if (!Directions.Contains(Position)) throw new IOException("請選擇有效的螢幕位置。");
        string opposite = new[] { "left", "right", "down", "up" }[Array.IndexOf(Directions, Position)];
        return ("section: screens\n windows-host:\n windows:\nend\nsection: links\n windows-host:\n  right = windows\n windows:\n  left = windows-host\nend\nsection: options\n clipboardSharing = " + (clipboard ? "true" : "false") + "\nend\n").Replace("right = windows", Position + " = windows").Replace("left = windows-host", opposite + " = windows-host");
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

sealed class NearbyDevice
{
    public string Fingerprint, Name, Address;
    public override string ToString() { return Name + "  ·  " + Address; }
}
sealed class ShareWindow : Form
{
    readonly ComboBox role = new ComboBox(), position = new ComboBox(), nearby = new ComboBox();
    readonly Label positionHint = new Label(), status = new Label(), peerLabel = new Label();
    readonly TextBox address = new TextBox(), details = new TextBox();
    readonly Button start = new Button(), stop = new Button(), search = new Button(), pair = new Button(), forget = new Button(), clear = new Button();
    readonly NotifyIcon tray = new NotifyIcon();
    readonly Dictionary<string, NearbyDevice> devices = new Dictionary<string, NearbyDevice>();
    readonly System.Windows.Forms.Timer retry = new System.Windows.Forms.Timer { Interval = 3000 };
    readonly bool testing;
    Process backend, link;
    Form consent;
    string consentId, connectedAddress = "", savedPeer = "";
    bool closing, loading = true, enabled = true;
    bool Host { get { return role.SelectedIndex == 0; } }
    void At(Control c, int x, int y, int width, int height) { c.SetBounds(x, y, width, height); Controls.Add(c); }
    void LabelAt(string text, int x, int y, int width) { At(new Label { Text = text }, x, y, width, 26); }
    public ShareWindow(bool selfTest = false)
    {
        testing = selfTest; Text = "Barrier Share · 附近電腦";
        Font = new Font("Microsoft JhengHei UI", 10F); ClientSize = new Size(720, 640);
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen; Icon = SystemIcons.Application;
        LabelAt("選擇附近電腦，配對後自動連線", 24, 20, 670);
        LabelAt("這台電腦", 24, 63, 120); At(role, 150, 58, 542, 32); role.DropDownStyle = ComboBoxStyle.DropDownList;
        role.Items.AddRange(new object[] { "主控端 — 滑鼠與鍵盤接在這台", "接收端 — 同意邀請後即可使用" });
        LabelAt("附近電腦", 24, 110, 120); At(nearby, 150, 104, 410, 32); nearby.DropDownStyle = ComboBoxStyle.DropDownList;
        search.Text = "重新搜尋"; At(search, 570, 101, 122, 36);
        LabelAt("接收端位置", 24, 157, 120); At(position, 150, 151, 542, 32); position.DropDownStyle = ComboBoxStyle.DropDownList;
        position.Items.AddRange(new object[] { "主控端右方", "主控端左方", "主控端上方", "主控端下方" }); position.SelectedIndex = 0;
        positionHint.Text = "由主控端設定"; At(positionHint, 150, 157, 542, 26);
        At(peerLabel, 24, 204, 668, 45); At(status, 24, 254, 668, 50); status.ForeColor = Color.FromArgb(20, 80, 145);
        pair.Text = "邀請配對"; start.Text = "恢復連線"; stop.Text = "暫停"; forget.Text = "解除配對"; clear.Text = "清除檔案暫存";
        At(pair, 24, 314, 150, 40); At(start, 186, 314, 136, 40); At(stop, 334, 314, 100, 40); At(forget, 446, 314, 116, 40); At(clear, 574, 314, 118, 40);
        LabelAt("首次配對：核對兩邊的 6 位數短碼，雙方同意後記住這台電腦。", 24, 378, 670);
        LabelAt("之後兩台開啟程式便會自動重連，IP 改變也不必重新輸入。", 24, 407, 670);
        LabelAt("雙向複製檔案／資料夾；等另一台顯示收到檔案後，再貼上。", 24, 436, 670);
        LabelAt("Windows：Ctrl+C／V　Mac：⌘C／V　大檔案分段傳送。", 24, 465, 670);
        At(details, 24, 505, 668, 110); details.Multiline = true; details.ReadOnly = true; details.ScrollBars = ScrollBars.Vertical;
        details.Font = new Font("Consolas", 8); details.BackColor = Color.FromArgb(247, 248, 250);
        var menu = new ContextMenuStrip(); menu.Items.Add("開啟視窗", null, delegate { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("結束", null, delegate { closing = true; Close(); }); tray.Icon = Icon; tray.Text = "Barrier Share"; tray.ContextMenuStrip = menu; tray.Visible = !testing;
        tray.DoubleClick += delegate { Show(); WindowState = FormWindowState.Normal; Activate(); };
        start.Click += delegate { enabled = true; StartLink(); UpdateControls(); };
        stop.Click += delegate { enabled = false; StopLink(); StopBackend(); status.Text = "已暫停；不接受邀請，也不會自動重連。"; UpdateControls(); };
        search.Click += delegate { Send("SEARCH"); status.Text = "正在搜尋同一區網的電腦…"; };
        pair.Click += delegate { var peer = nearby.SelectedItem as NearbyDevice; if (peer != null) { StopBackend(); Send("PAIR\t" + peer.Fingerprint); status.Text = "正在發出邀請…"; } };
        forget.Click += delegate {
            if (MessageBox.Show(this, "解除後不會自動連線，需要重新邀請並經對方同意。", "解除配對", MessageBoxButtons.OKCancel) != DialogResult.OK) return;
            StopBackend(); Send("FORGET");
        };
        clear.Click += delegate { ClearCache(); };
        role.SelectedIndexChanged += delegate { if (!loading) { try { StopLink(); StopBackend(); RefreshRole(); if (enabled) StartLink(); } catch (Exception e) { Error(e); } } };
        position.SelectedIndexChanged += delegate { if (!loading && position.SelectedIndex >= 0) { ShareSettings.Position = ShareSettings.Directions[position.SelectedIndex]; Save(); if (backend != null) StopBackend(); } };
        nearby.SelectedIndexChanged += delegate { UpdateControls(); };
        retry.Tick += delegate { if (enabled && link == null && !testing && !closing) StartLink(); };
        Shown += delegate {
            try {
                ShareSettings.Import(ShareSettings.Bin, true, false); ShareSettings.Import(ShareSettings.Bin, false, false);
                bool host; string ip; ShareSettings.Load(out host, out ip); role.SelectedIndex = host ? 0 : 1; address.Text = ip; position.SelectedIndex = Array.IndexOf(ShareSettings.Directions, ShareSettings.Position);
                loading = false; RefreshRole(); if (!testing) { StartLink(); retry.Start(); }
            } catch (Exception e) { loading = false; Error(e); }
        };
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (!closing && !testing) { e.Cancel = true; Hide(); tray.ShowBalloonTip(1500, "Barrier Share", "仍在背景搜尋與連線；從系統匣可結束程式。", ToolTipIcon.Info); return; }
            closing = true; retry.Stop(); StopLink(); StopBackend(); tray.Dispose();
        };
    }
    void Error(Exception e) { status.Text = "操作未完成：" + e.Message; }
    void Save() { try { ShareSettings.Save(Host, address.Text.Trim()); } catch (Exception e) { Error(e); } }
    void UpdateControls()
    {
        start.Enabled = !enabled || link == null; stop.Enabled = enabled;
        search.Enabled = link != null; pair.Enabled = Host && link != null && nearby.SelectedItem != null && consent == null;
        forget.Enabled = link != null && savedPeer.Length != 0; clear.Enabled = !enabled && backend == null;
    }
    void RefreshRole()
    {
        position.Visible = Host; positionHint.Visible = !Host; savedPeer = ""; devices.Clear(); nearby.Items.Clear(); Save();
        ShareSettings.Init(Host); peerLabel.Text = Host ? "選擇接收端，按「邀請配對」。" : "等待主控端邀請；首次需要你同意。";
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
        CloseConsent(); var process = link; link = null;
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
        if (f[0] == "READY") status.Text = Host ? "正在搜尋接收端…" : "可被搜尋，等待主控端邀請…";
        else if (f[0] == "DEVICE" && f.Length == 6) {
            NearbyDevice device; string selected = nearby.SelectedItem is NearbyDevice ? ((NearbyDevice)nearby.SelectedItem).Fingerprint : "";
            if (!devices.TryGetValue(f[1], out device)) { device = new NearbyDevice { Fingerprint = f[1] }; devices[f[1]] = device; }
            device.Name = Decode(f[2]); device.Address = f[3]; nearby.Items.Clear();
            foreach (var value in devices.Values) nearby.Items.Add(value);
            if (devices.ContainsKey(selected)) nearby.SelectedItem = devices[selected]; else if (nearby.Items.Count > 0) nearby.SelectedIndex = 0;
        } else if (f[0] == "GONE" && f.Length == 2) { NearbyDevice device; if (devices.TryGetValue(f[1], out device)) { nearby.Items.Remove(device); devices.Remove(f[1]); } }
        else if ((f[0] == "SAVED" || f[0] == "PAIRED") && f.Length == 3) { if (f[0] == "PAIRED") StopBackend(); savedPeer = f[1]; peerLabel.Text = "已配對：" + Decode(f[2]) + "\r\n開啟程式後會自動搜尋並驗證這台電腦。"; }
        else if ((f[0] == "VERIFY" || f[0] == "REQUEST") && f.Length == 5) ShowConsent(f);
        else if (f[0] == "CLOSED" && f.Length == 2 && f[1] == consentId) CloseConsent();
        else if (f[0] == "CONNECT" && f.Length == 4) {
            if (f[1] == savedPeer && (backend == null || (!Host && connectedAddress != f[3]))) { StopBackend(); address.Text = f[3]; Save(); StartBackend(); }
        } else if (f[0] == "REMOVED") { StopBackend(); savedPeer = ""; peerLabel.Text = "已解除配對。"; status.Text = Host ? "可以選擇接收端重新邀請。" : "等待新的配對邀請。"; }
        else if ((f[0] == "ERROR" || f[0] == "FATAL") && f.Length == 2) { status.Text = Decode(f[1]); LogLine(status.Text); }
        UpdateControls();
    }
    void ShowConsent(string[] message)
    {
        CloseConsent(); Show(); Activate(); consentId = message[1]; string id = consentId;
        var dialog = new Form { Text = message[0] == "REQUEST" ? "收到配對邀請" : "核對配對碼", ClientSize = new Size(500, 280), Font = Font, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false };
        consent = dialog;
        var explanation = new Label { Text = Decode(message[2]) + "\r\n請確認另一台顯示相同的 6 位數配對碼。", Bounds = new Rectangle(24, 18, 452, 58) };
        var code = new Label { Text = message[4], Font = new Font("Consolas", 30F, FontStyle.Bold), Bounds = new Rectangle(24, 82, 452, 60), TextAlign = ContentAlignment.MiddleCenter };
        var permission = new Label { Text = "同意後允許共用鍵盤滑鼠及雙向同步剪貼簿。\r\n配對會被記住，之後自動連線。", Bounds = new Rectangle(24, 150, 452, 55) };
        var reject = new Button { Text = "拒絕", Bounds = new Rectangle(170, 224, 110, 36), DialogResult = DialogResult.Cancel };
        var accept = new Button { Text = "相同，同意", Bounds = new Rectangle(292, 224, 182, 36), DialogResult = DialogResult.OK };
        dialog.Controls.AddRange(new Control[] { explanation, code, permission, reject, accept }); dialog.CancelButton = reject; dialog.AcceptButton = reject;
        UpdateControls(); var result = dialog.ShowDialog(this);
        if (consentId == id) { Send((result == DialogResult.OK ? "ACCEPT\t" : "REJECT\t") + id); consent = null; consentId = null; status.Text = result == DialogResult.OK ? "已同意，等待對方確認…" : "已拒絕配對。"; }
        dialog.Dispose(); UpdateControls();
    }
    void CloseConsent() { var dialog = consent; consent = null; consentId = null; if (dialog != null) dialog.Close(); }
    void StartBackend()
    {
        if (backend != null || !enabled) return;
        try {
            var process = new Process { StartInfo = ShareSettings.Backend(Host, address.Text), EnableRaisingEvents = true }; backend = process;
            process.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { Post(process, e.Data, false); }; process.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { Post(process, e.Data, false); };
            process.Exited += delegate { if (!closing && IsHandleCreated) BeginInvoke((Action)delegate { if (backend == process) { StopBackend(); status.Text = "連線暫停，會自動重試；詳情見下方紀錄。"; } }); };
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine(); connectedAddress = address.Text; status.Text = "配對已驗證，正在連線…"; UpdateControls();
        } catch (Exception e) { StopBackend(); Error(e); }
    }
    void StopBackend()
    {
        var process = backend; backend = null;
        if (process != null) { try { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } } catch (InvalidOperationException) { } process.Dispose(); }
        UpdateControls();
    }
    void LogLine(string line)
    {
        if (details.TextLength > 24000) details.Text = details.Text.Substring(details.TextLength - 12000); details.AppendText(line + Environment.NewLine);
        if (line.Contains("connected to server") || line.Contains("has connected")) status.Text = "已連線 · 雙向複製貼上已啟用";
        if (line.Contains("file clipboard: sending")) status.Text = "正在傳送檔案… 可繼續操作滑鼠與鍵盤";
        if (line.Contains("file clipboard: receiving")) status.Text = "正在接收檔案… 完成後即可貼上";
        if (line.Contains("received and verified") && line.Contains("clipboard")) status.Text = "已收到檔案，可在資料夾 Ctrl+V 貼上";
        if (line.Contains("WARNING") && line.Contains("file clipboard:")) status.Text = "檔案複製未完成；請查看下方原因。";
        if (line.Contains("disconnected") || line.Contains("server is dead")) status.Text = "連線中斷，正在自動重連…";
    }
    internal void TestDiscovery(string directory)
    {
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
            Application.Run(new ShareWindow(true));
        }
        return 0;
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
            }
            using (var core = Process.Start(ShareSettings.Backend(true, ""))) {
                Thread.Sleep(1500);
                if (core.HasExited) throw new Exception("Hidden backend failed: " + core.StandardError.ReadToEnd());
                if (core.MainWindowHandle != IntPtr.Zero) throw new Exception("Backend opened a console");
                core.Kill(); core.WaitForExit(5000);
            }
            using (var window = new ShareWindow(true)) {
                window.Show(); Application.DoEvents(); window.TestDiscovery(directory);
                using (var bitmap = new Bitmap(window.Width, window.Height)) { window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size)); bitmap.Save(Path.Combine(directory, "gui.png")); }
                window.Close();
            }
            File.WriteAllText(Path.Combine(directory, "PASS.txt"), "Settings persist; old pairing and trust preserved; hidden backend starts/stops; GUI renders.");
            return 0;
        } catch (Exception e) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "FAIL.txt"), e.ToString()); return 1; }
    }
}
