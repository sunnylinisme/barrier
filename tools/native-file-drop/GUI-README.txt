Barrier Share — Windows 雙向檔案複製測試版

兩台都更新到這個完整版本。請先停止舊的 CMD 版本。
解壓縮後雙擊 BarrierShare.exe；不必再開 CMD。

舊版已配對：
  可把完整新版檔案放進原本測試包資料夾（保留 profile / profile-server）。
  第一次啟動會沿用該資料夾的配對。
  若解壓到另一個資料夾，選好這台角色，按「沿用舊版配對」，選舊測試包資料夾。
  本機設定改存於 %LOCALAPPDATA%\BarrierShare，之後更新不用重貼 v2 識別碼。

第一次使用：
  有實體滑鼠鍵盤的那台選「主控端」，按開始連線。
  另一台選「接收端」，輸入主控端視窗列出的區網 IPv4，按開始連線。
  若顯示首次配對視窗，核對另一台的本機識別碼，相同再按「是」。兩台可能各詢問一次。
  Windows 防火牆如詢問，允許 barriers.exe 使用私人網路。

雙向複製檔案：
  在任一台檔案總管選取一個檔案，Ctrl+C。
  把滑鼠移到另一台，在目標資料夾 Ctrl+V。
  主控端 → 接收端、接收端 → 主控端均可；原檔保留。
  每次一個一般檔案，最大 16 MiB；本版不支援資料夾或多檔。
  先用小檔案測試。文字剪貼簿與鍵盤、滑鼠共享也會啟用。
  接收端固定在主控端右邊。這個介面預設不啟用拖曳功能。
  關閉連線中的視窗會縮到右下角；從圖示選「結束」才停止程式。

接收檔案會暫存在本機設定的 ClipboardCache，停止連線後可按「清除檔案暫存」。
清除會使尚未貼上的接收檔案無法貼上；已貼到其他資料夾的檔案不受影響。
日誌位於 %LOCALAPPDATA%\BarrierShare\profile-server\server.log 或 profile\windows.log。
舊 CMD 啟動器僅保留作拖曳版本相容用途；雙向檔案複製請用 BarrierShare.exe。

本版僅實作 Windows 檔案剪貼簿。macOS 檔案雙向複製尚未納入此介面。
Windows 10（1903 以上）/ 11 x64；使用 Windows 隨附的 .NET Framework 4.x，不需要額外的 Qt 執行環境。
來源與授權：https://github.com/sunnylinisme/barrier/tree/prototype/native-file-drop
GPL-2.0-or-later；依附元件授權見 licenses。
