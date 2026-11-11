# Barrier Share：Windows 雙向檔案複製與跨機拖放驗證版

## Windows 雙向 Ctrl+C／Ctrl+V（新版圖形介面）

兩台都使用完整新版，停止舊 CMD 程式後雙擊 `BarrierShare.exe`。選擇主控／接收端，接收端填主控端的區網 IP。主控端在左、接收端在右。設定與配對存於 `%LOCALAPPDATA%\BarrierShare`；將新版放入舊包資料夾可自動沿用配對，或按「沿用舊版配對」選擇舊包資料夾，不必重貼 v2 指紋。首次配對會顯示另一台的憑證識別碼，核對後才信任。

在任一台檔案總管選取一個檔案並 Ctrl+C，移到另一台的目標資料夾 Ctrl+V。兩個方向都保留原檔，每次一個一般檔案、最大 16 MiB，尚未支援資料夾、多檔或 macOS 檔案剪貼簿。文字剪貼簿及鍵鼠共享保留。GUI 開啟 `--file-clipboard` 與剪貼簿同步，預設不啟用拖曳；舊 CMD 啟動器仍維持以下拖曳驗證模式。完整操作見 [GUI-README.txt](GUI-README.txt)。

新增的檔案剪貼簿格式透過既有雙向 TLS 剪貼簿協定傳輸；接收端檢查長度、安全檔名與 SHA-256，寫入本機獨立暫存資料夾後，以 Windows `CF_HDROP` 提供 Explorer 貼上。只宣告 COPY，不移除來源。GUI 可在停止後清理暫存；清理前已貼出的檔案不受影響。

`windows-clipboard-network-test.py` 分別啟動正式 Windows server/client 與模擬 TLS 對端，在真正 Explorer 執行複製和貼上，以不同的本機／遠端位元組排除誤用舊剪貼簿，確認兩個角色的送收及原檔保留。GUI 自我測試檢查設定保存、中文路徑、舊憑證與信任匯入、隱藏背景程式啟停及畫面繪製。自動測試不替代 Windows 10／11 兩台實機驗收。

## 先前的拖曳驗證模式

這是修改過的 Barrier 主程式。以主控端的鍵盤滑鼠操作兩台電腦，在 Mac Finder 或 Windows 檔案總管按住檔案拖過主控端右邊界，繼續拖到接收端 Windows 檔案總管的目的資料夾並放開。目的地由檔案總管決定，沒有固定收件資料夾。

目前範圍：Apple Silicon Mac 或 Windows 10（1903 以上）／11 x64 當主控端（server）、Windows x64 當接收端（client），同一區域網路，單個一般檔案最多 16 MiB，只複製、不刪除來源原檔。目前方向為主控端 → 接收端；從接收端拖回主控端、資料夾、多檔及符號連結尚未支援。這是待雙機實測的開發版本，並非已證實在所有桌面環境正常運作的正式版。

此驗證版的啟動設定暫停跨機剪貼簿同步（`clipboardSharing = false`），避免大量剪貼簿資料與鍵鼠共用連線而造成輸入延遲或逾時。兩台之間的複製貼上暫不可用；每台電腦內的複製貼上、鍵盤滑鼠轉送及獨立的原生拖檔功能仍保留。

## Windows → Windows

1. 先關閉兩台原有的 Barrier。兩台都下載完整的 Windows 套件，各解壓到新的資料夾。這次需包含 `barriers.exe` 與 `Start-Windows-Server.cmd`；先前只有接收端的更新包不能用來當主控端。
2. 連接你要使用的鍵盤滑鼠那台開 `Start-Windows-Server.cmd`，另一台開 `Start-Windows.cmd`。接收端在主控端的右側。
3. 互相貼上兩邊顯示的 `v2:sha256:...` 配對碼。接收端輸入主控端的區網 IPv4 位址。Windows 防火牆若詢問，允許主控端 `barriers.exe` 在私人區網接收連線。
4. 兩邊都以一般使用者執行，保持啟動視窗開著。先確認鍵盤滑鼠可以跨機。
5. 接收端打開目的資料夾，在主控端 Explorer 按住一個小檔案，拖過右邊界後繼續保持按住，在另一台 Explorer 的目的資料夾空白處放開。檔案應出現，原檔仍保留。
6. 主控端紀錄在 `profile-server/server.log`，接收端在 `profile/windows.log`。兩個 profile 含各自私鑰，請勿在兩台間複製或上傳。不同主控端的第一次配對，請使用新的解壓資料夾，避免誤用既有 Mac 的信任設定。

## Mac → Windows：兩端準備

