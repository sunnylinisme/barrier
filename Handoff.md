# Barrier Share 交接

最後更新：2026-11-12（0.3.8 發布；下一版起共用 Release）

## 這是什麼

以 Barrier（debauchee/barrier，2022-02 版）為基礎改成的「Barrier Share」：Windows 10/11 x64 與 Apple Silicon Mac（macOS 15+）之間共用鍵盤滑鼠、雙向複製檔案。

- `master`：原版 Barrier，沒有改動。
- `prototype/native-file-drop`：所有開發都在這裡，對應 PR #1。
- 主要程式碼：`tools/native-file-drop/`（GUI、配對輔助程式、測試、打包）和 `src/lib/server/Server.cpp`、`src/lib/barrier/`（核心改動）。
- 詳細說明：`tools/native-file-drop/README.md`（架構／協定／測試）、`tools/native-file-drop/GUI-README.txt`（使用者說明與版本紀錄）。

## 目前版本

- Windows 0.3.8（已發布，`windows-v0.3.8`）：單一 EXE 安裝包（per-user，Inno Setup，`windows-setup.iss`）＋可攜 ZIP。視窗標題顯示版本。
- Mac 0.3.8（已發布，`mac-v0.3.8`，組建 9）：視窗標題顯示版本、有「關於 Barrier Share」。固定簽章（`Apple Development: freefishlin@gmail.com (PP2X799XV2)`，Team ID 2RA95F4R6F）；打包需設定 `BARRIER_CODESIGN_IDENTITY`，更新前用 `verify-macos-update.py` 驗證。

## 最近的工作

### 游標在跨畫面時來回彈跳（Windows → Windows 實機回報）

- 症狀：游標在兩台的邊界來回跳，進到另一台之後就正常。測試環境是主控端 2 個螢幕、接收端 1 個螢幕。
- 原因：切換畫面時，游標被放在對方螢幕最外側的那 1 個像素，手稍微往回動 1–2 px 就會立刻切回去。
- `6e471969`：新增測試 `--clipboard-edge-jitter`（進入後先往回 2 px 再往前，不能觸發 COUT），在 server 角色的四個方向都會跑。只加了測試、還沒修程式，所以 CI 失敗。
- `ec4d8249`：修正。`Server.cpp` 新增 `insetEntry()`，把原本只用在原生檔案拖曳的 16 px 內縮，套用到所有滑鼠觸發的畫面切換（主控端 → 接收端、接收端 → 主控端或其他畫面）。刻意往回移動（測試中是 64 px）仍然會正常切回。

### 主控端游標殘留在畫面中央（Windows 實機回報）

- 原因：原版 Barrier 靠一個 1×1 隱形視窗蓋住停在中央的游標。它帶 `WS_EX_TRANSPARENT`，系統判斷滑鼠位置時會略過它；拿掉之後，Windows 也不讓背景程式把視窗放到前景視窗之上（`SetWindowPos(HWND_TOPMOST)` 回報成功但沒生效，`SetForegroundWindow` 被拒）。CI 診斷證實了這兩點。
- `45848192`：離開主控端時用 `SetSystemCursor` 換成透明游標，進入、啟動、結束時用 `SPI_SETCURSORS` 從使用者設定重新載入。Windows GUI 停止或重啟背景程式後、以及啟動時也會還原，避免強制結束後游標一直透明。
- 測試：`WindowsDropTest --cursor-hidden/--cursor-visible` 用 `GetCursorInfo` 檢查游標圖案，並把狀態輸出成 CI 註記（未登入也能在 checks 頁看到）。
- 已知風險：如果背景程式和 GUI 同時異常結束，游標會維持透明，直到重新開啟 Barrier Share、更換游標配置或重新登入。

### 新版通知與發布

- 兩個 GUI 啟動時和之後每 24 小時讀取一次 `api.github.com/repos/sunnylinisme/barrier/releases`，只比對共用 tag `v*` 和自己平台的舊 tag（`windows-v*`／`mac-v*`），略過 draft、prerelease 和非本 repo 的連結。有新版時，右上角的「● 區域網路」會換成下載連結；Windows 另外會跳一次系統匣通知。不會自動下載。
- 發布（0.3.9 起兩個平台共用一個 Release，tag 為 `vX.Y.Z`）：先把 `windows-setup.iss`、`BarrierShare.cs`（AssemblyVersion）、`package-macos.sh` 升到同一版，`GUI-README.txt` 寫好「X.Y.Z 更新（Windows）」和「X.Y.Z 更新（Mac）」，commit 推上去。接著在 Mac 執行 `BARRIER_CODESIGN_IDENTITY='Apple Development: freefishlin@gmail.com (PP2X799XV2)' sh tools/native-file-drop/release-macos.sh`：編譯、測試、固定簽章打包，用 `verify-macos-update.py` 和 `/Applications` 裡的舊版比對簽章身分（可用 `OLD_APP` 指定），推 `vX.Y.Z` tag，建立附 Mac ZIP 的 **draft** Release。tag 觸發的 workflow 會核對兩個版本檔、等 draft 出現（最多約 10 分鐘），附上 Windows 安裝檔和可攜 ZIP 後才正式發布，所以使用者只會看到三個檔案都齊的 Release。
- 舊版相容：0.3.8 以前的 App 只認得 `windows-v*`／`mac-v*`。所以 release job 公開 `vX.Y.Z` 之後，會自動再建立 `windows-vX.Y.Z`（附 Windows 兩個檔案）和 `mac-vX.Y.Z`（附 Mac ZIP）兩個副本 Release，不標成 latest，說明連回共用 Release。這樣舊版 App 也能收到新版通知。等所有電腦都更新到 0.3.9 以上，就可以刪掉 workflow 裡的這段。
- `gh` 推送含 workflow 檔的 commit 需要 `workflow` scope（`gh auth refresh -s workflow`）。

