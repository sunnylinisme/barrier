#requires -Version 7.0
# SPDX-License-Identifier: GPL-2.0-or-later
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$PackageDir,
    [Parameter(Mandatory = $true)][string]$TestRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This test creates a disposable profile at the real per-user location.
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or -not $env:GITHUB_WORKSPACE) {
    throw 'Run only on a disposable Windows GitHub Actions runner.'
}
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') + '\'
if (-not $TestRoot.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $TestRoot)) {
    throw 'TestRoot must be a new directory inside the CI workspace.'
}
$profile = Join-Path $env:LOCALAPPDATA 'BarrierShare'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\org.barriershare.desktop_is1'
$machineKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\org.barriershare.desktop_is1'
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Barrier Share.lnk'),
    (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Barrier Share.lnk')
)
foreach ($path in @($profile, $uninstallKey, $machineKey) + $shortcuts) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to alter an existing profile, installation or shortcut: $path" }
}
$installDir = Join-Path $TestRoot '安裝測試 with spaces\Barrier Share'
New-Item -ItemType Directory -Path $TestRoot, $profile | Out-Null

function Invoke-TestProcess([string]$File, [string[]]$Arguments, [int]$TimeoutSeconds = 90, [bool]$ShellExecute = $false) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $File
    $info.UseShellExecute = $ShellExecute
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start $File" }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Timed out waiting for test process $File (PID $($process.Id)); no background processes were forcibly closed."
        }
        if ($process.ExitCode -ne 0) { throw "$File exited with code $($process.ExitCode); inspect installer/startup logs in $TestRoot" }
    } finally { $process.Dispose() }
}
function Get-ProfileHashes {
    $result = @{}
    foreach ($file in Get-ChildItem -LiteralPath $profile -File -Recurse) {
        $result[[IO.Path]::GetRelativePath($profile, $file.FullName)] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $result
}
function Assert-Profile([hashtable]$Expected) {
    if (-not (Test-Path -LiteralPath $profile)) { throw 'Installer removed the existing profile.' }
    $actual = Get-ProfileHashes
    if ($actual.Count -ne $Expected.Count) { throw 'Installer changed the profile file inventory.' }
    foreach ($name in $Expected.Keys) {
        if ($actual[$name] -ne $Expected[$name]) { throw "Installer changed profile file: $name" }
    }
}
function Assert-Installed {
    foreach ($name in 'BarrierShare.exe', 'barriers.exe', 'barrierc.exe', 'barrier-pair.exe', 'barrier-link.exe', 'GUI-README.txt', 'LICENSE', 'COMMIT.txt') {
        if (-not (Test-Path -LiteralPath (Join-Path $installDir $name) -PathType Leaf)) { throw "Missing installed file: $name" }
    }
    foreach ($file in Get-ChildItem -LiteralPath $PackageDir -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($PackageDir, $file.FullName)
        $destination = Join-Path $installDir $relative
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-FileHash -LiteralPath $destination).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) {
            throw "Installed payload differs from package: $relative"
        }
    }
    if (Test-Path -LiteralPath $machineKey) { throw 'Installer unexpectedly created a machine-wide uninstall entry.' }
    $entry = Get-ItemProperty -LiteralPath $uninstallKey
    $fileVersion = [Version][Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $installDir 'BarrierShare.exe')).FileVersion
    $expectedVersion = '{0}.{1}.{2}' -f $fileVersion.Major, $fileVersion.Minor, $fileVersion.Build
    if (-not $entry.DisplayName.StartsWith('Barrier Share') -or $entry.DisplayVersion -ne $expectedVersion -or $entry.InstallLocation.TrimEnd('\') -ine $installDir.TrimEnd('\')) {
        throw 'Per-user uninstall metadata does not match the installed application.'
    }
    $uninstaller = Join-Path $installDir 'unins000.exe'
    if (-not (Test-Path -LiteralPath $uninstaller) -or -not $entry.UninstallString.Contains($uninstaller)) { throw 'Uninstall command does not target this test installation.' }
    # Read the native Shell link instead of WScript's legacy TargetPath projection.
    $shell = New-Object -ComObject Shell.Application
    try {
        foreach ($path in $shortcuts) {
            if (-not (Test-Path -LiteralPath $path)) { throw "Shortcut was not created: $path" }
            $folder = $item = $shortcut = $null
            try {
                $folder = $shell.NameSpace([IO.Path]::GetDirectoryName($path))
                $item = $folder.ParseName([IO.Path]::GetFileName($path))
                if (-not $item.IsLink) { throw "Not a Shell shortcut: $path" }
                $shortcut = $item.GetLink
                $target = [string]$shortcut.Path
                $expected = Join-Path $installDir 'BarrierShare.exe'
                Add-Content -LiteralPath (Join-Path $TestRoot 'shortcuts.log') -Encoding utf8 -Value "Shortcut=$path; Target=$target; Expected=$expected; WorkingDirectory=$($shortcut.WorkingDirectory)"
                if (-not $target -or [IO.Path]::GetFullPath($target) -ine [IO.Path]::GetFullPath($expected)) {
                    throw "Shortcut targets the wrong application: $path; actual=[$target]; expected=[$expected]"
                }
            } finally {
                foreach ($object in @($shortcut, $item, $folder)) {
                    if ($null -ne $object) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($object) }
                }
            }
        }
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

Set-Content -LiteralPath (Join-Path $profile 'settings.xml') -Value '<settings host="true" address="" position="left" />' -Encoding utf8
Set-Content -LiteralPath (Join-Path $profile 'preserve-marker.txt') -Value ('before install ' + [Guid]::NewGuid()) -Encoding utf8
$beforeInstall = Get-ProfileHashes
$arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$installDir", '/TASKS=desktopicon')
Invoke-TestProcess $InstallerPath ($arguments + "/LOG=$(Join-Path $TestRoot 'install.log')")
Assert-Installed
Assert-Profile $beforeInstall

$startupRoot = Join-Path $TestRoot '已安裝啟動 startup'
Invoke-TestProcess $shortcuts[0] @('--startup-test', $startupRoot) 45 $true
if (-not (Test-Path -LiteralPath (Join-Path $startupRoot 'STARTUP-PASS.txt'))) { throw 'Installed Start Menu shortcut did not pass normal startup/discovery checks.' }
Assert-Profile $beforeInstall

# Reinstall over existing files exercises the updater path without inventing an older release.
Set-Content -LiteralPath (Join-Path $profile 'preserve-marker.txt') -Value ('before reinstall ' + [Guid]::NewGuid()) -Encoding utf8
Set-Content -LiteralPath (Join-Path $profile 'settings.xml') -Value '<settings host="false" address="192.168.1.2" position="up" />' -Encoding utf8
$beforeReinstall = Get-ProfileHashes
Invoke-TestProcess $InstallerPath ($arguments + "/LOG=$(Join-Path $TestRoot 'reinstall.log')")
Assert-Installed
Assert-Profile $beforeReinstall
Invoke-TestProcess (Join-Path $installDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$(Join-Path $TestRoot 'uninstall.log')")
foreach ($file in Get-ChildItem -LiteralPath $PackageDir -File -Recurse) {
    if (Test-Path -LiteralPath (Join-Path $installDir ([IO.Path]::GetRelativePath($PackageDir, $file.FullName)))) { throw "Uninstall left packaged file: $($file.Name)" }
}
foreach ($path in @($uninstallKey, $machineKey) + $shortcuts) {
    if (Test-Path -LiteralPath $path) { throw "Uninstall left registration or shortcut: $path" }
}
Assert-Profile $beforeReinstall

# Updating over a running copy closes it cleanly and starts it again; uninstall closes it and
# removes the launch-at-sign-in value. The running app may write its own profile from here on.
function Wait-Until([scriptblock]$Condition, [string]$Failure, [int]$Seconds = 20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while (-not (& $Condition)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw $Failure }
        Start-Sleep -Milliseconds 200
    }
}
function Test-AppRunning { $mutex = $null; $open = [Threading.Mutex]::TryOpenExisting('Local\BarrierShare.Desktop', [ref]$mutex); if ($mutex) { $mutex.Dispose() }; return $open }
$app = Join-Path $installDir 'BarrierShare.exe'
function Step([string]$Text) { Write-Output "::notice title=Installer step::$Text" }
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($null -ne (Get-ItemProperty -LiteralPath $runKey -Name BarrierShare -ErrorAction SilentlyContinue)) { throw 'Refusing to alter an existing launch-at-sign-in entry.' }
# The previous uninstaller removes itself shortly after exiting; let it finish before installing again.
Wait-Until { -not (Test-Path -LiteralPath (Join-Path $installDir 'unins000.exe')) } 'Previous uninstaller did not finish removing itself.' 30
Invoke-TestProcess $InstallerPath ($arguments + "/LOG=$(Join-Path $TestRoot 'install-for-update.log')")
$first = Start-Process -FilePath $app -ArgumentList '--background' -PassThru
Step "started background copy $($first.Id)"
Wait-Until { Test-AppRunning } 'Installed app did not start in the background.'
Start-Sleep -Seconds 2
$updateLog = Join-Path $TestRoot 'update-running.log'
Invoke-TestProcess $InstallerPath ($arguments + "/LOG=$updateLog")
Step ("update finished; first exited=$($first.HasExited); log: " + ((Select-String -LiteralPath $updateLog -Pattern 'quit|taskkill|Run entry|BarrierShare.exe' | ForEach-Object { $_.Line.Substring([Math]::Min(24, $_.Line.Length)) }) -join ' | '))
Step ("processes: " + ((Get-Process BarrierShare -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) $($_.Path)" }) -join ' | '))
if (-not $first.WaitForExit(1000)) { throw 'Setup replaced files without closing the running copy.' }
if ((Get-Content -LiteralPath $updateLog -Raw).Contains('did not quit on request')) { throw 'Running copy ignored the quit signal and had to be killed.' }
Wait-Until { @(Get-Process BarrierShare -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $first.Id -and $_.Path -ieq $app }).Count -eq 1 } 'Setup did not start the updated copy again.'
$second = Get-Process BarrierShare | Where-Object { $_.Path -ieq $app }
Set-ItemProperty -LiteralPath $runKey -Name BarrierShare -Value ('"' + $app + '" --background')
Invoke-TestProcess (Join-Path $installDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$(Join-Path $TestRoot 'uninstall-running.log')")
if (-not $second.WaitForExit(1000)) { throw 'Uninstall left the app running.' }
if ($null -ne (Get-ItemProperty -LiteralPath $runKey -Name BarrierShare -ErrorAction SilentlyContinue)) { throw 'Uninstall left the launch-at-sign-in entry.' }
if (Test-Path -LiteralPath $app) { throw 'Uninstall could not remove the app that was running.' }

Set-Content -LiteralPath (Join-Path $TestRoot 'INSTALLER-PASS.txt') -Value 'Per-user silent installation to a Unicode path with spaces; payload hashes and shortcuts match; installed Start Menu shortcut startup passes; repeat installation and uninstall preserve an existing profile; uninstall removes payload, shortcuts and registration; updating over a running background copy closes it through the quit signal and starts it again; uninstall closes a running copy and removes the launch-at-sign-in entry. This is a same-version reinstall, not an old-release migration test.' -Encoding utf8
Get-Content -LiteralPath (Join-Path $TestRoot 'INSTALLER-PASS.txt')