1. 停止兩台原有的 Barrier。分別解壓縮 `barrier-cross-drop-macos-arm64.zip` 和 `barrier-cross-drop-windows-x64.zip`；不要在 ZIP 內執行。
2. Mac 開啟 `Start-Mac.command`，Windows 開啟 `Start-Windows.cmd`。兩邊都會顯示自己的 `v2:sha256:...` 憑證指紋。
3. 將 **Windows 顯示的完整指紋**貼進 Mac 視窗，將 **Mac 顯示的完整指紋**貼進 Windows 視窗。請以另一台實際顯示的內容為準。指紋是公開配對資料；不要交換 `profile/SSL/Barrier.pem`，它含私鑰。配對只需一次；要重新配對可移走本測試包的 `profile` 資料夾後重開。
4. Windows 輸入 Mac 視窗列出的區網 IP。若有多個地址，使用與 Windows 同網段的一個。讓兩個終端視窗持續開啟。
5. 在 Mac「系統設定 → 隱私權與安全性」允許本資料夾的 `barriers` 使用「輔助使用」和「輸入監控」，之後重新執行啟動檔。若無權限，程式會報錯，不會繼續攔截輸入。若 macOS 擋住下載程式，先確認這是你自己的 GitHub Actions 編譯產物，再到「隱私權與安全性」允許開啟；未做 Apple 公證。
6. 防火牆若詢問，允許 Mac 的 `barriers` 在私人區網接收 TCP 24800；Windows `barrierc` 只需連到 Mac。Windows 以一般使用者執行，不用系統管理員或服務模式。

## 第一次跨機測試

1. Windows 先在檔案總管打開一個空的測試資料夾。
2. 先不拿檔案，把 Mac 滑鼠移出螢幕右側，確認能操作 Windows；從 Windows 左側可回到 Mac。
3. 在 Finder 選一個小檔案，按住滑鼠左鍵，拖過 Mac 右邊界。**保持按住，等 Windows 出現可拖曳檔案的游標，再移到目標資料夾放開。** 第一版會先傳完檔案，交界處可能稍停。
4. 檔案應出現在你放下的位置，Mac 原檔仍保留。同名檔由檔案總管的覆蓋確認處理。
5. 再試中文檔名、不同資料夾，以及按 Esc 取消。取消、斷線、回到 Mac、超過 60 秒未放下均會取消尚未完成的 Windows 拖曳。交接前放太快會取消，重新拖即可。
6. 比對完整性：Mac `shasum -a 256 "檔案路徑"`；Windows PowerShell `Get-FileHash -Algorithm SHA256 "檔案路徑"`，兩者雜湊應相同。

按 Ctrl+C 停止。記錄分別在 `profile/mac.log`、`profile/windows.log`。成功傳完會記錄 `sent`、`received and verified`；Windows 檔案總管接受複製會記錄 `copy accepted`。這個訊息不替代實際檔案／雜湊確認。

## 實作與自動驗證

只有檔案拖到邊界時才會暫時建立近乎透明的原生接收視窗，以取得 Explorer 的拖曳資料；它不執行本機移動或複製。擷取後以標記過的取消事件結束本機拖曳，這些內部事件不會轉送成另一台的按鍵或放開動作。

新增選項 `--native-file-drop`，兩端都需開啟；禁用 TLS 時拒絕啟動。Windows 握手後宣告接收能力。檔案分成最多 64 KiB 的訊息，走既有互驗憑證的 TLS 連線，綁定本次切換序號。接收端檢查大小、檔名、序號、完整長度和 SHA-256，通過後才交給 Windows OLE 的 `FILEDESCRIPTORW`／`FILECONTENTS`。檔案總管在放下的位置取資料；不把遠端路徑當成本機寫入路徑。

`native-transfer-test` 使用主程式同一份送收程式測試空檔、二進位、中文／emoji、16 MiB、拒收損毀與越界封包、過期序號與取消狀態。`windows-cli-network-test.py` 啟動真正的 Windows client，經雙向驗證憑證的 TLS 接收主程式送出格式，再將資料拖放到原生測試接收視窗。Windows 的 `native-windows-drop-test` 測試遠端放開與取消，也使用 Windows 真正的資料夾接收器驗證落檔。`native-windows-explorer` 會另開真正的 Explorer 視窗，以正式拖放程式拖入中文檔名的二進位測試檔，並核對寫入內容；失敗會保留測試桌面截圖。`native-windows-source` 另外從真正 Explorer 拖出檔案，測試中文路徑、原檔保留與多檔拒收；`windows-server-network-test.py` 讓正式 Windows 主控程式從螢幕邊界擷取 Explorer 拖曳，經雙向 TLS 傳送，再驗證檔案內容與實際放開訊息。這些自動測試仍不能取代兩台實機的完整操作驗收。

建置：CMake，關閉 GUI／installer／舊測試，開啟 `BARRIER_USE_SYSTEM_OPENSSL` 和 `BARRIER_NATIVE_DROP_TESTS`。Windows 使用 vcpkg `openssl:x64-windows-static` 和 `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`；Mac 使用 arm64 OpenSSL 靜態函式庫。完整建置參數見 `.github/workflows/native-file-drop.yml`。
