<#
.SYNOPSIS
    Sets up Sync Devices on this Windows machine. Safe to run again.

.DESCRIPTION
    First machine:   .\Setup-SyncDevices.ps1
        Reads your Claude Code chats, finds the folders they touched, lets you pick which to sync,
        and makes this the canonical machine.
    Other machines:  .\Setup-SyncDevices.ps1 -Join <first machine's device ID>
        Asks the first machine to pair, waits until you click Accept there, receives the folder
        list, and syncs the same folders.

.PARAMETER Join
    The first machine's device ID. Use it on every machine after the first.
.PARAMETER Rescan
    First machine only: pick the folders again.
.PARAMETER Import
    First machine only: take the folder list from a JSON file instead of the scan. It accepts this
    tool's own sync-devices.json, or an object with a "folders" list of { id, label, path }.
.PARAMETER Yes
    Accept the scan's suggestions without the picker window.
.PARAMETER FreshStart
    Joining machine: move its existing Claude chats to ~\.claude\projects.before-sync-<date> first,
    so it starts from the first machine's chats only.
.PARAMETER AllowOneDriveDesktop
    Continue when the Desktop folder is inside OneDrive. Two sync tools on one folder conflict.
.PARAMETER NoShortcuts
    Do not register the logon start (HKCU Run key) or the Start-menu shortcut.
.PARAMETER NoLaunch
    Do not start the app at the end.
#>
param([string]$Join, [switch]$Rescan, [string]$Import, [switch]$Yes, [switch]$FreshStart,
    [switch]$AllowOneDriveDesktop, [switch]$NoShortcuts, [switch]$NoLaunch)
$ErrorActionPreference = 'Stop'

# The app runs from a copy outside the synced folders, so a sync never edits the running app.
$appDir = Join-Path $env:LOCALAPPDATA 'SyncDevices'
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
if ((Resolve-Path $PSScriptRoot).Path -ne (Resolve-Path $appDir).Path) {
    Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $appDir -Force
}
. (Join-Path $appDir 'SyncDevices.Common.ps1')
if ($Join) { $Join = Assert-DeviceId $Join }

$desktop = (Get-LocalVars).DESKTOP
if ($desktop -match 'OneDrive' -and -not $AllowOneDriveDesktop) {
    throw "Your Desktop ($desktop) is in OneDrive. Turn off OneDrive backup for Desktop, or run again with -AllowOneDriveDesktop."
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

function Show-FolderPicker($Found) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $items = New-Object System.Collections.ArrayList
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Sync Devices: choose folders'; $f.Size = New-Object Drawing.Size(900, 540)
    $f.StartPosition = 'CenterScreen'; $f.TopMost = $true; $f.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $lbl = New-Object Windows.Forms.Label
    $lbl.Dock = 'Top'; $lbl.Height = 52; $lbl.Padding = New-Object Windows.Forms.Padding(12, 10, 12, 0)
    $lbl.Text = "Your Claude chats touched these folders. Tick the ones to keep in sync on all your machines.`nBig folders start unticked: they are usually a parent of the real project."
    $list = New-Object Windows.Forms.CheckedListBox
    $list.Dock = 'Fill'; $list.CheckOnClick = $true; $list.IntegralHeight = $false
    $list.Font = New-Object Drawing.Font('Consolas', 9.5)
    function Add-Row($x) {
        [void]$items.Add($x)
        [void]$list.Items.Add(('{0,9}  {1,4} chats  {2}' -f (Format-Size $x.Bytes), $x.Chats, $x.Path), [bool]$x.Selected)
    }
    foreach ($x in $Found) { Add-Row $x }

    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 50; $bar.FlowDirection = 'RightToLeft'
    $bar.Padding = New-Object Windows.Forms.Padding(10, 9, 10, 0)
    $bOk = New-Object Windows.Forms.Button
    $bOk.Text = 'Sync these folders'; $bOk.Size = New-Object Drawing.Size(150, 30); $bOk.DialogResult = 'OK'
    $bCancel = New-Object Windows.Forms.Button
    $bCancel.Text = 'Cancel'; $bCancel.Size = New-Object Drawing.Size(90, 30); $bCancel.DialogResult = 'Cancel'
    $bAdd = New-Object Windows.Forms.Button
    $bAdd.Text = 'Add folder...'; $bAdd.Size = New-Object Drawing.Size(110, 30)
    $bAdd.add_Click({
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog($f) -eq 'OK') {
            $p = $dlg.SelectedPath
            Add-Row ([pscustomobject]@{ Path = $p; SpecPath = (ConvertTo-SpecPath $p (Get-LocalVars)); Chats = 0; Bytes = (Measure-Folder $p); Selected = $true })
        }
    })
    $bar.Controls.AddRange(@($bOk, $bCancel, $bAdd))
    $f.Controls.Add($list); $f.Controls.Add($lbl); $f.Controls.Add($bar)
    $f.AcceptButton = $bOk; $f.CancelButton = $bCancel
    if ($f.ShowDialog() -ne 'OK') { return $null }
    @($list.CheckedIndices | ForEach-Object { $items[$_] })
}

