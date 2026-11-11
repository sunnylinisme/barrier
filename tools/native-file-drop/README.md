# Barrier Share：Windows／Mac 雙向複製通用測試版

Windows 10（1903 以上）／11 x64 與 Apple Silicon Mac（macOS 15 以上）可以任選主控／接收角色，雙向複製多個檔案或資料夾。主控端可設定接收端在右、左、上、下；兩台更新同版後使用原生視窗程式，無需 CMD。完整操作、區網搜尋與配對、暫存清理與限制見 [GUI-README.txt](GUI-README.txt)。

Windows 開啟 `BarrierShare.exe`，Mac 開啟 `Barrier Share.app`。主／副角色只決定鍵鼠來源，不限制複製方向。主控端從區網電腦清單邀請接收端，兩邊核對 TLS 綁定的 6 位數短碼並同意；之後以已保存憑證自動重連。無需輸入 IP 或指紋。設定分別保存在 `%LOCALAPPDATA%\BarrierShare` 與 `~/Library/Application Support/BarrierShare`。主介面提供暫停與解除配對。

## 區網搜尋、同意與重連

兩套原生 GUI 使用同一個 `barrier-link` 輔助程式。IPv4 UDP 24801 搜尋只提供名稱／位址／憑證指紋提示，不授予信任。主控端對選取的接收端建立 TCP 24801 雙向憑證 TLS 連線，核對搜尋得到的憑證，並透過 TLS exporter 產生當次連線的 6 位數核對碼。雙方各自明確同意後才保存對方的真實 TLS 憑證指紋；鍵鼠與剪貼簿程式在此之前不啟動。

已配對電腦重新被搜尋到時，以保存的指紋驗證新的 TLS 連線；只有雙方仍記住彼此才通知 GUI 啟動／重連 Barrier。接收端使用經驗證的 TCP 對端 IP，因此 DHCP 位址改變不必重新輸入。偽造名稱／搜尋封包不能直接替換信任或啟動控制。解除配對會清除目前角色的 peer 記錄與信任；拒絕、逾時或單方同意不建立新信任。一次一個對端、同一 IPv4 廣播網域，未實作跨子網或 VPN 探索。

`link-network-test.py` 在隔離 loopback 端點啟動真正的輔助程式，驗證搜尋、相同 TLS 短碼、雙方同意、拒絕、保存、重開後自動連線與解除配對。測試不啟動鍵鼠攔截。GUI 自我測試另檢查清單更新／移除，以及關閉過期配對視窗。

## 檔案剪貼簿

`--file-clipboard` 以 `FCAP` 協商版本 2，使用既有互驗憑證的 TLS 連線。OS 剪貼簿中的檔案路徑只在本機註冊為短期 capability，不會把本機路徑或 capability 當成遠端可存取路徑。檔案內容使用獨立的 FC* 訊息；每次傳送 64 KiB，收到 ACK 才送下一段，避免整個檔案塞入記憶體或網路輸出佇列，保留鍵鼠與心跳處理機會。

大小使用 64 位元，移除原本單檔 16 MiB 上限；逐檔 SHA-256 校驗、長度驗證與來源變更檢查。接收端驗證相對路徑，拒絕符號連結、特殊檔案、不相容檔名或衝突名稱，寫入獨立暫存，整批成功後才發布剪貼簿。取消、斷線或校驗失敗會清除未完成暫存；已完成的暫存供後續貼上，使用者可從 GUI 清理。沒有搬移或刪除來源操作。

Windows 使用 `CF_HDROP` 與 COPY 效果，Mac 使用原生檔案 URL。檔案內容與目錄結構會保留，但不保證 ACL、時間戳、延伸屬性與執行權限。每次最多 4096 個選取項目、100 萬個總項目、128 層目錄；磁碟空間與檔案系統限制仍適用。接收完才可貼上，沒有續傳。

## 驗證

- `file-clipboard-stream`：96 MiB 二進位、資料夾／空資料夾、多檔、64 KiB 佇列上界、超過 4 GiB 的檔案大小標頭、損毀／取消／路徑穿越拒絕。
- `mac-file-clipboard`：兩個獨立原生 Pasteboard 的檔案 URL 擷取、32 MiB 以上程序內傳輸、接收發布及避免回送；不啟動正式核心／TLS，也不等同 Finder 實際貼上，不修改使用者的系統剪貼簿。
- `native-windows-clipboard`：真正的 Windows 檔案剪貼簿，多檔與資料夾實際貼進 Explorer。
- `windows-clipboard-network-test.py`：每次啟動一個正式 Windows server 或 client，與 Python 模擬 TLS 對端互傳 64／32 MiB 檔案，並實際在 Explorer 複製／貼上。兩種角色均測右／左／上／下：server 由本機游標越界觸發，client 由模擬主控傳送對應邊緣的進入／返回座標，並讀取原生游標位置驗證。另驗證來源保留、校驗與心跳／游標訊息交錯；這不是兩個正式核心或兩台電腦的端到端測試，CI 使用 Windows Server 2022。
- 兩套 GUI 自我測試：設定保存、四個方向的設定產生、舊憑證與信任匯入、後端位置與畫面繪製；不代表四向實機鍵鼠操作已通過。

上述自動測試不替代 Windows 10／11 與 Mac 的兩台實體電腦完整操作驗收。macOS App 未公證，需自行允許開啟並授予輔助使用與輸入監控權限。

## 建置與舊拖曳模式

完整流程見 `.github/workflows/native-file-drop.yml`。CMake 關閉原 Qt GUI／installer／舊測試，開啟 `BARRIER_USE_SYSTEM_OPENSSL` 和 `BARRIER_NATIVE_DROP_TESTS`。Windows 用 vcpkg 靜態 OpenSSL 與系統內建 .NET Framework 編譯 WinForms；Mac 用系統 Swift/AppKit，`package-macos.sh` 建立含後端與依附庫的獨立 App。發布包只包含視窗程式、必要後端與授權，不再包含命令列啟動器。

Mac 打包必須明確指定 `BARRIER_CODESIGN_IDENTITY`（鑰匙圈中的簽章憑證名稱或 SHA-1）。App 與內附程式沿用固定識別碼，更新時應沿用同一個開發者身分；指定身分無法簽章時會停止，不會自動降回臨時簽章。憑證私鑰留在本機鑰匙圈，不放進原始碼或封裝。

```sh
BARRIER_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
  sh tools/native-file-drop/package-macos.sh build
```

本機開發驗證可使用既有 Apple Development 憑證；公開發佈使用 Developer ID Application 並另行完成 Apple 公證。CI 明確指定 `BARRIER_CODESIGN_IDENTITY=-` 只產生臨時簽章測試包，不能當成可保留授權的正式更新包。從既有臨時簽章遷移到固定憑證仍可能需要重新授權一次；後續須驗證新版本符合舊版本的 designated requirement，並做實機授權保留驗收。詳見 [Apple：Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。

發布固定簽章更新前執行 `python3 tools/native-file-drop/verify-macos-update.py OLD_APP NEW_APP`。它會驗證 App、全部 helper 和內附函式庫的簽章及雙向身分相容性；臨時簽章、身分不符或程式清單變更會拒絕。此檢查不執行 App，也不變更系統權限。

先前 `--native-file-drop` 的單向拖曳預覽保留在核心及回歸測試，GUI 不啟用。它仍限 Mac／Windows 主控端 → Windows 接收端，單個檔案最多 16 MiB；此限制不適用於新的檔案剪貼簿。早期單機拖曳 probe 與其 CI 已移除，歷史版本仍可從 Git 取得。
