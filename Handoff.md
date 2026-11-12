# Barrier Share 交接

最後更新：2026-11-12（Mac 0.3.5 發布）

## 這是什麼

以 Barrier（debauchee/barrier，2022-02 版）為基礎改成的「Barrier Share」：Windows 10/11 x64 與 Apple Silicon Mac（macOS 15+）之間共用鍵盤滑鼠、雙向複製檔案。

- `master`：原版 Barrier，沒有改動。
- `prototype/native-file-drop`：所有開發都在這裡，對應 PR #1。
- 主要程式碼：`tools/native-file-drop/`（GUI、配對輔助程式、測試、打包）和 `src/lib/server/Server.cpp`、`src/lib/barrier/`（核心改動）。
- 詳細說明：`tools/native-file-drop/README.md`（架構／協定／測試）、`tools/native-file-drop/GUI-README.txt`（使用者說明與版本紀錄）。

## 目前版本

- Windows 0.3.7（含跨畫面彈跳、主控端游標殘留修正與新版通知）：單一 EXE 安裝包（per-user，Inno Setup，`windows-setup.iss`）。
- Mac 0.3.5（已發布，2026-11-12，Release `mac-v0.3.5`）：固定簽章（`Apple Development: freefishlin@gmail.com (PP2X799XV2)`，Team ID 2RA95F4R6F）；打包需設定 `BARRIER_CODESIGN_IDENTITY`，更新前用 `verify-macos-update.py` 驗證。

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

- 兩個 GUI 啟動時和之後每 24 小時讀取一次 `api.github.com/repos/sunnylinisme/barrier/releases`，只比對自己平台的 tag（`windows-v*`／`mac-v*`），略過 draft、prerelease 和非本 repo 的連結。有新版時，右上角的「● 區域網路」會換成下載連結；Windows 另外會跳一次系統匣通知。不會自動下載。
- Windows 發布：推 `windows-vX.Y.Z` tag，workflow 的 `release` job 會核對 tag 和 `windows-setup.iss` 的版本，從 `GUI-README.txt` 取「X.Y.Z 更新（Windows）」那段當說明，附上安裝檔和可攜 ZIP。
- Mac 發布：CI 只有臨時簽章，所以要在 Mac 本機執行 `tools/native-file-drop/release-macos.sh`。它會編譯、測試、用 `BARRIER_CODESIGN_IDENTITY` 簽章打包，用 `verify-macos-update.py` 和 `/Applications` 裡的舊版比對簽章身分（可用 `OLD_APP` 指定），最後推 `mac-vX.Y.Z` tag，並用 `gh` 建立 Release。版本號取自 `package-macos.sh`，說明取自 `GUI-README.txt` 的「X.Y.Z 更新（Mac）」。注意：腳本會在 repo 內產生 `build-release/`（未列入 .gitignore），重跑前要先刪掉，否則會因工作目錄不乾淨而中止。

## 待辦

0. 版本號統一：Windows 與 Mac 都升到 0.3.8，視窗標題顯示版本（Windows 系統匣提示也會顯示；Mac 新增「關於 Barrier Share」選單）。尚未發布：Windows 推 `windows-v0.3.8`，Mac 執行 `release-macos.sh`。

1. ~~確認 `ec4d8249` 的 CI 通過~~：已通過（run 43144214817，Windows 和 macOS 都成功）。
2. 實機驗收：Windows → Windows，主控端多螢幕，四個方向都要慢慢貼邊來回移動，確認不再彈跳、刻意切回仍正常；游標在接收端時主控端看不到游標，回來後游標樣式正常。
3. Windows 0.3.7 已升版；推 `windows-v0.3.7` tag 即發布第一個正式 Release。Mac 0.3.5（含彈跳修正與新版通知）已於 2026-11-12 發布並在 Mac mini 上安裝驗證：診斷紀錄顯示 0.3.5（組建 8），輔助使用與輸入監控權限在更新後仍為已授權。
4. 已知限制（見 README）：一次只能連一台、只支援 IPv4 同網段、Mac App 未公證、自動測試不能取代兩台實機的驗收。

## 開發注意事項

- Windows 建置需要 CMake、MSVC 和 vcpkg 靜態 OpenSSL，完整步驟在 `.github/workflows/native-file-drop.yml`。
- Windows 整合測試會實際移動游標、操作 Explorer 和系統剪貼簿，不要在正在使用的電腦上跑；以 CI（Windows Server 2022）為準。
- CI 只在 PR 有變更 `src/**`、`tools/native-file-drop/**`、`CMakeLists.txt` 或 workflow 時觸發。
