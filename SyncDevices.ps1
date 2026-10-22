<#
.SYNOPSIS
    Sync Devices: shows whether your machines are connected and in sync, syncs them on request,
    and lists every Claude Code chat so you can continue it on this machine.

.PARAMETER Tray
    Start hidden in the notification area. Setup uses this for the logon shortcut.

.PARAMETER Screenshot
    For the README: render the main window with the sample data in tools\Demo-Data.ps1 to this PNG
    file, then exit. Shows no real machine names, user names or paths.
#>
param([switch]$Tray, [string]$Screenshot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http, Microsoft.VisualBasic
. (Join-Path $PSScriptRoot 'SyncDevices.Common.ps1')
if ($Screenshot) { . (Join-Path $PSScriptRoot 'tools\Demo-Data.ps1') }

# One instance per user: a second start asks the running one to show its window.
$created = $true
$showSignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\SyncDevices.Show')
if (-not $Screenshot) {
    $mutex = New-Object System.Threading.Mutex($true, 'Local\SyncDevices.App', [ref]$created)
    if (-not $created) { [void]$showSignal.Set(); return }
}

[Windows.Forms.Application]::EnableVisualStyles()
$state = @{ Exiting = $false; SyncRequested = $false; LastInSync = $null; LastMaintenance = [datetime]::MinValue; Ticks = 0; Warned = @{} }
$http = New-Object System.Net.Http.HttpClient
$uiFont = New-Object Drawing.Font('Segoe UI', 9.5)
$green = [Drawing.Color]::FromArgb(22, 128, 61)
$amber = [Drawing.Color]::FromArgb(180, 95, 6)
$gray = [Drawing.Color]::FromArgb(90, 98, 110)

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

function Show-Message([string]$Text, [string]$Icon = 'Information') {
    [void][Windows.Forms.MessageBox]::Show($form, $Text, 'Sync Devices', 'OK', $Icon)
}

function New-AppIcon {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(27, 98, 163))), 1, 1, 30, 30)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 2.6
    $g.DrawLine($pen, 8, 12, 23, 12); $g.DrawLine($pen, 18, 7, 23, 12); $g.DrawLine($pen, 18, 17, 23, 12)
    $g.DrawLine($pen, 24, 20, 9, 20); $g.DrawLine($pen, 14, 15, 9, 20); $g.DrawLine($pen, 14, 25, 9, 20)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# --- Main window ---------------------------------------------------------------------------------

$icon = New-AppIcon
$form = New-Object Windows.Forms.Form
$form.Text = 'Sync Devices'
$form.Icon = $icon
$form.Font = $uiFont
$form.Size = New-Object Drawing.Size(860, 520)
$form.MinimumSize = New-Object Drawing.Size(660, 380)
$form.StartPosition = 'CenterScreen'

$list = New-Object Windows.Forms.ListView
$list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.HideSelection = $true
[void]$list.Columns.Add('Folder', 230)
[void]$list.Columns.Add('Status', 250)
[void]$list.Columns.Add('Path on this device', 340)

$banner = New-Object Windows.Forms.Panel
$banner.Dock = 'Top'; $banner.Height = 62; $banner.Visible = $false
$lblBanner = New-Object Windows.Forms.Label
$lblBanner.Location = New-Object Drawing.Point(14, 10); $lblBanner.AutoSize = $true
$btnAccept = New-Object Windows.Forms.Button
$btnAccept.Text = 'Accept'; $btnAccept.Size = New-Object Drawing.Size(90, 28); $btnAccept.Anchor = 'Top, Right'
$btnAccept.Location = New-Object Drawing.Point(($form.ClientSize.Width - 206), 16)
$btnIgnore = New-Object Windows.Forms.Button
$btnIgnore.Text = 'Ignore'; $btnIgnore.Size = New-Object Drawing.Size(90, 28); $btnIgnore.Anchor = 'Top, Right'
$btnIgnore.Location = New-Object Drawing.Point(($form.ClientSize.Width - 106), 16)
$banner.Controls.AddRange(@($lblBanner, $btnAccept, $btnIgnore))
$bannerOffer = [Drawing.Color]::FromArgb(255, 244, 214)
$bannerWarn = [Drawing.Color]::FromArgb(253, 226, 226)

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 66
$lblPeer = New-Object Windows.Forms.Label
$lblPeer.Location = New-Object Drawing.Point(14, 10); $lblPeer.AutoSize = $true
$lblPeer.Font = New-Object Drawing.Font('Segoe UI Semibold', 12.5)
$lblThis = New-Object Windows.Forms.Label
$lblThis.Location = New-Object Drawing.Point(16, 40); $lblThis.AutoSize = $true; $lblThis.ForeColor = $gray
$header.Controls.AddRange(@($lblPeer, $lblThis))