function Import-FolderList([string]$Path) {
    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    @($data.folders | Where-Object { -not ($_.PSObject.Properties['claudeHome'] -and $_.claudeHome) } |
        ForEach-Object { [pscustomobject]@{ id = $_.id; label = $_.label; path = $_.path } })
}

# --- Syncthing ---------------------------------------------------------------------------------

if (-not (Get-SyncthingExe)) {
    Write-Host 'Installing Syncthing (official winget package)...'
    winget install --id Syncthing.Syncthing -e --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity
    if (-not (Get-SyncthingExe)) { throw 'Syncthing did not install. Install it by hand, then run this again.' }
}
# The first start creates the config itself and moves to free ports if the defaults are taken.
if (-not (Start-Syncthing)) { throw 'Syncthing did not start. Check %LOCALAPPDATA%\Syncthing\syncthing.log.' }

$me = Get-MyId
$self = Invoke-St -Path "config/devices/$me"
$self.name = $env:COMPUTERNAME
$null = Invoke-St -Method PUT -Path "config/devices/$me" -Body $self
# Syncthing creates a sample folder on first run; remove it from the config (its files stay on disk).
try { $null = Invoke-St -Method DELETE -Path 'config/folders/default' } catch { }

# --- The folder list -----------------------------------------------------------------------------

$spec = Get-Spec
if ($Join) {
    $null = Add-Device $Join
    $cfg = Get-FolderPlan | Where-Object { $_.Id -eq $script:ConfigFolderId }
    New-Item -ItemType Directory -Force -Path $cfg.Path | Out-Null
    Write-IgnoreFile $cfg
    Set-StFolder $cfg @($me, $Join)
    if (-not $spec) {
        Write-Host ''
        Write-Host "This device's ID: $me"
        Write-Host 'On the first machine, open Sync Devices and click Accept. Waiting up to 15 minutes...'
        $deadline = (Get-Date).AddMinutes(15)
        while (-not (Get-Spec)) {
            if ((Get-Date) -gt $deadline) { throw 'No folder list arrived. Click Accept on the first machine, then run this again.' }
            Start-Sleep -Seconds 3
        }
        Write-Host 'Folder list received from the first machine.'
    }
} elseif ($spec -and -not (Test-IsCanonicalMachine) -and ($Rescan -or $Import)) {
    throw "Choose folders on the first machine ($($spec.canonical.machine)). This machine follows its list."
} elseif (-not $spec -or $Rescan -or $Import) {
    $carried = @()
    if ($Import) {
        $folders = @(Import-FolderList $Import)
        # Devices that already share these folders were trusted with them before; keep them paired.
        $ids = @($folders | ForEach-Object { $_.id })
        $carried = @(Invoke-St -Path 'config/folders' | Where-Object { $ids -contains $_.id } |
            ForEach-Object { $_.devices | ForEach-Object { $_.deviceID } } | Where-Object { $_ -ne $me } | Select-Object -Unique)
    } else {
        Write-Host 'Reading your Claude chats to find the folders they touched...'
        $found = @(Find-ClaudeFolders)
        $chosen = $(if ($Yes) { @($found | Where-Object { $_.Selected }) } else { Show-FolderPicker $found })
        if ($null -eq $chosen) { throw 'Setup cancelled. Nothing was changed.' }
        $folders = @(ConvertTo-SpecFolders $chosen)
    }
    if ($spec) {
        # Keep the ID of a folder that is already synced, so Syncthing does not start it over.
        foreach ($nf in $folders) {
            $old = $spec.folders | Where-Object { $_.path -eq $nf.path } | Select-Object -First 1
            if ($old) { $nf.id = $old.id }
        }
        $spec.folders = $folders
    } else {
        $spec = New-Spec $me $folders
    }
    if ($carried) { $spec | Add-Member -NotePropertyName devices -NotePropertyValue @($carried) -Force }
    Save-Spec $spec
}

