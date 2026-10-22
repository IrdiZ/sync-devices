# Shared helpers for Sync Devices: Syncthing REST access, the shared folder spec, the transcript
# scan, and Claude chat-folder links. Dot-source this file.

$script:AppDir = Join-Path $env:LOCALAPPDATA 'SyncDevices'
$script:SharedDir = Join-Path $script:AppDir 'shared'
$script:SpecPath = Join-Path $script:SharedDir 'sync-devices.json'
$script:ConfigFolderId = 'sync-devices-config'
$script:ClaudeFolderId = 'claude-home'
$script:StConfig = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
$script:ApiKey = $null
$script:ApiBase = $null
$script:SpecCache = $null
$script:SpecStamp = $null
$script:DeviceIdPattern = '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$'
$script:DefaultIgnore = @('node_modules', '.venv', '__pycache__', '*.pyc', '.next', '.pytest_cache', '.git/worktrees',
    '(?d)Thumbs.db', '(?d)desktop.ini')
# From ~\.claude only these sync; settings.json and plugins stay per machine.
$script:ClaudeAllow = @('!/CLAUDE.md', '!/skills', '!/plans', '!/agents', '!/commands', '!/projects', '/*')

# --- Syncthing ------------------------------------------------------------------------------------

function Get-SyncthingExe {
    $cmd = Get-Command syncthing.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $exe = Get-ChildItem -LiteralPath $pkgs -Recurse -Filter syncthing.exe -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

function Initialize-Api {
    if ($script:ApiKey) { return }
    $xml = [xml](Get-Content -LiteralPath $script:StConfig -Raw)
    $script:ApiKey = $xml.configuration.gui.apikey
    $script:ApiBase = "http://$($xml.configuration.gui.address)/rest"
}

function Invoke-St {
    param([string]$Path, [string]$Method = 'GET', $Body = $null)
    Initialize-Api
    $req = @{
        Method = $Method; Uri = "$script:ApiBase/$Path"; TimeoutSec = 15; UseBasicParsing = $true
        Headers = @{ 'X-API-Key' = $script:ApiKey }
    }
    if ($null -ne $Body) {
        $req.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 20))
        $req.ContentType = 'application/json; charset=utf-8'
    }
    # Windows PowerShell 5.1 returns a JSON array as one object; emitting the variable unrolls it.
    $result = Invoke-RestMethod @req
    $result
}

function Test-StRunning {
    if (-not (Test-Path -LiteralPath $script:StConfig)) { return $false }
    try { $null = Invoke-St -Path 'system/ping'; return $true } catch { return $false }
}

function Start-Syncthing {
    if (Test-StRunning) { return $true }
    $exe = Get-SyncthingExe
    if (-not $exe) { throw 'Syncthing is not installed. Run Setup-SyncDevices.ps1 first.' }
    Start-Process -FilePath $exe -ArgumentList 'serve', '--no-browser', '--no-console' -WindowStyle Hidden
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        # The first start may move the GUI to a free port and rewrite config.xml; read it again.
        $script:ApiKey = $null
        if (Test-StRunning) { return $true }
    }
    return $false
}

function Get-MyId { (Invoke-St -Path 'system/status').myID }

function Get-Peers {
    # Only machines paired through Sync Devices. The same Syncthing install can know other devices
    # (a NAS, a friend's PC); they must never receive Claude data.
    $me = Get-MyId
    $spec = Get-Spec
    if (-not $spec) { return @() }
    $known = @($spec.canonical.deviceId) + @(Get-Field $spec 'devices' @())
    @(Invoke-St -Path 'config/devices' | Where-Object { $_.deviceID -ne $me -and $known -contains $_.deviceID })
}