$bottom = New-Object Windows.Forms.FlowLayoutPanel
$bottom.Dock = 'Bottom'; $bottom.Height = 50; $bottom.Padding = New-Object Windows.Forms.Padding(10, 9, 10, 0)
function New-Button([string]$Text, [int]$Width = 110) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object Drawing.Size($Width, 30)
    $bottom.Controls.Add($b)
    $b
}
$btnSync = New-Button 'Sync now' 120
$btnSync.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
$btnPause = New-Button 'Pause'
$btnPair = New-Button 'Pair device...'
$btnChats = New-Button 'Chats...'
$btnAdvanced = New-Button 'Advanced...'
$lblLast = New-Object Windows.Forms.Label
$lblLast.AutoSize = $true; $lblLast.ForeColor = $gray; $lblLast.Margin = New-Object Windows.Forms.Padding(14, 8, 0, 0)
$bottom.Controls.Add($lblLast)

# Dock order: the Fill control goes in first so the Top and Bottom bars take their space before it.
$form.Controls.Add($list)
$form.Controls.Add($banner)
$form.Controls.Add($header)
$form.Controls.Add($bottom)

# --- Tray icon -----------------------------------------------------------------------------------

# Not named $tray: PowerShell names ignore case, and $Tray is the switch parameter.
$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon = $icon; $notify.Text = 'Sync Devices'; $notify.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open')
$miSync = $menu.Items.Add('Sync now')
$miPause = $menu.Items.Add('Pause syncing')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')
$notify.ContextMenuStrip = $menu

# --- Behaviour ---------------------------------------------------------------------------------

function Show-Main {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
    Update-View
}

function Invoke-Maintenance {
    $state.LastMaintenance = Get-Date
    try { Sync-ClaudeChatFolders 3>$null } catch { }
    try { Approve-PendingMirrors } catch { }
}

function Get-FolderStatusText($Folder, $Status, $Online) {
    if ($Folder.paused) { return 'Paused' }
    $err = Get-Field $Status 'error' ''
    if ($Status.state -eq 'error' -or $err) { return "Problem: $err" }
    $pullErrors = Get-Field $Status 'pullErrors' 0
    if ($pullErrors -gt 0) { return "Problem: $pullErrors files could not sync" }
    if ($Status.state -like 'scan*') { return 'Checking files...' }
    if ($Status.state -like 'sync*') { return "Receiving ($(Format-Size $Status.needBytes) left)" }
    if ($Online.Count -eq 0) {
        if ($Status.needBytes -gt 0) { return 'Waiting for the other device' }
        return 'Up to date here (other device offline)'
    }
    foreach ($p in $Online) {
        if (-not ($Folder.devices | Where-Object { $_.deviceID -eq $p.deviceID })) { continue }
        try {
            $c = Invoke-St -Path ('db/completion?folder={0}&device={1}' -f [uri]::EscapeDataString($Folder.id), $p.deviceID)
            if ($c.completion -lt 100) { return 'Sending {0:N0}% ({1} left)' -f $c.completion, (Format-Size $c.needBytes) }
        } catch { }
    }
    if ($Status.needBytes -gt 0) { return "Waiting ($(Format-Size $Status.needBytes) to receive)" }
    'Up to date'
}

