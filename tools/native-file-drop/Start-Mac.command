#!/bin/bash
set -u
cd "$(dirname "$0")" || exit 1
ROOT="$PWD"
PROFILE="$ROOT/profile"
fail() {
    printf '\n啟動失敗，請保留上方錯誤文字。按 Enter 關閉。\n'
    read -r _
    exit 1
}
printf '\nBarrier 跨機拖放：Mac → Windows\n'
printf '步驟 1／3：以下是這台 Mac 的配對碼，請完整貼到 Windows 啟動視窗。\n\n'
LOCAL=$(./barrier-pair init "$PROFILE") || fail
printf '%s\n\n' "$LOCAL"
while [ ! -s "$PROFILE/SSL/Fingerprints/TrustedClients.txt" ]; do
    printf '步驟 2／3：在 Windows 開啟 Start-Windows.cmd，複製它顯示的 v2:sha256: 開頭整行。\n'
    printf '請在這裡貼上 Windows 配對碼，再按 Enter（不是 IP 位址）：\n> '
    read -r PEER || exit 1
    PEER=${PEER%$'\r'}
    if [ "$PEER" = "$LOCAL" ]; then
        printf '這是 Mac 自己的配對碼。請改貼 Windows 視窗顯示的那一行。\n\n'
        continue
    fi
    case "$PEER" in
        v2:sha256:*) ;;
        *) printf '格式不對，配對碼要以 v2:sha256: 開頭。可以重新貼上。\n\n'; continue ;;
    esac
    if ! ./barrier-pair trust "$PROFILE" client "$PEER"; then
        printf '配對碼未儲存，請確認整行完整，再重新貼上。\n\n'
    fi
done
cat > "$PROFILE/mac-windows.conf" <<'CONFIG'
section: screens
    mac:
    windows:
end
section: links
    mac:
        right = windows
    windows:
        left = mac
end
section: options
    clipboardSharing = false
end
CONFIG
printf '\n步驟 3／3：請在 Windows 輸入這台 Mac 的區網 IP：\n'
/usr/sbin/ipconfig getifaddr en0 || true
/usr/sbin/ipconfig getifaddr en1 || true
printf '\n現在啟動 Mac 主程式，等待 Windows 連入。請保持兩邊視窗開啟。\n'
printf '看到 client "windows" has connected 才代表連線成功，之後游標可移出 Mac 右邊界。\n'
printf '若出現 event tap 錯誤，請在系統設定允許輔助使用／輸入監控，再重新啟動。\n'
printf '權限清單可能顯示 barriers 或終端機（Terminal）。記錄檔：profile/mac.log\n'
printf '本驗證版暫停跨機剪貼簿同步，鍵盤滑鼠與原生拖檔仍啟用。\n'
printf '按 Ctrl+C 停止。\n\n'
./barriers -f --no-tray --name mac --native-file-drop --profile-dir "$PROFILE" -c "$PROFILE/mac-windows.conf" --log "$PROFILE/mac.log"
STATUS=$?
printf '\nMac 主程式已停止（結束碼 %s）。若尚未連線，請保留上方錯誤文字。按 Enter 關閉。\n' "$STATUS"
read -r _
exit "$STATUS"