function Get-Field($Obj, [string]$Name, $Default = $null) {
    if ($Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    $Default
}

function Register-Peer([string]$DeviceId) {
    $spec = Get-Spec
    if (-not $spec -or $DeviceId -eq $spec.canonical.deviceId) { return }
    $list = @(Get-Field $spec 'devices' @() | Where-Object { $_ })
    if ($list -contains $DeviceId) { return }
    $spec | Add-Member -NotePropertyName devices -NotePropertyValue @($list + $DeviceId) -Force
    Save-Spec $spec
}

function Set-PeersPaused([bool]$Paused) {
    foreach ($p in Get-Peers) {
        $p.paused = $Paused
        $null = Invoke-St -Method PUT -Path "config/devices/$($p.deviceID)" -Body $p
    }
}

function Test-ManagedFolder([string]$FolderId) {
    $spec = Get-Spec
    if ($FolderId -in @($script:ConfigFolderId, $script:ClaudeFolderId)) { return $true }
    if (-not $spec) { return $false }
    if (@($spec.folders | Where-Object { $_.id -eq $FolderId }).Count) { return $true }
    [bool](@($spec.mirrors | Where-Object { $FolderId.StartsWith("$($_.id)-") }).Count)
}

function Get-PeerName($Device) {
    if ($Device.name) { return $Device.name }
    $Device.deviceID.Substring(0, 7)
}

function Assert-DeviceId([string]$DeviceId) {
    $id = $DeviceId.Trim().ToUpper()
    if ($id -notmatch $script:DeviceIdPattern) {
        $blocks = @($id -split '-' | Where-Object { $_ }).Count
        throw "This is not a device ID: $DeviceId`nA device ID has 8 blocks of 7 characters; this one has $blocks. Copy it again in full."
    }
    $id
}

function Add-Device([string]$DeviceId, [string]$Name = '') {
    $id = Assert-DeviceId $DeviceId
    # Keep an existing entry as it is (its name, addresses, pause state); only add new devices.
    try { $null = Invoke-St -Path "config/devices/$id"; return $id } catch { }
    $dev = Invoke-St -Path 'config/defaults/device'
    $dev.deviceID = $id
    $dev.name = $Name
    $null = Invoke-St -Method PUT -Path "config/devices/$id" -Body $dev
    $id
}

function Add-Peer([string]$DeviceId, [string]$Name = '') {
    $id = Add-Device $DeviceId $Name
    Register-Peer $id
    Update-SharedFolders
}

function Get-PendingDevices {
    $p = Invoke-St -Path 'cluster/pending/devices'
    if (-not $p) { return @() }
    @($p.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{ Id = $_.Name; Name = $_.Value.name; Address = $_.Value.address }
    })
}

