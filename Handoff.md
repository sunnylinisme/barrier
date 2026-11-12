# Barrier Share 交接

最後更新：2026-11-12

## 這是什麼

以 Barrier（debauchee/barrier，2022-02 版）為基礎改成的「Barrier Share」：Windows 10/11 x64 與 Apple Silicon Mac（macOS 15+）之間共用鍵盤滑鼠、雙向複製檔案。

- `master`：原版 Barrier，沒有改動。
- `prototype/native-file-drop`：所有開發都在這裡，對應 PR #1。
- 主要程式碼：`tools/native-file-drop/`（GUI、配對輔助程式、測試、打包）和 `src/lib/server/Server.cpp`、`src/lib/barrier/`（核心改動）。
- 詳細說明：`tools/native-file-drop/README.md`（架構／協定／測試）、`tools/native-file-drop/GUI-README.txt`（使用者說明與版本紀錄）。

## 目前版本

- Windows 0.3.5：單一 EXE 安裝包（per-user，Inno Setup，`windows-setup.iss`）。
- Mac 0.3.4：固定簽章；打包需設定 `BARRIER_CODESIGN_IDENTITY`，更新前用 `verify-macos-update.py` 驗證。

## 最近的工作

### 游標在跨畫面時來回彈跳（Windows → Windows 實機回報）

- 症狀：游標在兩台的邊界來回跳，進到另一台之後就正常。測試環境是主控端 2 個螢幕、接收端 1 個螢幕。
- 原因：切換畫面時，游標被放在對方螢幕最外側的那 1 個像素，手稍微往回動 1–2 px 就會立刻切回去。
- `6e471969`：新增測試 `--clipboard-edge-jitter`（進入後先往回 2 px 再往前，不能觸發 COUT），在 server 角色的四個方向都會跑。只加了測試、還沒修程式，所以 CI 失敗。
- `ec4d8249`：修正。`Server.cpp` 新增 `insetEntry()`，把原本只用在原生檔案拖曳的 16 px 內縮，套用到所有滑鼠觸發的畫面切換（主控端 → 接收端、接收端 → 主控端或其他畫面）。刻意往回移動（測試中是 64 px）仍然會正常切回。

## 待辦

1. ~~確認 `ec4d8249` 的 CI 通過~~：已通過（run 43144214817，Windows 和 macOS 都成功）。
2. 實機驗收：Windows → Windows，主控端多螢幕，四個方向都要慢慢貼邊來回移動，確認不再彈跳、刻意切回仍正常。
3. 通過後發 Windows 0.3.6，並更新 `GUI-README.txt` 的版本紀錄。這次修改在核心，Mac 的 `barriers` 也會受益；如果 Mac 當主控端，需要另外打包 Mac 版。
4. 已知限制（見 README）：一次只能連一台、只支援 IPv4 同網段、Mac App 未公證、自動測試不能取代兩台實機的驗收。

## 開發注意事項

- Windows 建置需要 CMake、MSVC 和 vcpkg 靜態 OpenSSL，完整步驟在 `.github/workflows/native-file-drop.yml`。
- Windows 整合測試會實際移動游標、操作 Explorer 和系統剪貼簿，不要在正在使用的電腦上跑；以 CI（Windows Server 2022）為準。
- CI 只在 PR 有變更 `src/**`、`tools/native-file-drop/**`、`CMakeLists.txt` 或 workflow 時觸發。
