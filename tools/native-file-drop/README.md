# Barrier Share：Windows／Mac 雙向複製通用測試版

Windows 10（1903 以上）／11 x64 與 Apple Silicon Mac（macOS 15 以上）可以任選主控／接收角色，雙向複製多個檔案或資料夾。主控端可設定接收端在右、左、上、下；兩台更新同版後使用原生視窗程式，無需 CMD。完整操作、配對遷移、暫存清理與限制見 [GUI-README.txt](GUI-README.txt)。

Windows 開啟 `BarrierShare.exe`，Mac 開啟 `Barrier Share.app`。主／副角色只決定鍵鼠來源，不限制複製方向。舊包配對可匯入；設定分別保存在 `%LOCALAPPDATA%\BarrierShare` 與 `~/Library/Application Support/BarrierShare`。首次連線仍需核對憑證，之後記住信任。

## 檔案剪貼簿

`--file-clipboard` 以 `FCAP` 協商版本 2，使用既有互驗憑證的 TLS 連線。OS 剪貼簿中的檔案路徑只在本機註冊為短期 capability，不會把本機路徑或 capability 當成遠端可存取路徑。檔案內容使用獨立的 FC* 訊息；每次傳送 64 KiB，收到 ACK 才送下一段，避免整個檔案塞入記憶體或網路輸出佇列，保留鍵鼠與心跳處理機會。

大小使用 64 位元，移除原本單檔 16 MiB 上限；逐檔 SHA-256 校驗、長度驗證與來源變更檢查。接收端驗證相對路徑，拒絕符號連結、特殊檔案、不相容檔名或衝突名稱，寫入獨立暫存，整批成功後才發布剪貼簿。取消、斷線或校驗失敗會清除未完成暫存；已完成的暫存供後續貼上，使用者可從 GUI 清理。沒有搬移或刪除來源操作。

Windows 使用 `CF_HDROP` 與 COPY 效果，Mac 使用原生檔案 URL。檔案內容與目錄結構會保留，但不保證 ACL、時間戳、延伸屬性與執行權限。每次最多 4096 個選取項目、100 萬個總項目、128 層目錄；磁碟空間與檔案系統限制仍適用。接收完才可貼上，沒有續傳。

## 驗證

- `file-clipboard-stream`：96 MiB 二進位、資料夾／空資料夾、多檔、64 KiB 佇列上界、超過 4 GiB 的檔案大小標頭、損毀／取消／路徑穿越拒絕。
- `mac-file-clipboard`：獨立原生 Pasteboard 的檔案 URL 擷取、32 MiB 以上傳輸、接收發布及避免回送，不修改使用者的系統剪貼簿。
- `native-windows-clipboard`：真正的 Windows 檔案剪貼簿，多檔與資料夾實際貼進 Explorer。
- `windows-clipboard-network-test.py`：正式 Windows server/client 與模擬 TLS 對端互傳 64／32 MiB 檔案；四個螢幕方向、Explorer 複製／貼上、來源保留、校驗與心跳／游標訊息交錯。
- 兩套 GUI 自我測試：設定保存、四個方向、舊憑證與信任匯入、後端位置與畫面繪製。

上述自動測試不替代 Windows 10／11 與 Mac 的兩台實體電腦完整操作驗收。macOS App 未公證，需自行允許開啟並授予輔助使用與輸入監控權限。

## 建置與舊拖曳模式

完整流程見 `.github/workflows/native-file-drop.yml`。CMake 關閉原 Qt GUI／installer／舊測試，開啟 `BARRIER_USE_SYSTEM_OPENSSL` 和 `BARRIER_NATIVE_DROP_TESTS`。Windows 用 vcpkg 靜態 OpenSSL 與系統內建 .NET Framework 編譯 WinForms；Mac 用系統 Swift/AppKit，`package-macos.sh` 建立含後端與依附庫的獨立 App。發布包只包含視窗程式、必要後端與授權，不再包含命令列啟動器。

先前 `--native-file-drop` 的單向拖曳預覽保留在核心及回歸測試，GUI 不啟用。它仍限 Mac／Windows 主控端 → Windows 接收端，單個檔案最多 16 MiB；此限制不適用於新的檔案剪貼簿。早期單機拖曳 probe 與其 CI 已移除，歷史版本仍可從 Git 取得。