function Get-PairingPrompt($Peers, $Pending) {
    # The name in a request is chosen by the sender and can copy a real machine's name. So once a
    # device is paired, a new request is never offered for Accept; a real new machine is added
    # with "Pair device" and its ID.
    $p = @($Pending | Where-Object { $_ }) | Select-Object -First 1
    if (-not $p) { return $null }
    $calls = $(if ($p.Name) { "calls itself `"$($p.Name)`"" } else { 'sends no name' })
    if (@($Peers | Where-Object { $_ }).Count -eq 0) {
        return [pscustomobject]@{ Device = $p; AllowAccept = $true
            Text = "A device asks to pair ($calls). Accept only if your other machine shows this ID:`n$($p.Id)" }
    }
    [pscustomobject]@{ Device = $p; AllowAccept = $false
        Text = "Unknown device asks to pair ($calls). Your devices are already paired, so it is not one of them:`n$($p.Id)" }
}

function Block-Device([string]$DeviceId, [string]$Name = '', [string]$Address = '') {
    # Syncthing then refuses the device without asking again. It has no REST endpoint for this
    # list alone, so the whole config goes back with the entry added.
    $cfg = Invoke-St -Path 'config'
    $ignored = @($cfg.remoteIgnoredDevices | Where-Object { $_ })
    if (-not ($ignored | Where-Object { $_.deviceID -eq $DeviceId })) {
        $cfg.remoteIgnoredDevices = $ignored + [pscustomobject]@{
            deviceID = $DeviceId; name = $Name; address = $Address; time = (Get-Date).ToUniversalTime().ToString('o')
        }
        $null = Invoke-St -Method PUT -Path 'config' -Body $cfg
    }
    try { $null = Invoke-St -Method DELETE -Path "cluster/pending/devices?device=$DeviceId" } catch { }
}

function Test-IdConfirmation([string]$DeviceId, [string]$Typed) {
    # Proof that a pairing request comes from your own machine: its setup printed the same ID there.
    $t = "$Typed".Trim().ToUpper()
    $t.Length -eq 7 -and $DeviceId.StartsWith($t)
}

# --- Trust boundaries -----------------------------------------------------------------------------
# A paired machine can edit the shared folder list and syncs transcripts that feed the scan. So every
# folder ID, folder path and chat ID that came from there is checked before it is used.

function Test-SafeFolderId([string]$Id) {
    # Folder IDs end up in REST URLs and folder names: no separators, no "..".
    $Id -cmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -and $Id -notmatch '\.\.'
}

function Test-SessionId([string]$Id) {
    # Claude Code session IDs are UUIDs; anything else never reaches a command line.
    $Id -match '^[A-Za-z0-9][A-Za-z0-9-]{0,99}$'
}

function Test-SafeSyncPath([string]$Path) {
    # Never sync folders where synced files run code (Startup, Program Files) or hold credentials.
    if ($Path -notmatch '^[A-Za-z]:\\.' -or $Path -match '(^|\\)\.\.(\\|$)') { return $false }
    $p = $Path.TrimEnd('\')
    $userHome = $env:USERPROFILE
    $claudeApp = Join-Path $env:APPDATA 'Claude'
    if ($p.Equals($claudeApp, 'OrdinalIgnoreCase') -or $p.StartsWith("$claudeApp\", 'OrdinalIgnoreCase')) { return $true }
    if ($p.Equals($userHome, 'OrdinalIgnoreCase')) { return $false }
    $deny = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Join-Path $userHome 'AppData')) +
        @('.ssh', '.gnupg', '.aws', '.azure', '.kube', '.docker', '.config', '.git-credentials' | ForEach-Object { Join-Path $userHome $_ })
    -not ($deny | Where-Object { $_ -and ($p.Equals($_, 'OrdinalIgnoreCase') -or $p.StartsWith("$_\", 'OrdinalIgnoreCase')) })
}

# --- The shared spec ------------------------------------------------------------------------------
# sync-devices.json lives in its own synced folder, so every paired machine has the same list.
# Paths use {HOME}, {DESKTOP} and {APPDATA}; each machine fills in its own values. "canonical"
# records the first machine: its Claude chat-folder names are the ones that sync.

function Get-Spec {
    if (-not (Test-Path -LiteralPath $script:SpecPath)) { return $null }
    $stamp = (Get-Item -LiteralPath $script:SpecPath).LastWriteTimeUtc
    if ($stamp -ne $script:SpecStamp) {
        $script:SpecCache = Get-Content -LiteralPath $script:SpecPath -Raw | ConvertFrom-Json
        $script:SpecStamp = $stamp
    }
    $script:SpecCache
}

function Save-Spec($Spec) {
    New-Item -ItemType Directory -Force -Path $script:SharedDir | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($script:SpecPath, (ConvertTo-Json -InputObject $Spec -Depth 10), $utf8)
    $script:SpecStamp = $null
}

function Get-LocalVars {
    # SYNCDEVICES_DESKTOP is a test hook: it lets a second instance run on the same machine.
    $desktop = $(if ($env:SYNCDEVICES_DESKTOP) { $env:SYNCDEVICES_DESKTOP } else { [Environment]::GetFolderPath('Desktop') })
    @{ HOME = $env:USERPROFILE; DESKTOP = $desktop; APPDATA = $env:APPDATA }
}

function Get-CanonicalVars {
    $c = (Get-Spec).canonical
    @{ HOME = $c.HOME; DESKTOP = $c.DESKTOP; APPDATA = $c.APPDATA }
}

function Expand-SpecPath([string]$Path, [hashtable]$Vars) {
    foreach ($k in $Vars.Keys) { $Path = $Path.Replace("{$k}", $Vars[$k]) }
    $Path
}

function ConvertTo-SpecPath([string]$Path, [hashtable]$Vars) {
    # Most specific first: Desktop and AppData usually sit inside the home folder.
    foreach ($k in 'DESKTOP', 'APPDATA', 'HOME') {
        $v = $Vars[$k]
        if ($Path.Equals($v, [StringComparison]::OrdinalIgnoreCase)) { return "{$k}" }
        if ($Path.StartsWith("$v\", [StringComparison]::OrdinalIgnoreCase)) { return "{$k}" + $Path.Substring($v.Length) }
    }
    $Path
}

function Test-IsCanonicalMachine {
    $spec = Get-Spec
    $spec -and $spec.canonical.deviceId -eq (Get-MyId)
}

function New-Spec([string]$DeviceId, $Folders) {
    $lv = Get-LocalVars
    [pscustomobject]@{
        version   = 1
        canonical = [pscustomobject]@{
            deviceId = $DeviceId; machine = $env:COMPUTERNAME; HOME = $lv.HOME; DESKTOP = $lv.DESKTOP; APPDATA = $lv.APPDATA
        }
        devices   = @()
        ignore    = $script:DefaultIgnore
        folders   = @($Folders)
        mirrors   = @([pscustomobject]@{ id = 'claude-scratch'; label = 'Claude app scratch work'; path = '{APPDATA}\Claude\scratch-workspaces' })
    }
}

function New-FolderId([string]$Path, $Taken) {
    $base = ((Split-Path $Path -Leaf).ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $base) { $base = 'folder' }
    $id = $base
    for ($n = 2; $Taken -contains $id -or $id -in @($script:ConfigFolderId, $script:ClaudeFolderId); $n++) { $id = "$base-$n" }
    $id
}

function Get-FolderPlan {
    $spec = Get-Spec
    $lv = Get-LocalVars
    [pscustomobject]@{
        Id = $script:ConfigFolderId; Label = 'Sync Devices settings'; Path = $script:SharedDir
        Type = 'sendreceive'; ClaudeHome = $false; Ignore = @('// Managed by Sync Devices.')
    }
    if (-not $spec) { return }
    $managed = @('// Managed by Sync Devices. Setup overwrites this file.')
    $claudeIgnore = $managed
    # Local chat-folder names are junctions to the canonical folders; only the canonical ones sync.
    foreach ($p in @(Get-KeyPairs)) { $claudeIgnore += "(?i)/projects/$($p.Local)"; $claudeIgnore += "(?i)/projects/$($p.Local)-*" }
    [pscustomobject]@{
        Id = $script:ClaudeFolderId; Label = 'Claude chats, memory, skills'; Path = (Join-Path $lv.HOME '.claude')
        Type = 'sendreceive'; ClaudeHome = $true; Ignore = @($claudeIgnore + $script:ClaudeAllow)
    }
    foreach ($f in $spec.folders) {
        $p = Expand-SpecPath $f.path $lv
        if (-not (Test-SafeFolderId $f.id) -or -not (Test-SafeSyncPath $p)) {
            Write-Warning "Skipped an unsafe entry in the folder list: $($f.id) -> $p"
            continue
        }
        [pscustomobject]@{
            Id = $f.id; Label = $f.label; Path = $p
            Type = 'sendreceive'; ClaudeHome = $false; Ignore = @($managed + $spec.ignore)
        }
    }
    # Each machine publishes its own scratch folder one way; the others keep a read-only copy.
    foreach ($m in $spec.mirrors) {
        $p = Expand-SpecPath $m.path $lv
        if (-not (Test-SafeFolderId $m.id) -or -not (Test-SafeSyncPath $p)) {
            Write-Warning "Skipped an unsafe mirror in the folder list: $($m.id) -> $p"
            continue
        }
        if (Test-Path -LiteralPath $p) {
            [pscustomobject]@{
                Id = "$($m.id)-$($env:COMPUTERNAME.ToLower())"; Label = "$($m.label) ($env:COMPUTERNAME)"; Path = $p
                Type = 'sendonly'; ClaudeHome = $false; Ignore = @($managed + $spec.ignore)
            }
        }
    }
}

function Write-IgnoreFile($Item) {
    $path = Join-Path $Item.Path '.stignore'
    # Syncthing marks .stignore hidden on Windows, and .NET refuses to overwrite a hidden file.
    if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path -Force).Attributes = 'Normal' }
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllLines($path, [string[]]$Item.Ignore, $utf8)
}

function Set-StFolder($Item, [string[]]$DeviceIds) {
    $cfg = $null
    try { $cfg = Invoke-St -Path "config/folders/$($Item.Id)" } catch { }
    if (-not $cfg) {
        $cfg = Invoke-St -Path 'config/defaults/folder'
        $cfg.id = $Item.Id
        # Trash-can versioning keeps the last replaced or deleted copy of each file for 30 days.
        $cfg.versioning = [pscustomobject]@{
            type = 'trashcan'; params = @{ cleanoutDays = '30' }; cleanupIntervalS = 3600; fsPath = ''; fsType = 'basic'
        }
    }
    $cfg.label = $Item.Label
    $cfg.path = $Item.Path
    $cfg.type = $Item.Type
    $cfg.devices = @($DeviceIds | Select-Object -Unique | ForEach-Object {
        [pscustomobject]@{ deviceID = $_; introducedBy = ''; encryptionPassword = '' }
    })
    $null = Invoke-St -Method PUT -Path "config/folders/$($Item.Id)" -Body $cfg
}

function Get-DeviceIds { @(Get-MyId) + @(Get-Peers | ForEach-Object { $_.deviceID }) }

function Update-SharedFolders {
    $ids = Get-DeviceIds
    foreach ($item in Get-FolderPlan) {
        try { $null = Invoke-St -Path "config/folders/$($item.Id)" } catch { continue }
        Set-StFolder $item $ids
    }
}

function Approve-PendingMirrors {
    $spec = Get-Spec
    if (-not $spec) { return }
    $pending = Invoke-St -Path 'cluster/pending/folders'
    if (-not $pending) { return }
    $prefixes = @($spec.mirrors | ForEach-Object { "$($_.id)-" })
    foreach ($prop in $pending.PSObject.Properties) {
        $id = $prop.Name
        if (-not (Test-SafeFolderId $id) -or -not ($prefixes | Where-Object { $id.StartsWith($_) })) { continue }
        $offers = @($prop.Value.offeredBy.PSObject.Properties)
        $path = Join-Path $env:USERPROFILE "SyncDevices\$id"
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        $item = [pscustomobject]@{ Id = $id; Label = $offers[0].Value.label; Path = $path; Type = 'receiveonly' }
        Set-StFolder $item (@(Get-MyId) + @($offers | ForEach-Object { $_.Name }))
    }
}

# --- Folder scan -----------------------------------------------------------------------------------

function Measure-Folder([string]$Path) {
    $skip = @('node_modules', '.venv', '__pycache__', '.next', '.pytest_cache')
    $total = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push([IO.DirectoryInfo]$Path)
    while ($stack.Count) {
        $d = $stack.Pop()
        try {
            foreach ($f in $d.EnumerateFiles()) { $total += $f.Length }
            foreach ($s in $d.EnumerateDirectories()) {
                $isLink = $s.Attributes -band [IO.FileAttributes]::ReparsePoint
                if (-not $isLink -and $skip -notcontains $s.Name) { $stack.Push($s) }
            }
        } catch { }
    }
    $total
}

function Find-ClaudeFolders([string]$ProjectsDir = (Join-Path $env:USERPROFILE '.claude\projects')) {
    # Every folder a Claude session worked in or touched a file in, read from the transcripts.
    # A path becomes its git repository root, or else its own folder. Broad folders (home, Desktop,
    # Documents, Downloads, a drive) never become a sync folder themselves.
    $lv = Get-LocalVars
    $rx = [regex]'"(?:cwd|file_path|notebook_path|path)":"([A-Za-z]:\\\\(?:[^"\\]|\\.)*)"'
    $seen = @{}
    foreach ($file in Get-ChildItem -LiteralPath $ProjectsDir -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($m in $rx.Matches($text)) {
            $p = $m.Groups[1].Value.Replace('\\', '\').TrimEnd('\')
            $p = $p.Substring(0, 1).ToUpper() + $p.Substring(1)
            if (-not $seen.ContainsKey($p)) { $seen[$p] = New-Object 'System.Collections.Generic.HashSet[string]' }
            [void]$seen[$p].Add($file.BaseName)
        }
    }

    $broad = @($lv.HOME, $lv.DESKTOP, [Environment]::GetFolderPath('MyDocuments'), (Join-Path $lv.HOME 'Downloads'),
        (Join-Path $lv.HOME 'OneDrive')) + @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.RootDirectory.FullName.TrimEnd('\') })
    $excluded = @($env:LOCALAPPDATA, $env:APPDATA, $env:TEMP, $env:ProgramData, $env:SystemRoot, ${env:ProgramFiles}, ${env:ProgramFiles(x86)},
        (Join-Path $lv.HOME '.claude')) | Where-Object { $_ }
    function Test-Under([string]$Path, [string]$Root) {
        $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith("$Root\", [StringComparison]::OrdinalIgnoreCase)
    }
    function Test-Broad([string]$Path) {
        $p = $Path.TrimEnd('\')
        [bool]($broad | Where-Object { $p.Equals($_.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) })
    }

    $roots = @{}
    foreach ($p in $seen.Keys) {
        if ($excluded | Where-Object { Test-Under $p $_ }) { continue }
        $dir = $p
        if (Test-Path -LiteralPath $dir -PathType Leaf) { $dir = Split-Path $dir }
        elseif (-not (Test-Path -LiteralPath $dir)) {
            # A deleted file still means its folder was touched.
            $dir = Split-Path $dir
            if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        }
        $root = $null
        for ($d = $dir; $d -and -not (Test-Broad $d); $d = Split-Path $d) {
            if (Test-Path -LiteralPath (Join-Path $d '.git')) { $root = $d; break }
        }
        if (-not $root) { $root = $dir }
        if ((Test-Broad $root) -or -not (Test-SafeSyncPath $root)) { continue }
        if (-not $roots.ContainsKey($root)) { $roots[$root] = New-Object 'System.Collections.Generic.HashSet[string]' }
        foreach ($s in $seen[$p]) { [void]$roots[$root].Add($s) }
    }

    foreach ($r in $roots.Keys | Sort-Object) {
        $bytes = Measure-Folder $r
        [pscustomobject]@{
            Path = $r; SpecPath = (ConvertTo-SpecPath $r $lv); Chats = $roots[$r].Count; Bytes = $bytes
            # Big folders start unticked: they are usually a parent of the real project.
            Selected = $bytes -le 2GB
        }
    }
}

function Select-OuterFolders($Folders) {
    # A folder inside another chosen folder already syncs with it.
    $list = @($Folders | Sort-Object { $_.Path.Length })
    $kept = @()
    foreach ($f in $list) {
        $inside = $kept | Where-Object { $f.Path.StartsWith("$($_.Path)\", [StringComparison]::OrdinalIgnoreCase) }
        if (-not $inside) { $kept += $f }
    }
    $kept
}

function ConvertTo-SpecFolders($Folders) {
    $taken = @()
    foreach ($f in Select-OuterFolders $Folders) {
        $id = New-FolderId $f.Path $taken
        $taken += $id
        [pscustomobject]@{ id = $id; label = (Split-Path $f.Path -Leaf); path = $f.SpecPath }
    }
}

# --- Claude chat folders ---------------------------------------------------------------------------
# Claude Code stores each project's chats and memory in ~\.claude\projects\<path with non-alphanumerics
# as '-'>, so the same project has a different folder name on each machine. The canonical machine's
# names are the ones that sync; on other machines the local name becomes a junction to the canonical one.

function ConvertTo-ClaudeKey([string]$Path) { $Path -replace '[^A-Za-z0-9]', '-' }

function Get-KeyPairs {
    if (-not (Get-Spec)) { return @() }
    $lv = Get-LocalVars
    $cv = Get-CanonicalVars
    $roots = @((Get-Spec).folders | ForEach-Object { $_.path }) + '{HOME}'
    $pairs = foreach ($r in $roots) {
        $c = ConvertTo-ClaudeKey (Expand-SpecPath $r $cv)
        $l = ConvertTo-ClaudeKey (Expand-SpecPath $r $lv)
        if ($c -ne $l) { [pscustomobject]@{ Canon = $c; Local = $l; CanonPath = (Expand-SpecPath $r $cv); LocalPath = (Expand-SpecPath $r $lv) } }
    }
    @($pairs | Sort-Object { $_.Canon.Length } -Descending)
}

function Find-KeyPair($Pairs, [string]$Name, [string]$Side) {
    foreach ($p in $Pairs) {
        $prefix = $p.$Side
        if ($Name.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $Name.StartsWith("$prefix-", [StringComparison]::OrdinalIgnoreCase)) { return $p }
    }
    return $null
}

function Test-IsLink($Item) { [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) }

function Merge-Folder([string]$From, [string]$To) {
    foreach ($item in @(Get-ChildItem -LiteralPath $From -Force)) {
        $dest = Join-Path $To $item.Name
        if ($item.PSIsContainer) {
            if (Test-Path -LiteralPath $dest) { Merge-Folder $item.FullName $dest }
            else { Move-Item -LiteralPath $item.FullName -Destination $dest -ErrorAction Stop }
        } elseif (-not (Test-Path -LiteralPath $dest)) {
            Move-Item -LiteralPath $item.FullName -Destination $dest -ErrorAction Stop
        } elseif ((Get-FileHash -LiteralPath $item.FullName).Hash -eq (Get-FileHash -LiteralPath $dest).Hash) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
        } else {
            $alt = Join-Path $To ('{0}.from-{1}{2}' -f $item.BaseName, $env:COMPUTERNAME, $item.Extension)
            Move-Item -LiteralPath $item.FullName -Destination $alt -Force -ErrorAction Stop
        }
    }
}

function Sync-ClaudeChatFolders([string]$ProjectsDir = (Join-Path $env:USERPROFILE '.claude\projects')) {
    $pairs = @(Get-KeyPairs)
    if ($pairs.Count -eq 0 -or -not (Test-Path -LiteralPath $ProjectsDir)) { return }
    foreach ($dir in @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -Force)) {
        $canon = Find-KeyPair $pairs $dir.Name 'Canon'
        if ($canon) {
            $localPath = Join-Path $ProjectsDir ($canon.Local + $dir.Name.Substring($canon.Canon.Length))
            if (-not (Test-Path -LiteralPath $localPath)) {
                New-Item -ItemType Junction -Path $localPath -Target $dir.FullName | Out-Null
            }
            continue
        }
        $local = Find-KeyPair $pairs $dir.Name 'Local'
        if (-not $local -or (Test-IsLink $dir)) { continue }
        $canonName = $local.Canon + $dir.Name.Substring($local.Local.Length)
        $canonPath = Join-Path $ProjectsDir $canonName
        try {
            if (Test-Path -LiteralPath $canonPath) {
                Merge-Folder $dir.FullName $canonPath
                if (@(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -File).Count -gt 0) { continue }
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force
            } else {
                Rename-Item -LiteralPath $dir.FullName -NewName $canonName -ErrorAction Stop
            }
            New-Item -ItemType Junction -Path $dir.FullName -Target $canonPath | Out-Null
        } catch {
            # A chat that is open right now locks its folder; the next run links it.
            Write-Warning "Not linked yet: $($dir.Name) ($($_.Exception.Message))"
        }
    }
}

function Convert-ToLocalPath([string]$Path) {
    foreach ($p in @(Get-KeyPairs)) {
        if ($Path.StartsWith($p.CanonPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $p.LocalPath + $Path.Substring($p.CanonPath.Length)
        }
    }
    if (Test-Path -LiteralPath $Path) { return $Path }
    # A chat from another machine: swap that machine's user folder (and OneDrive Desktop) for ours.
    if ($Path -match '^[A-Za-z]:\\Users\\[^\\]+(\\.*)?$') {
        $rest = $Matches[1]
        if ($rest -match '^\\OneDrive\\Desktop(\\.*)?$') { return (Get-LocalVars).DESKTOP + $Matches[1] }
        return $env:USERPROFILE + $rest
    }
    $Path
}

function Get-ClaudeExe {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $bundled = Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'Claude\claude-code') -Recurse -Filter claude.exe -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($bundled) { return $bundled.FullName }
    return $null
}
