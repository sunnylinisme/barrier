# 原生檔案拖放：開發預覽 0.1

這是跨機拖放的**第一階段接收端驗證工具**，不是已完成的 Barrier 跨機版本。
目前可把工具內的測試檔直接拖進同一台電腦的 Finder／檔案總管資料夾。
內容在目的端請求時才產生，無需事先放在桌面或建立佔位檔。

**目前尚未連接網路、接手另一台的滑鼠拖曳，或傳送使用者檔案。**
既有 Barrier 程式沒有被此工具修改；啟用原本的拖放選項不會啟用本工具。

## 下載與測試

在本 fork 的 Actions 選擇成功的 `Native file drop preview` 執行：

- Apple Silicon Mac：下載 `native-drop-macos-arm64`，解壓縮內部 ZIP，開啟 `Barrier Drop Probe.app`。
- Windows 10／11 x64：下載 `native-drop-windows-x64`，解壓縮後開啟 `native-drop-probe.exe`。這是開發工具，會同時開啟主控台。

這些是未經開發者簽章／Apple 公證的測試包。若系統阻擋開啟，先保留訊息供排查；不需關閉系統防護。

1. 在 Finder／檔案總管開啟一個測試資料夾。
2. 把工具內的 `Barrier-拖放測試.txt` 拖進該資料夾空白處。
3. 確認檔案出現在選定的位置，且中文內容可讀。
4. 再拖一次，確認目的端處理同名檔案的方式；不要使用重要檔案做覆寫測試。
5. 拖曳途中按 Escape，確認沒有新增檔案。
6. 對不同資料夾重複操作，確保沒有沿用上次的接收路徑。

若已安裝 Python，可檢查完整位元組：

```text
python verify-drop.py "完整路徑/Barrier-拖放測試.txt"
```

請記錄：作業系統版本、處理器、目的資料夾、是否成功、同名行為、取消行為。
GUI 拖放測試與自動測試分開記錄；CI 通過不代表雙機測試已通過。

## 本機編譯

macOS 需要 Xcode Command Line Tools：

```sh
sh tools/native-drop-probe/build-macos.sh build/native-drop
```

Windows 需要 Visual Studio 2022 C++ Build Tools 和 CMake，於開發者終端執行：

```powershell
cmake -S tools/native-drop-probe -B build/native-drop -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
cmake --build build/native-drop --config Release
ctest --test-dir build/native-drop -C Release --output-on-failure
```

程式各自提供 `--self-test`。Mac 測試實際 promise 寫入、UTF-8 位元組、拒絕覆寫與錯誤回報；Windows 測試檔案描述、按需提供內容、可重複讀取的獨立串流、錯誤格式與取消。

## 接回 Barrier 的下一階段

最終驗收仍是：Mac → Windows、Windows → Mac、Windows → Windows，從來源資料夾按住一個檔案，跨過螢幕邊界並放進目的資料夾。

1. 修正來源檔案取得及中繼資料格式。舊 `MSWindowsScreen::send_drag_thread()` 直接傳路徑，與 `DragInformation::parseDragInfo()` 預期的檔名／大小格式不一致。
2. 以本工具驗證的 `NSFilePromiseProvider`／OLE `IDataObject` 取代舊 Windows 空白的 `fakeDraggingFiles()` 與固定桌面落檔邏輯。
3. 建立有識別碼的單檔傳輸生命週期，將網路收到的資料交給 promise／stream。跨螢幕後另一端建立拖曳時，必須保留滑鼠按住狀態並正確處理返回來源、Escape、斷線和遲到封包。
4. 加入有界緩衝與非同步傳輸，避免大檔佔滿記憶體或阻塞鍵鼠；保留配對與 TLS。
5. 於上述三個方向實測單檔、空檔、中文檔名、同名與取消，再擴充多檔和資料夾。

本工具刻意只產生小型固定測試檔；尚未驗證網路延遲、非同步 OLE 大檔傳輸、權限較高的目的端或任意應用程式。

## 原生介面依據

- [Apple：Supporting Table View Drag and Drop Through File Promises](https://developer.apple.com/documentation/AppKit/supporting-table-view-drag-and-drop-through-file-promises)
- [Microsoft：Shell Clipboard Formats](https://learn.microsoft.com/en-us/windows/win32/shell/clipboard)
- [Microsoft：Shell Data Object](https://learn.microsoft.com/en-us/windows/win32/shell/dataobject)