function Update-View {
    if (-not (Test-StRunning)) {
        $lblPeer.Text = 'Starting the sync engine...'; $lblPeer.ForeColor = $gray
        [void](Start-Syncthing)
        return
    }
    $peers = @(Get-Peers)
    $conns = (Invoke-St -Path 'system/connections').connections
    $online = @($peers | Where-Object { $c = Get-Field $conns $_.deviceID; $c -and $c.connected })
    $paused = $peers.Count -gt 0 -and @($peers | Where-Object { -not $_.paused }).Count -eq 0
    $names = ($peers | ForEach-Object { Get-PeerName $_ }) -join ', '

    $lblThis.Text = "This device: $env:COMPUTERNAME"
    if (-not (Get-Spec)) {
        $lblPeer.Text = 'Not set up yet. Run Setup-SyncDevices.ps1.'; $lblPeer.ForeColor = $amber
    } elseif ($peers.Count -eq 0) {
        $lblPeer.Text = 'No other device yet. Click "Pair device".'; $lblPeer.ForeColor = $gray
    } elseif ($paused) {
        $lblPeer.Text = 'Syncing is paused.'; $lblPeer.ForeColor = $amber
    } elseif ($online.Count -gt 0) {
        $lblPeer.Text = "Connected to $(($online | ForEach-Object { Get-PeerName $_ }) -join ', ')"; $lblPeer.ForeColor = $green
    } else {
        $lblPeer.Text = "Not connected to $names. Open Sync Devices there."; $lblPeer.ForeColor = $amber
    }
    $btnPause.Text = $(if ($paused) { 'Resume' } else { 'Pause' })
    $miPause.Text = $(if ($paused) { 'Resume syncing' } else { 'Pause syncing' })

    $prompt = Get-PairingPrompt $peers @(Get-PendingDevices)
    if ($prompt) {
        $lblBanner.Text = $prompt.Text
        $btnAccept.Visible = $prompt.AllowAccept
        $banner.BackColor = $(if ($prompt.AllowAccept) { $bannerOffer } else { $bannerWarn })
        $banner.Tag = $prompt.Device
        $banner.Visible = $true
        if (-not $prompt.AllowAccept -and -not $state.Warned.ContainsKey($prompt.Device.Id)) {
            $state.Warned[$prompt.Device.Id] = $true
            $notify.ShowBalloonTip(6000, 'Sync Devices', 'An unknown device asked to pair. It was not accepted.', 'Warning')
        }
    } else {
        $banner.Visible = $false
    }

    $folders = @(Invoke-St -Path 'config/folders' | Where-Object { Test-ManagedFolder $_.id })
    $allDone = $online.Count -gt 0
    $list.BeginUpdate()
    foreach ($f in $folders) {
        $st = Invoke-St -Path ('db/status?folder={0}' -f [uri]::EscapeDataString($f.id))
        $text = Get-FolderStatusText $f $st $online
        if ($text -ne 'Up to date') { $allDone = $false }
        $row = $list.Items[$f.id]
        if (-not $row) {
            $row = $list.Items.Add($f.id, $f.label, '')
            [void]$row.SubItems.Add('')
            [void]$row.SubItems.Add('')
        }
        $row.Text = $f.label
        $row.SubItems[1].Text = $text
        $row.SubItems[2].Text = $f.path
        $row.ForeColor = $(if ($text -eq 'Up to date') { $green } elseif ($text -like 'Problem*') { [Drawing.Color]::Firebrick } else { [Drawing.SystemColors]::WindowText })
    }
    $ids = @($folders | ForEach-Object { $_.id })
    foreach ($row in @($list.Items)) { if ($ids -notcontains $row.Name) { $list.Items.Remove($row) } }
    $list.EndUpdate()

    if ($allDone) {
        $state.LastInSync = Get-Date
        if ($state.SyncRequested) {
            $state.SyncRequested = $false
            $notify.ShowBalloonTip(4000, 'Sync Devices', "Everything is synced with $names.", 'Info')
        }
    }
    if ($state.SyncRequested) { $lblLast.Text = 'Syncing...' }
    elseif ($state.LastInSync) { $lblLast.Text = 'Fully synced at ' + $state.LastInSync.ToString('HH:mm') }
    else { $lblLast.Text = '' }
}

function Invoke-SyncNow {
    $peers = @(Get-Peers)
    if ($peers.Count -gt 0 -and @($peers | Where-Object { -not $_.paused }).Count -eq 0) { Set-PeersPaused $false }
    Invoke-Maintenance
    # A full scan can take a while, so the request runs in the background and the view shows progress.
    Initialize-Api
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), "$script:ApiBase/db/scan"
    $req.Headers.Add('X-API-Key', $script:ApiKey)
    [void]$http.SendAsync($req)
    $state.SyncRequested = $true
    Update-View
}

