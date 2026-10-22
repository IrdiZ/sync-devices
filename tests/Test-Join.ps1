# End to end: two Sync Devices instances on this machine, each with its own user folder, AppData and
# Syncthing. "A" sets up first, "B" joins, the test clicks Accept on A, then checks that files and
# chats flow both ways. Everything lives in a temp folder. The test refuses to talk to the real
# Syncthing install and only stops Syncthing processes it started.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
. (Join-Path $repo 'SyncDevices.Common.ps1')

$fails = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "PASS  $Name" } else { "FAIL  $Name"; $script:fails++ } }
function New-File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -LiteralPath $Path -Value $Text -NoNewline
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 120) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Seconds 2
    }
    $false
}

$stExe = Get-SyncthingExe
if (-not $stExe) { throw 'Install Syncthing before you run this test.' }
$real = @{ LOCALAPPDATA = $env:LOCALAPPDATA; USERPROFILE = $env:USERPROFILE; APPDATA = $env:APPDATA
    TEMP = $env:TEMP; TMP = $env:TMP; SYNCDEVICES_DESKTOP = $env:SYNCDEVICES_DESKTOP; PATH = $env:PATH }
$realConfig = $script:StConfig
$realPids = @(Get-Process syncthing -ErrorAction SilentlyContinue | ForEach-Object Id)
$started = Get-Date
$T = Join-Path $real.LOCALAPPDATA ('Temp\sd-join-' + [guid]::NewGuid().ToString('N').Substring(0, 6))

function Get-Env([string]$Who) {
    $base = Join-Path $T $Who
    @{ USERPROFILE = "$base\user"; LOCALAPPDATA = "$base\local"; APPDATA = "$base\roaming"; TEMP = "$base\temp"; TMP = "$base\temp"
        SYNCDEVICES_DESKTOP = "$base\user\Desktop"; PATH = (Split-Path $stExe) + ';' + $real.PATH }
}
function Use-Instance([string]$Who) {
    $e = Get-Env $Who
    foreach ($k in $e.Keys) { Set-Item "env:$k" $e[$k] }
    $script:StConfig = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
    $script:AppDir = Join-Path $env:LOCALAPPDATA 'SyncDevices'
    $script:SharedDir = Join-Path $script:AppDir 'shared'
    $script:SpecPath = Join-Path $script:SharedDir 'sync-devices.json'
    $script:ApiKey = $null; $script:SpecStamp = $null
    if ($script:StConfig -eq $realConfig) { throw 'Refusing to talk to the real Syncthing.' }
}
function Start-Setup([string]$Who, [string]$SetupArgs) {
    $e = Get-Env $Who
    $log = Join-Path $T "$Who-setup.log"
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$repo\Setup-SyncDevices.ps1' $SetupArgs -NoShortcuts -NoLaunch *> '$log'`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($k in $e.Keys) { $psi.EnvironmentVariables[$k] = $e[$k] }
    [pscustomobject]@{ Process = [Diagnostics.Process]::Start($psi); Log = $log }
}
function Get-ListenPort {
    $status = Invoke-St -Path 'system/status'
    foreach ($p in $status.connectionServiceStatus.PSObject.Properties) {
        foreach ($addr in @($p.Value.lanAddresses)) { if ($addr -match '^tcp://.*:(\d+)$') { return $Matches[1] } }
    }
    $null
}

