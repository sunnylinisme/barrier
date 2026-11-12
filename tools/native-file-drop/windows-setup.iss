; SPDX-License-Identifier: GPL-2.0-or-later
; Compile with ISCC /DPackageDir=<absolute staged package> /DOutputDir=<absolute output>.
#ifndef PackageDir
  #error PackageDir must point to the validated Windows package directory.
#endif
#ifndef OutputDir
  #error OutputDir must be specified.
#endif
#define AppVersion "0.3.9"

[Setup]
AppId=org.barriershare.desktop
AppName=Barrier Share
AppVersion={#AppVersion}
AppPublisher=Barrier Share contributors
AppPublisherURL=https://github.com/sunnylinisme/barrier
AppSupportURL=https://github.com/sunnylinisme/barrier
DefaultDirName={localappdata}\Programs\Barrier Share
DefaultGroupName=Barrier Share
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.18362
SetupMutex=Local\BarrierShare.Setup
CloseApplications=no
RestartApplications=no
WizardStyle=modern
ShowLanguageDialog=auto
OutputDir={#OutputDir}
OutputBaseFilename=BarrierShare-Setup-{#AppVersion}-x64
SetupIconFile={#AddBackslash(SourcePath)}icons\BarrierShare.ico
UninstallDisplayName=Barrier Share
UninstallDisplayIcon={app}\BarrierShare.exe
VersionInfoVersion={#AppVersion}.0
Compression=lzma2
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesetraditional"; MessagesFile: "{#AddBackslash(SourcePath)}installer-languages\ChineseTraditional.isl"

[CustomMessages]
english.CloseFailed=Barrier Share could not be closed. Choose Exit from its notification-area icon and run Setup again.
chinesetraditional.CloseFailed=無法自動關閉 Barrier Share。請從右下角系統匣的圖示選擇「結束」，再重新執行安裝程式。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PackageDir}\BarrierShare.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barriers.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barrierc.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barrier-pair.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barrier-link.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\GUI-README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\COMMIT.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\licenses\*.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Barrier Share"; Filename: "{app}\BarrierShare.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Barrier Share"; Filename: "{app}\BarrierShare.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
; The app writes this value when "launch at sign-in" is ticked; uninstall removes it without ever creating it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "BarrierShare"; Flags: uninsdeletevalue dontcreatekey

[Run]
; A copy that was running before the update is started again, also for silent installs.
Filename: "{app}\BarrierShare.exe"; WorkingDir: "{app}"; Flags: nowait; Check: WasRunning
Filename: "{app}\BarrierShare.exe"; Description: "{cm:LaunchProgram,Barrier Share}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent unchecked; Check: not WasRunning

; Settings and pairing live in a separate LocalAppData\BarrierShare directory.
; No UninstallDelete entry: uninstall removes only this install's recorded files.

[Code]
const
  AppMutexName = 'Local\BarrierShare.Desktop';
  { BarrierShare.cs (ShareProgram.QuitEvent) waits on this event and exits cleanly. }
  QuitEventName = 'Local\BarrierShare.Quit';
var
  Running: Boolean;

function OpenEvent(Access: Cardinal; Inherit: Integer; Name: String): Cardinal; external 'OpenEventW@kernel32.dll stdcall';
function SetEvent(Handle: Cardinal): Integer; external 'SetEvent@kernel32.dll stdcall';
function CloseHandle(Handle: Cardinal): Integer; external 'CloseHandle@kernel32.dll stdcall';
function SystemParametersInfo(Action, Param, Value, WinIni: Cardinal): Integer; external 'SystemParametersInfoW@user32.dll stdcall';

function WasRunning(): Boolean;
begin
  Result := Running;
end;

{ Close Barrier Share (and its helper processes) so the files can be replaced. 0.3.9 and later
  quit on the event; 0.3.8 and earlier, or a copy that does not answer, are ended with taskkill. }
procedure CloseBarrierShare();
var
  Handle: Cardinal;
  I, Code: Integer;
begin
  if not CheckForMutexes(AppMutexName) then exit;
  Running := True;
  Handle := OpenEvent($0002 { EVENT_MODIFY_STATE }, 0, QuitEventName);
  if Handle <> 0 then begin
    SetEvent(Handle);
    CloseHandle(Handle);
    for I := 1 to 80 do begin
      if not CheckForMutexes(AppMutexName) then break;
      Sleep(100);
    end;
  end;
  if CheckForMutexes(AppMutexName) then begin
    Log('Barrier Share did not quit on request; ending it and its helpers');
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM BarrierShare.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
    for I := 1 to 50 do begin
      if not CheckForMutexes(AppMutexName) then break;
      Sleep(100);
    end;
  end;
  { A forced stop can leave the host's cursors hidden; reload the user's cursor scheme. }
  SystemParametersInfo($0057 { SPI_SETCURSORS }, 0, 0, 0);
  Sleep(300);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseBarrierShare();
  if CheckForMutexes(AppMutexName) then
    Result := ExpandConstant('{cm:CloseFailed}')
  else
    Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseBarrierShare();
  Result := True;
end;
