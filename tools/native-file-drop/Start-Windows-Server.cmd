@echo off
setlocal
cd /d "%~dp0"
echo Barrier Windows host to Windows receiver - native file drop preview
echo Run this on the PC whose keyboard and mouse you use.
echo Host fingerprint (paste into the receiver's Start-Windows.cmd):
barrier-pair.exe init "%~dp0profile-server"
if errorlevel 1 goto failed
if exist "%~dp0profile-server\SSL\Fingerprints\TrustedClients.txt" goto configured
:pair
set /p "PEER=Paste the RECEIVER fingerprint here: "
barrier-pair.exe trust "%~dp0profile-server" client "%PEER%"
if errorlevel 1 goto pair
:configured
(
echo section: screens
 echo     windows-host:
 echo     windows:
 echo end
 echo section: links
 echo     windows-host:
 echo         right = windows
 echo     windows:
 echo         left = windows-host
 echo end
 echo section: options
 echo     clipboardSharing = false
 echo end
) > "%~dp0profile-server\windows-windows.conf"
echo Enter this PC's LAN IPv4 address on the receiver:
ipconfig | findstr /C:"IPv4"
echo Allow barriers.exe on the private LAN if Windows Firewall asks.
echo The receiver is to the RIGHT. Keep both launcher windows open.
echo Single regular file up to 16 MiB, COPY only, host to receiver.
barriers.exe -f --no-tray --name windows-host --native-file-drop --profile-dir "%~dp0profile-server" -c "%~dp0profile-server\windows-windows.conf" --log "%~dp0profile-server\server.log"
:failed
pause