function Switch-Pause {
    $peers = @(Get-Peers)
    $paused = $peers.Count -gt 0 -and @($peers | Where-Object { -not $_.paused }).Count -eq 0
    Set-PeersPaused (-not $paused)
    Update-View
}

function Show-PairDialog {
    $d = New-Object Windows.Forms.Form
    $d.Text = 'Pair device'; $d.Font = $uiFont; $d.Icon = $icon
    $d.Size = New-Object Drawing.Size(620, 310); $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.StartPosition = 'CenterParent'

    $l1 = New-Object Windows.Forms.Label
    $l1.Text = "This device's ID. On a new machine, run Setup-SyncDevices.ps1 -Join <this ID>:"
    $l1.Location = New-Object Drawing.Point(16, 16); $l1.AutoSize = $true
    $tbMine = New-Object Windows.Forms.TextBox
    $tbMine.Location = New-Object Drawing.Point(18, 42); $tbMine.Width = 470; $tbMine.ReadOnly = $true
    $tbMine.Font = New-Object Drawing.Font('Consolas', 9.5); $tbMine.Text = Get-MyId
    $bCopy = New-Object Windows.Forms.Button
    $bCopy.Text = 'Copy'; $bCopy.Location = New-Object Drawing.Point(498, 40); $bCopy.Width = 90
    $bCopy.add_Click({ [Windows.Forms.Clipboard]::SetText($tbMine.Text); $bCopy.Text = 'Copied' })

    $l2 = New-Object Windows.Forms.Label
    $l2.Text = "Or paste the ID of a machine that already runs Sync Devices:"
    $l2.Location = New-Object Drawing.Point(16, 92); $l2.AutoSize = $true
    $tbOther = New-Object Windows.Forms.TextBox
    $tbOther.Location = New-Object Drawing.Point(18, 118); $tbOther.Width = 570
    $tbOther.Font = New-Object Drawing.Font('Consolas', 9.5)
    $l3 = New-Object Windows.Forms.Label
    $l3.Text = "Check the ID on that machine itself. Never accept an ID someone sends you."
    $l3.Location = New-Object Drawing.Point(16, 156); $l3.AutoSize = $true; $l3.ForeColor = $gray

    $bPair = New-Object Windows.Forms.Button
    $bPair.Text = 'Pair'; $bPair.Location = New-Object Drawing.Point(398, 220); $bPair.Width = 90
    $bClose = New-Object Windows.Forms.Button
    $bClose.Text = 'Close'; $bClose.Location = New-Object Drawing.Point(498, 220); $bClose.Width = 90
    $bClose.DialogResult = 'Cancel'
    $bPair.add_Click({
        try {
            Add-Peer $tbOther.Text
            Show-Message 'Paired. The folders start syncing once the other machine connects.'
            $d.Close()
        } catch { Show-Message $_.Exception.Message 'Warning' }
    })
    $d.Controls.AddRange(@($l1, $tbMine, $bCopy, $l2, $tbOther, $l3, $bPair, $bClose))
    $d.CancelButton = $bClose
    [void]$d.ShowDialog($form)
    Update-View
}

# --- Chats window ------------------------------------------------------------------------------

function Read-Tail([string]$Path, [int]$Bytes = 262144) {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $start = [Math]::Max(0, $fs.Length - $Bytes)
        [void]$fs.Seek($start, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $start)
        [void]$fs.Read($buf, 0, $buf.Length)
        [Text.Encoding]::UTF8.GetString($buf)
    } finally { $fs.Dispose() }
}

function Get-LastJsonString([string]$Text, [string]$Key) {
    $m = [regex]::Matches($Text, '"' + $Key + '":"((?:[^"\\]|\\.)*)"')
    if ($m.Count -eq 0) { return $null }
    $raw = $m[$m.Count - 1].Groups[1].Value
    try { ConvertFrom-Json ('"' + $raw + '"') } catch { $raw }
}

