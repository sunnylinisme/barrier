# Barrier 跨機拖放：Mac → Windows 驗證版

這是修改過的 Barrier 主程式。以 Mac 的鍵盤滑鼠操作兩台電腦，在 Finder 按住檔案拖過 Mac 右邊界，繼續拖到 Windows 檔案總管的目的資料夾並放開。目的地由檔案總管決定，沒有固定收件資料夾。

目前範圍：Apple Silicon Mac 當 server、Windows 10（1903 以上）／11 x64 當 client，同一區域網路，單個一般檔案最多 16 MiB，只複製、不刪除 Mac 原檔。資料夾、多檔、符號連結、Windows → Mac 及 Windows → Windows 尚未實作。這是待雙機實測的開發版本，並非已證實在所有桌面環境正常運作的正式版。

此驗證版的啟動設定暫停跨機剪貼簿同步（`clipboardSharing = false`），避免大量剪貼簿資料與鍵鼠共用連線而造成輸入延遲或逾時。兩台之間的複製貼上暫不可用；每台電腦內的複製貼上、鍵盤滑鼠轉送及獨立的原生拖檔功能仍保留。

## 兩端準備

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

新增選項 `--native-file-drop`，兩端都需開啟；禁用 TLS 時拒絕啟動。Windows 握手後宣告接收能力。檔案分成最多 64 KiB 的訊息，走既有互驗憑證的 TLS 連線，綁定本次切換序號。接收端檢查大小、檔名、序號、完整長度和 SHA-256，通過後才交給 Windows OLE 的 `FILEDESCRIPTORW`／`FILECONTENTS`。檔案總管在放下的位置取資料；不把遠端路徑當成本機寫入路徑。

`native-transfer-test` 使用主程式同一份送收程式測試空檔、二進位、中文／emoji、16 MiB、拒收損毀與越界封包、過期序號與取消狀態。`windows-cli-network-test.py` 啟動真正的 Windows client，經雙向驗證憑證的 TLS 接收主程式送出格式，再將資料拖放到原生測試接收視窗。Windows 的 `native-windows-drop-test` 測試遠端放開與取消，也使用 Windows 真正的資料夾接收器驗證落檔。`native-windows-explorer` 會另開真正的 Explorer 視窗，以正式拖放程式拖入中文檔名的二進位測試檔，並核對寫入內容；失敗會保留測試桌面截圖。這些自動測試仍不能取代兩台實機的 Finder → Explorer 操作驗收。

建置：CMake，關閉 GUI／installer／舊測試，開啟 `BARRIER_USE_SYSTEM_OPENSSL` 和 `BARRIER_NATIVE_DROP_TESTS`。Windows 使用 vcpkg `openssl:x64-windows-static` 和 `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`；Mac 使用 arm64 OpenSSL 靜態函式庫。完整建置參數見 `.github/workflows/native-file-drop.yml`。