# --- Folders -------------------------------------------------------------------------------------

$spec = Get-Spec
$canonical = Test-IsCanonicalMachine
$projects = Join-Path $env:USERPROFILE '.claude\projects'
$claudeConfigured = $true
try { $null = Invoke-St -Path "config/folders/$($script:ClaudeFolderId)" } catch { $claudeConfigured = $false }
# Only on the first run: a second -FreshStart must not move the synced chats aside again.
if ($FreshStart -and -not $canonical -and -not $claudeConfigured -and (Test-Path -LiteralPath $projects)) {
    $backup = 'projects.before-sync-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmm')
    Rename-Item -LiteralPath $projects -NewName $backup
    Write-Host "Moved this machine's old Claude chats to $(Join-Path (Split-Path $projects) $backup)"
}

$ids = Get-DeviceIds
foreach ($item in Get-FolderPlan) {
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($item.Path)))) {
        Write-Warning "Skipped $($item.Label): drive $([IO.Path]::GetPathRoot($item.Path)) does not exist on this machine."
        continue
    }
    $configured = $true
    try { $null = Invoke-St -Path "config/folders/$($item.Id)" } catch { $configured = $false }
    $hasFiles = (Test-Path -LiteralPath $item.Path) -and @(Get-ChildItem -LiteralPath $item.Path -Force | Select-Object -First 1).Count -gt 0
    $receivesFromPeer = $item.Type -eq 'sendreceive' -and -not $item.ClaudeHome -and $item.Id -ne $script:ConfigFolderId
    if (-not $configured -and -not $canonical -and $receivesFromPeer -and $hasFiles) {
        $backup = '{0}.before-sync-{1}' -f (Split-Path $item.Path -Leaf), (Get-Date -Format 'yyyyMMdd-HHmm')
        Rename-Item -LiteralPath $item.Path -NewName $backup
        Write-Host "Kept this machine's old copy of $($item.Path) as $backup"
    }
    New-Item -ItemType Directory -Force -Path $item.Path | Out-Null
    Write-IgnoreFile $item
    # Keep Syncthing's own files out of git status in synced repos (local exclude, never committed).
    $exclude = Join-Path $item.Path '.git\info\exclude'
    if (Test-Path -LiteralPath (Split-Path $exclude)) {
        $have = @(Get-Content -LiteralPath $exclude -ErrorAction SilentlyContinue)
        $missing = @('.stignore', '.stfolder', '.stversions') | Where-Object { $have -notcontains $_ }
        if ($missing) { Add-Content -LiteralPath $exclude -Value $missing }
    }
    Set-StFolder $item $ids
    Write-Host "Folder ready: $($item.Label) -> $($item.Path)"
}

Sync-ClaudeChatFolders

# --- App -----------------------------------------------------------------------------------------

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$appArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$appDir\SyncDevices.ps1`""
if (-not $NoShortcuts) {
    # Start at logon through the Run key: Windows can skip the Startup folder on a busy logon.
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Set-ItemProperty -LiteralPath $run -Name 'Sync Devices' -Value "`"$ps`" $appArgs -Tray"
    $oldStartup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Sync Devices.lnk'
    if (Test-Path -LiteralPath $oldStartup) { Remove-Item -LiteralPath $oldStartup }
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Sync Devices.lnk'))
    $s.TargetPath = $ps; $s.Arguments = $appArgs; $s.WorkingDirectory = $appDir
    $s.WindowStyle = 7; $s.Description = 'Sync Devices'
    $s.Save()
}
if (-not $NoLaunch) {
    # A running app would keep the old code: a new start only asks it to show its window.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*SyncDevices.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process -FilePath $ps -ArgumentList $appArgs -WindowStyle Hidden
}

Write-Host ''
if ($canonical) {
    Write-Host "Done. This is the first machine. Its device ID: $me"
    Write-Host 'On each other machine run:'
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\Setup-SyncDevices.ps1 -Join $me"
} else {
    Write-Host "Done. This machine syncs with $($spec.canonical.machine). Its device ID: $me"
}
