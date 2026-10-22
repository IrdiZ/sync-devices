# Chat-folder linking on a simulated second machine. The canonical machine's user is "alex", this
# machine's user is "sam". Works in a temp folder only; touches nothing else.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\SyncDevices.Common.ps1')

$fails = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "PASS  $Name" } else { "FAIL  $Name"; $script:fails++ } }
function New-File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -LiteralPath $Path -Value $Text -NoNewline
}
function Test-Junction([string]$Path) { (Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).LinkType -eq 'Junction') }
function Get-Target([string]$Path) { @((Get-Item -LiteralPath $Path -Force).Target)[0] }
function Get-Tree([string]$Path) { @(Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object FullName) -join '|' }

function Get-Spec {
    [pscustomobject]@{
        canonical = [pscustomobject]@{ deviceId = 'X'; HOME = 'C:\Users\alex'; DESKTOP = 'C:\Users\alex\Desktop'; APPDATA = 'C:\Users\alex\AppData\Roaming' }
        devices = @(); ignore = @(); mirrors = @()
        folders = @([pscustomobject]@{ id = 'app'; label = 'app'; path = '{DESKTOP}\app' },
            [pscustomobject]@{ id = 'tools'; label = 'tools'; path = 'C:\tools' })
    }
}
$alex = @{ HOME = 'C:\Users\alex'; DESKTOP = 'C:\Users\alex\Desktop'; APPDATA = 'C:\Users\alex\AppData\Roaming' }
$sam = @{ HOME = 'C:\Users\sam'; DESKTOP = 'C:\Users\sam\Desktop'; APPDATA = 'C:\Users\sam\AppData\Roaming' }
$script:Vars = $alex
function Get-LocalVars { $script:Vars }

# Long-form temp path: $env:TEMP can use an 8.3 name, while junction targets use the long name.
$T = Join-Path $env:LOCALAPPDATA ('Temp\sd-link-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$P = Join-Path $T 'projects'
$canon = Join-Path $P 'C--Users-alex-Desktop-app'
$localReal = Join-Path $P 'C--Users-sam-Desktop-app'
try {
    New-File "$canon\a.jsonl" 'same'
    New-File "$canon\memory\MEMORY.md" 'canonical memory'
    New-File "$localReal\a.jsonl" 'same'
    New-File "$localReal\b.jsonl" 'local chat'
    New-File "$localReal\memory\MEMORY.md" 'local memory'
    New-File "$P\C--Users-sam-Desktop-app-sub\c.jsonl" 'new local project'
    New-File "$P\C--Users-alex-Desktop-other\d.jsonl" 'canonical only'
    New-File "$P\C--tools\e.jsonl" 'same path on both machines'
    New-File "$P\C--Users-alexander-notes\f.jsonl" 'prefix trap: alexander is not alex'

    $before = Get-Tree $P
    Sync-ClaudeChatFolders $P
    Check 'canonical machine: nothing changes' ((Get-Tree $P) -eq $before)

    $script:Vars = $sam
    Check 'key pairs exist for the home and Desktop folders' (@(Get-KeyPairs | Where-Object { $_.Local -eq 'C--Users-sam' }).Count -eq 1)
    Sync-ClaudeChatFolders $P
    Check 'local folder became a junction' (Test-Junction $localReal)
    Check 'junction points at the canonical folder' ((Get-Target $localReal) -eq $canon)
    Check 'local chat moved into canonical' ((Get-Content "$canon\b.jsonl" -Raw) -eq 'local chat')
    Check 'identical file kept once' ((Get-Content "$canon\a.jsonl" -Raw) -eq 'same')
    Check 'canonical memory kept' ((Get-Content "$canon\memory\MEMORY.md" -Raw) -eq 'canonical memory')
    $alt = "$canon\memory\MEMORY.from-$env:COMPUTERNAME.md"
    Check 'conflicting local memory kept beside it' ((Test-Path $alt) -and (Get-Content $alt -Raw) -eq 'local memory')
    Check 'new local project renamed to canonical' (Test-Path "$P\C--Users-alex-Desktop-app-sub\c.jsonl")
    Check 'new local project name is a junction' (Test-Junction "$P\C--Users-sam-Desktop-app-sub")
    Check 'canonical-only project gets a local junction' ((Get-Target "$P\C--Users-sam-Desktop-other") -eq "$P\C--Users-alex-Desktop-other")
    Check 'same-path project untouched' (-not (Test-Junction "$P\C--tools"))
    Check 'prefix trap untouched' ((Test-Path "$P\C--Users-alexander-notes\f.jsonl") -and -not (Get-ChildItem $P -Force | Where-Object { $_.Name -like 'C--Users-samander*' }))
    Set-Content "$localReal\g.jsonl" 'via link' -NoNewline
    Check 'writing through the junction lands in canonical' ((Get-Content "$canon\g.jsonl" -Raw) -eq 'via link')

    $snap = Get-Tree $P
    Sync-ClaudeChatFolders $P
    Check 'second run changes nothing' ((Get-Tree $P) -eq $snap)

    $lockedDir = "$P\C--Users-sam-Desktop-locked"
    New-File "$P\C--Users-alex-Desktop-lockedx\h.jsonl" 'x'
    New-File "$lockedDir\open.jsonl" 'open chat'
    $lock = [IO.File]::Open("$lockedDir\open.jsonl", 'Open', 'ReadWrite', 'None')
    Sync-ClaudeChatFolders $P 3>$null
    $lock.Dispose()
    Check 'an open chat folder stays in place' ((Test-Path "$lockedDir\open.jsonl") -and -not (Test-Junction $lockedDir))

    $ign = (Get-FolderPlan | Where-Object { $_.Id -eq 'claude-home' }).Ignore
    Check 'claude-home ignores local junction names' ($ign -contains '(?i)/projects/C--Users-sam-*')
    Check 'junction ignores come before the include rules' ([array]::IndexOf($ign, '!/projects') -gt [array]::IndexOf($ign, '(?i)/projects/C--Users-sam-*'))
    Check 'paths map to this machine' ((Convert-ToLocalPath 'C:\Users\alex\Desktop\app\src') -eq 'C:\Users\sam\Desktop\app\src')
} finally {
    # Junctions first, so removing the tree never follows a link into real data.
    if (Test-Path $P) { Get-ChildItem -LiteralPath $P -Force | Where-Object { $_.LinkType } | ForEach-Object { [IO.Directory]::Delete($_.FullName) } }
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$fails failure(s)"
exit $fails