function Get-Chats {
    $proj = Join-Path $env:USERPROFILE '.claude\projects'
    $dirs = @(Get-ChildItem -LiteralPath $proj -Directory -Force | Where-Object { -not (Test-IsLink $_) })
    $chats = foreach ($dir in $dirs) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -Filter *.jsonl -File)) {
            $tail = Read-Tail $file.FullName
            $title = Get-LastJsonString $tail 'aiTitle'
            if (-not $title) { $title = Get-LastJsonString $tail 'lastPrompt' }
            if (-not $title) { $title = '(no title)' }
            if ($title.Length -gt 120) { $title = $title.Substring(0, 117) + '...' }
            [pscustomobject]@{ Id = $file.BaseName; Title = $title; Cwd = (Get-LastJsonString $tail 'cwd'); Updated = $file.LastWriteTime }
        }
    }
    @($chats | Sort-Object Updated -Descending)
}

function Start-ChatHere($Chat) {
    # The ID is a synced file name; only a plain session ID may reach the command line.
    if (-not (Test-SessionId $Chat.Id)) { Show-Message "This chat has an invalid ID and cannot be opened: $($Chat.Id)" 'Warning'; return }
    $claude = Get-ClaudeExe
    if (-not $claude) { Show-Message 'Claude Code (claude.exe) is not installed on this machine.' 'Warning'; return }
    $dir = $(if ($Chat.Cwd) { Convert-ToLocalPath $Chat.Cwd } else { '' })
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        Show-Message "This chat ran in a folder that is not on this machine:`n$dir`n`nIt opens in your home folder instead. Claude may not find it there." 'Warning'
        $dir = $env:USERPROFILE
    }
    $cmd = "Set-Location -LiteralPath '{0}'; & '{1}' --resume {2}" -f $dir.Replace("'", "''"), $claude.Replace("'", "''"), $Chat.Id
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoExit', '-NoProfile', '-EncodedCommand', $encoded
}

function Show-ChatsDialog {
    $d = New-Object Windows.Forms.Form
    $d.Text = 'Chats on this machine'; $d.Font = $uiFont; $d.Icon = $icon
    $d.Size = New-Object Drawing.Size(980, 560); $d.StartPosition = 'CenterParent'

    $lv = New-Object Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
    [void]$lv.Columns.Add('Chat', 430)
    [void]$lv.Columns.Add('Folder', 340)
    [void]$lv.Columns.Add('Last active', 150)

    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 50; $bar.Padding = New-Object Windows.Forms.Padding(10, 9, 10, 0)
    $bOpen = New-Object Windows.Forms.Button
    $bOpen.Text = 'Continue on this machine'; $bOpen.Size = New-Object Drawing.Size(200, 30)
    $bCopy = New-Object Windows.Forms.Button
    $bCopy.Text = 'Copy resume command'; $bCopy.Size = New-Object Drawing.Size(180, 30)
    $hint = New-Object Windows.Forms.Label
    $hint.Text = 'Close a chat on the other machine before you continue it here.'
    $hint.AutoSize = $true; $hint.ForeColor = $gray; $hint.Margin = New-Object Windows.Forms.Padding(14, 8, 0, 0)
    $bar.Controls.AddRange(@($bOpen, $bCopy, $hint))

    foreach ($c in Get-Chats) {
        $row = $lv.Items.Add($c.Title)
        [void]$row.SubItems.Add($(if ($c.Cwd) { Convert-ToLocalPath $c.Cwd } else { '' }))
        [void]$row.SubItems.Add($c.Updated.ToString('yyyy-MM-dd HH:mm'))
        $row.Tag = $c
    }
    $selected = { if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Tag } else { $null } }
    $bOpen.add_Click({ $c = & $selected; if ($c) { Start-ChatHere $c } })
    $lv.add_DoubleClick({ $c = & $selected; if ($c) { Start-ChatHere $c } })
    $bCopy.add_Click({
        $c = & $selected
        if ($c -and (Test-SessionId $c.Id)) { [Windows.Forms.Clipboard]::SetText("claude --resume $($c.Id)"); $bCopy.Text = 'Copied' }
    })
    $d.Controls.Add($lv)
    $d.Controls.Add($bar)
    [void]$d.ShowDialog($form)
}