try {
    $a = Get-Env 'A'; $b = Get-Env 'B'
    $aApp = "$($a.SYNCDEVICES_DESKTOP)\app"; $bApp = "$($b.SYNCDEVICES_DESKTOP)\app"
    $aKey = ConvertTo-ClaudeKey $aApp; $bKey = ConvertTo-ClaudeKey $bApp
    New-File "$aApp\readme.txt" 'from A'
    New-File "$($a.USERPROFILE)\.claude\projects\$aKey\chat-a.jsonl" 'chat started on A'
    New-File "$bApp\old.txt" 'old copy on B'
    New-File "$($b.USERPROFILE)\.claude\projects\$bKey\chat-b.jsonl" 'chat started on B'
    New-Item -ItemType Directory -Force -Path $a.TEMP, $b.TEMP | Out-Null
    $folderList = Join-Path $T 'folders.json'
    Set-Content -LiteralPath $folderList -Value '{"folders":[{"id":"app","label":"app","path":"{DESKTOP}\\app"}]}'

    "setting up A..."
    $sa = Start-Setup 'A' "-Import '$folderList'"
    Check 'A: setup finished' ($sa.Process.WaitForExit(180000) -and $sa.Process.ExitCode -eq 0)
    Check 'A: became the first machine' ((Get-Content $sa.Log -Raw) -match 'This is the first machine')
    Use-Instance 'A'
    $aId = Get-MyId
    Check 'A: uses its own Syncthing, not the real one' ($script:ApiBase -notmatch ':8384/')
    $aPort = Get-ListenPort

    # An unrelated device in A's Syncthing (think: a NAS). It must never get the folders.
    $dummyHome = Join-Path $T 'dummy'
    & $stExe generate "--home=$dummyHome" | Out-Null
    $dummyId = (& $stExe device-id "--home=$dummyHome" | Select-Object -Last 1).Trim()
    $null = Add-Device $dummyId 'NAS'

    "B joins A..."
    $sb = Start-Setup 'B' "-Join $aId"
    Use-Instance 'B'
    Check 'B: pairing request sent to A' (Wait-Until { (Test-StRunning) -and (Invoke-St -Path "config/devices/$aId") } 120)
    $bId = Get-MyId
    $dev = Invoke-St -Path "config/devices/$aId"
    $dev.addresses = @("tcp://127.0.0.1:$aPort")
    $null = Invoke-St -Method PUT -Path "config/devices/$aId" -Body $dev

    Use-Instance 'A'
    Check 'A: sees the request' (Wait-Until { @(Get-PendingDevices | Where-Object { $_.Id -eq $bId }).Count } 120)
    $prompt = Get-PairingPrompt @(Get-Peers) @(Get-PendingDevices)
    Check 'A: first pairing offers Accept (the NAS does not count)' ($prompt -and $prompt.AllowAccept -and $prompt.Device.Id -eq $bId)
    Add-Peer $bId                                    # the Accept click
    $shared = @((Invoke-St -Path 'config/folders/app').devices | ForEach-Object { $_.deviceID })
    Check 'A: app folder shared with B' ($shared -contains $bId)
    Check 'A: app folder NOT shared with the NAS' ($shared -notcontains $dummyId)

    Check 'B: setup finished after Accept' ($sb.Process.WaitForExit(240000) -and $sb.Process.ExitCode -eq 0)
    Check 'B: knows it follows A' ((Get-Content $sb.Log -Raw) -match 'This machine syncs with')
    Use-Instance 'B'
    $backup = @(Get-ChildItem -LiteralPath $b.SYNCDEVICES_DESKTOP -Directory -Filter 'app.before-sync-*')
    Check "B: old folder kept as backup" ($backup.Count -eq 1 -and (Test-Path (Join-Path $backup[0].FullName 'old.txt')))
    Check 'B: received A''s file' (Wait-Until { (Get-Content "$bApp\readme.txt" -Raw) -eq 'from A' } 120)
    Check 'B: spec says A is canonical and B is paired' ((Get-Spec).canonical.deviceId -eq $aId -and (@((Get-Spec).devices) -contains $bId))
    $bProj = "$($b.USERPROFILE)\.claude\projects"
    Check 'B: received A''s chat under the canonical name' (Wait-Until { Test-Path "$bProj\$aKey\chat-a.jsonl" } 120)
    $link = Get-Item -LiteralPath "$bProj\$bKey" -Force -ErrorAction SilentlyContinue
    Check 'B: local chat folder is a junction to the canonical one' ($link -and $link.LinkType -eq 'Junction' -and @($link.Target)[0] -eq "$bProj\$aKey")
    Check 'B: Claude on B sees A''s chat through its own path' (Test-Path "$bProj\$bKey\chat-a.jsonl")

    Use-Instance 'A'
    Check 'A: received the chat started on B' (Wait-Until { (Get-Content "$($a.USERPROFILE)\.claude\projects\$aKey\chat-b.jsonl" -Raw) -eq 'chat started on B' } 120)
    New-File "$bApp\from-b.txt" 'written on B'
    Check 'A: received a new file written on B' (Wait-Until { (Get-Content "$aApp\from-b.txt" -Raw) -eq 'written on B' } 120)
    Check 'A: B''s old copy did not leak to A' (-not (Test-Path "$aApp\old.txt"))
} finally {
    foreach ($who in 'A', 'B') {
        try {
            Use-Instance $who
            if ((Test-StRunning) -and $script:ApiBase -notmatch ':8384/') { $null = Invoke-St -Method POST -Path 'system/shutdown' }
        } catch { }
    }
    foreach ($k in $real.Keys) { if ($null -eq $real[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $real[$k] } }
    Start-Sleep -Seconds 3
    Get-Process syncthing -ErrorAction SilentlyContinue |
        Where-Object { $realPids -notcontains $_.Id -and $_.StartTime -gt $started } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    foreach ($who in 'A', 'B') {
        $proj = Join-Path $T "$who\user\.claude\projects"
        if (Test-Path $proj) { Get-ChildItem -LiteralPath $proj -Force | Where-Object { $_.LinkType } | ForEach-Object { [IO.Directory]::Delete($_.FullName) } }
    }
    if ($fails) { "logs kept in $T" } else { Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue }
}
"`n$fails failure(s)"
exit $fails
