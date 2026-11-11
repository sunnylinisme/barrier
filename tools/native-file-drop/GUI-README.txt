Barrier Share — Windows／Mac 雙向複製通用測試版

支援 Windows 10（1903 以上）／11 x64，以及 Apple Silicon Mac（macOS 15 以上）。
一次連接兩台，可自由搭配作主控端或接收端；兩台必須更新到本版，並在同一區網。

啟動與沿用配對
1. 先停止舊版連線程式，避免同時執行兩份。
2. Windows：解壓縮後雙擊 BarrierShare.exe。
   Mac：解壓縮後將 Barrier Share.app 放到「應用程式」，再開啟。
   這是未公證的測試版，若被 macOS 阻擋，請在「系統設定 → 隱私權與安全性」選「仍要打開」。
   在「輔助使用」與「輸入監控」允許 Barrier Share；若系統列出 barriers／barrierc，也需允許。完成後重開程式。
3. 有實體滑鼠鍵盤的那台選「主控端」；另一台選「接收端」，填入主控端列出的區網 IPv4。
   兩台都可使用 Windows 或 Mac。主／副只決定鍵鼠來源，不限制複製方向。
4. 曾經配對：選好角色後按「沿用舊版配對」，選舊測試包資料夾（含 profile／profile-server）。
   設定與配對會保存，之後更新不用重貼 v2 識別碼。
5. 首次配對：兩台按「開始連線」，核對對方視窗的識別碼後按信任；不需要手動輸入識別碼。
   Windows 防火牆若詢問，允許 barriers.exe 使用私人網路。

設定螢幕位置
在主控端選「接收端位置」：右、左、上、下。停止連線後即可更改並重新連線。
位置以主控端為準，接收端自動使用相反方向返回。

雙向複製檔案與資料夾
在來源電腦的 Finder／檔案總管選取檔案或資料夾並複製：Mac 用 ⌘C，Windows 用 Ctrl+C。
將游標移到另一台，等該台視窗顯示「已收到檔案」，在目標資料夾貼上：Mac 用 ⌘V，Windows 用 Ctrl+V。
兩個方向均可，原檔保留；可選多檔、整個資料夾（含空資料夾）。不需要拖曳，本版介面不啟用拖曳。
跨系統操作時使用目的端的快捷鍵：Mac 鍵盤上的 Command 對應 Windows 鍵，Control 對應 Ctrl；Windows 鍵盤的 Windows 鍵對應 Mac Command。
文字剪貼簿及鍵盤、滑鼠共享同時啟用。

檔案分成 64 KiB 區塊傳輸，逐檔 SHA-256 校驗；移除原本單檔 16 MiB 限制，大小使用 64 位元。
大檔案需等待傳送完成才可貼上。可用磁碟空間、檔案系統限制及區網速度仍適用。
接收端會先存一份暫存，貼上時再複製到目的地，因此需預留兩份空間。
來源在傳送時請勿修改。中斷連線或複製新的內容會取消未完成傳送，重連後請重新複製。
不支援符號連結、特殊檔案、Windows 不接受的檔名；一次選取最多 4096 個頂層項目、共 100 萬個項目、128 層目錄。
保留檔案內容與目錄結構；不保證保留 ACL、延伸屬性、時間戳記或執行權限。本版不是系統備份工具。

關閉視窗後仍在系統匣／Mac 選單列執行，選「結束」才停止。
接收檔案暫存會保留供貼上；停止連線後可按「清除檔案暫存」。
清除會使尚未貼上的接收檔案失效，已貼到其他資料夾的檔案不受影響。
Windows 設定：%LOCALAPPDATA%\BarrierShare
Mac 設定：~/Library/Application Support/BarrierShare
日誌位於上述資料夾的 profile-server/server.log 或 profile/windows.log（Mac 為 mac.log）。

驗證範圍：自動化 Windows 原生剪貼簿與實際檔案總管貼上、雙向 TLS 傳輸、四個螢幕方向；Mac 原生檔案剪貼簿及視窗程式。
兩台實體 Windows／Mac 的完整操作仍需實機驗收；目前只提供 Windows x64 與 Mac arm64。
來源與授權：https://github.com/sunnylinisme/barrier/tree/prototype/native-file-drop
GPL-2.0-or-later；依附元件授權見 licenses（Mac 位於 app 的 Contents/Resources）。