# --- Wiring --------------------------------------------------------------------------------------

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action } catch { $lblLast.Text = "Error: $($_.Exception.Message)" }
}

$btnSync.add_Click({ Invoke-Safely { Invoke-SyncNow } })
$btnPause.add_Click({ Invoke-Safely { Switch-Pause } })
$btnPair.add_Click({ Invoke-Safely { Show-PairDialog } })
$btnChats.add_Click({ Invoke-Safely { Show-ChatsDialog } })
$btnAdvanced.add_Click({ Invoke-Safely { Initialize-Api; Start-Process ($script:ApiBase -replace '/rest$', '/') } })
$btnAccept.add_Click({
    Invoke-Safely {
        # Re-check at click time: a device may have been paired since the banner appeared.
        $prompt = Get-PairingPrompt @(Get-Peers) @(Get-PendingDevices)
        if (-not $prompt -or -not $prompt.AllowAccept -or $prompt.Device.Id -ne $banner.Tag.Id) { Update-View; return }
        # Anyone who knows this device's ID can send a request with a convincing name. Proof that it is
        # your machine: its setup printed the same ID there.
        $typed = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Type the first 7 characters of the device ID that your other machine shows.`n`nSetup printed it there as: This device's ID.",
            'Confirm it is your machine', '')
        if (-not (Test-IdConfirmation $prompt.Device.Id $typed)) {
            if ($typed) { Show-Message 'Not paired: those characters do not match this request, so it may not be your machine.' 'Warning' }
            return
        }
        Add-Peer $prompt.Device.Id $prompt.Device.Name
        $banner.Visible = $false
        Invoke-SyncNow
    }
})
$btnIgnore.add_Click({
    Invoke-Safely {
        $p = $banner.Tag
        Block-Device $p.Id $p.Name $p.Address
        $banner.Visible = $false
        Update-View
    }
})
$miOpen.add_Click({ Show-Main })
$miSync.add_Click({ Invoke-Safely { Invoke-SyncNow } })
$miPause.add_Click({ Invoke-Safely { Switch-Pause } })
$notify.add_DoubleClick({ Show-Main })
$miExit.add_Click({
    $state.Exiting = $true
    $notify.Visible = $false
    $form.Close()
    [Windows.Forms.Application]::ExitThread()
})
$form.add_FormClosing({
    # In a PowerShell event handler, $_ is the event's arguments.
    if (-not $state.Exiting) { $_.Cancel = $true; $form.Hide() }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({
    Invoke-Safely {
        if ($showSignal.WaitOne(0)) { Show-Main }
        $state.Ticks++
        # Refresh every 3 s while the window is open, every 15 s in the tray.
        if ($form.Visible -or $state.SyncRequested -or ($state.Ticks % 5 -eq 0)) { Update-View }
        if (((Get-Date) - $state.LastMaintenance).TotalMinutes -ge 5) { Invoke-Maintenance }
    }
})
if ($Screenshot) {
    $notify.Visible = $false
    $state.LastInSync = (Get-Date).Date.AddHours(14).AddMinutes(32)
    $form.StartPosition = 'Manual'
    $form.Location = New-Object Drawing.Point(40, 40)
    $form.Size = New-Object Drawing.Size(860, 330)
    Show-Main
    for ($i = 0; $i -lt 5; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    $full = New-Object Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($full, (New-Object Drawing.Rectangle 0, 0, $form.Width, $form.Height))
    # Keep the client area only: Form.DrawToBitmap paints the title bar in an old Windows style.
    $origin = $form.PointToScreen([Drawing.Point]::Empty)
    $client = New-Object Drawing.Rectangle ($origin.X - $form.Left), ($origin.Y - $form.Top), $form.ClientSize.Width, $form.ClientSize.Height
    $shot = $full.Clone($client, $full.PixelFormat)
    $g = [Drawing.Graphics]::FromImage($shot)
    $g.DrawRectangle((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(200, 205, 212))), 0, 0, $shot.Width - 1, $shot.Height - 1)
    $g.Dispose()
    $shot.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
    $notify.Dispose()
    return
}

$timer.Start()

if (-not $Tray) { Show-Main }
[Windows.Forms.Application]::Run()
$notify.Dispose()
$mutex.ReleaseMutex()
