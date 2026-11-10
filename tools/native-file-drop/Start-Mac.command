#!/bin/bash
set -e
cd "$(dirname "$0")"
ROOT="$PWD"
PROFILE="$ROOT/profile"
echo 'Barrier Mac -> Windows native file drop preview'
echo 'Mac fingerprint (copy this to the Windows setup window):'
./barrier-pair init "$PROFILE"
if [ ! -s "$PROFILE/SSL/Fingerprints/TrustedClients.txt" ]; then
    read -r -p 'Paste the Windows fingerprint here: ' PEER
    ./barrier-pair trust "$PROFILE" client "$PEER"
fi
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
CONFIG
echo 'Mac LAN addresses (enter the appropriate one on Windows):'
/usr/sbin/ipconfig getifaddr en0 || true
/usr/sbin/ipconfig getifaddr en1 || true
echo 'Windows is to the RIGHT of Mac. Keep holding the mouse until its file cursor appears.'
echo 'Allow Accessibility and Input Monitoring for this barriers executable if macOS asks.'
echo 'Press Ctrl+C to stop. Log: profile/mac.log'
./barriers -f --no-tray --name mac --native-file-drop --profile-dir "$PROFILE" -c "$PROFILE/mac-windows.conf" --log "$PROFILE/mac.log"