### 0.3.9（尚未發布）：登入時啟動、傳輸進度、快捷鍵、安裝時自動關閉

- 登入時自動啟動：Windows 寫 `HKCU\...\Run\BarrierShare` = `"BarrierShare.exe" --background`（`ShareLogin`；路徑變了會自動更新，解除安裝會刪掉這個值）；`--background` 不顯示視窗、直接在系統匣啟動。Mac 用 `SMAppService.mainApp`，以登入項目啟動時不開視窗。
- 傳輸進度：核心 `FileClipboardTransfer.cpp` 每 0.5 秒記一行 `file clipboard: progress sent|received N bytes`；兩個 GUI 從紀錄解析，顯示已傳大小和速度。總大小事先不知道（串流協定沒傳總量），所以沒有百分比。傳輸中「恢復連線」變成「取消傳送」，做法是重啟背景程式，兩邊的暫存都會清掉。
- 快捷鍵：主控端設定檔加上 `keystroke(Control+Alt+<方向>) = switchInDirection(<方向>)`，只綁設定的那一軸（朝接收端和反方向）。Mac 上 Alt 是 Option。
- 安裝時自動關閉：拿掉 `AppMutex`，改在 `PrepareToInstall`／`InitializeUninstall` 觸發 `Local\BarrierShare.Quit` 事件讓 App 正常結束（會還原游標、停掉背景程式）；0.3.8 以前沒有這個事件，或 8 秒內沒結束，就 `taskkill /F /T` 再用 `SPI_SETCURSORS` 還原游標。之前有在執行的話，裝完會再開啟（靜默安裝也會）。`windows-installer-test.ps1` 有測試：背景執行中更新、更新後重新開啟、執行中解除安裝。

### 0.3.9：進階設定、手動位址、Windows 背景服務

- 進階設定（兩個 GUI）：切換延遲、輕敲兩下、角落不切換、接收端 ctrl/super 對調、相對滑鼠、螢幕保護同步、切換快捷鍵開關、Ctrl+Alt+L 鎖游標、額外 options 行（不能有 section/end）。存在 settings.xml 的 `<advanced>`／settings.json 的 `advanced`，舊設定檔可讀。
- 手動位址：`barrier-link` 新指令 `TARGETS\t<a,b>`（IPv4 或名稱，最多 16 個），每次搜尋也直接送到這些位址；名稱最多 30 秒解析一次。GUI 在 READY 和存檔後送出。
- Windows 背景服務 `barrier-service.exe`（服務名 `BarrierShare`，LocalSystem，自動啟動）：GUI 透過 `\\.\pipe\BarrierShare.Service` 送 START/STOP/STATUS。核心用主控台工作階段的 winlogon token 啟動（SYSTEM），所以登入畫面、鎖定畫面、UAC 都能用；登出後會在新的主控台工作階段重新啟動核心。
  - 安全性：只接受主控台工作階段使用者的要求；配對憑證、信任清單、設定檔以資料傳送，服務寫到 `{app}\state\<SID>\`（只有 SYSTEM／Administrators 可改，使用者可讀），從不開啟使用者指定的路徑；執行檔只用服務自己的資料夾。
  - 已知限制：核心以 SYSTEM 讀取要傳送的檔案（多人共用電腦時要注意）；核心還原游標時讀的是 SYSTEM 的游標配置，GUI 停止核心後會再用使用者的配置還原。
  - 安裝改為 `PrivilegesRequired=admin`、`{autopf}\Barrier Share`；`PrepareToInstall` 停服務、移除 HKCU 舊個人安裝；裝完用 `sc` 建立／更新並啟動服務；解除安裝停止並刪除服務、刪 `{app}\state`。GUI 以 `runasoriginaluser` 重新開啟。
  - 免安裝 ZIP 沒有服務，GUI 連不到 pipe 時自動改回自己啟動核心。

## 待辦

0. 版本號統一：Windows 與 Mac 都在 0.3.8（2026-11-12 以 `windows-v0.3.8`、`mac-v0.3.8` 分開發布，是最後一次分開發布），視窗標題顯示版本（Windows 系統匣提示也會顯示；Mac 新增「關於 Barrier Share」選單）。

1. ~~確認 `ec4d8249` 的 CI 通過~~：已通過（run 43144214817，Windows 和 macOS 都成功）。
2. 實機驗收：Windows → Windows，主控端多螢幕，四個方向都要慢慢貼邊來回移動，確認不再彈跳、刻意切回仍正常；游標在接收端時主控端看不到游標，回來後游標樣式正常。
3. Mac 0.3.5（含彈跳修正與新版通知）已於 2026-11-12 發布並在 Mac mini 上安裝驗證：診斷紀錄顯示 0.3.5（組建 8），輔助使用與輸入監控權限在更新後仍為已授權。
4. 已知限制（見 README）：一次只能連一台、只支援 IPv4 同網段、Mac App 未公證、自動測試不能取代兩台實機的驗收。

## 開發注意事項

- Windows 建置需要 CMake、MSVC 和 vcpkg 靜態 OpenSSL，完整步驟在 `.github/workflows/native-file-drop.yml`。
- Windows 整合測試會實際移動游標、操作 Explorer 和系統剪貼簿，不要在正在使用的電腦上跑；以 CI（Windows Server 2022）為準。
- CI 只在 PR 有變更 `src/**`、`tools/native-file-drop/**`、`CMakeLists.txt` 或 workflow 時觸發。
