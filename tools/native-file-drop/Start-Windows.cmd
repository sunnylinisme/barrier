@echo off
setlocal
cd /d "%~dp0"
echo Barrier native file drop receiver (Mac or Windows host)
echo Windows fingerprint (copy this to the Mac setup window):
barrier-pair.exe init "%~dp0profile"
if errorlevel 1 goto failed
if exist "%~dp0profile\SSL\Fingerprints\TrustedServers.txt" goto address
set /p "PEER=Paste the HOST fingerprint here: "
barrier-pair.exe trust "%~dp0profile" server "%PEER%"
if errorlevel 1 goto failed
:address
set /p "SERVER=Host LAN address (example 192.168.1.20): "
echo Keep this window open. This receiver is to the RIGHT of the host.
echo Open a destination folder in File Explorer before dragging.
echo Press Ctrl+C to stop. Log: profile\windows.log
barrierc.exe -f --no-tray --name windows --native-file-drop --profile-dir "%~dp0profile" --log "%~dp0profile\windows.log" "%SERVER%"
:failed
pause
