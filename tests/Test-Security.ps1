# The trust boundaries: data from a paired machine (folder list, folder offers, synced chat files,
# transcripts) and pairing requests from strangers. Each check is an attack that must be refused.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\SyncDevices.Common.ps1')

$fails = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "PASS  $Name" } else { "FAIL  $Name"; $script:fails++ } }

$h = $env:USERPROFILE
'-- folder paths'
Check 'Startup folder refused' (-not (Test-SafeSyncPath "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"))
Check 'anything in AppData refused' (-not (Test-SafeSyncPath "$h\AppData\Local\Google\Chrome\User Data"))
Check '~\.ssh refused' (-not (Test-SafeSyncPath "$h\.ssh"))
Check '~\.aws refused' (-not (Test-SafeSyncPath "$h\.aws\credentials"))
Check 'the home folder itself refused' (-not (Test-SafeSyncPath $h))
Check 'Windows folder refused' (-not (Test-SafeSyncPath "$env:SystemRoot\System32"))
Check 'Program Files refused' (-not (Test-SafeSyncPath "$env:ProgramFiles\App"))
Check 'drive root refused' (-not (Test-SafeSyncPath 'C:\'))
Check 'network path refused' (-not (Test-SafeSyncPath '\\server\share\x'))
Check '".." refused' (-not (Test-SafeSyncPath "$h\Desktop\app\..\..\AppData"))
Check 'Claude app scratch folder allowed' (Test-SafeSyncPath "$env:APPDATA\Claude\scratch-workspaces")
Check 'a Desktop project allowed' (Test-SafeSyncPath "$h\Desktop\app")
Check 'a project on another drive allowed' (Test-SafeSyncPath 'D:\code\app')

'-- folder IDs'
Check 'traversal in a mirror ID refused' (-not (Test-SafeFolderId 'claude-scratch-x\..\..\AppData'))
Check 'slash in an ID refused' (-not (Test-SafeFolderId 'claude-scratch-x/../../system'))
Check 'query string in an ID refused' (-not (Test-SafeFolderId 'app?x=1'))
Check '".." in an ID refused' (-not (Test-SafeFolderId 'a..b'))
Check 'normal IDs allowed' ((Test-SafeFolderId 'my-data') -and (Test-SafeFolderId 'claude-scratch-desktop-4abc'))

'-- chat IDs'
Check 'command in a chat ID refused' (-not (Test-SessionId 'x; Start-Process calc'))
Check 'quote in a chat ID refused' (-not (Test-SessionId "x'"))
Check 'a session UUID allowed' (Test-SessionId '22d5120d-0829-4dc8-b070-edba4fafd1c4')

'-- pairing'
$id = 'ABCDEFG-HIJKLMN-OPQRSTU-VWXYZ23-4567ABC-DEFGHIJ-KLMNOPQ-RSTUVWX'
Check 'first 7 characters confirm' (Test-IdConfirmation $id 'ABCDEFG')
Check 'case and spaces do not matter' (Test-IdConfirmation $id '  abcdefg ')
Check 'wrong characters refused' (-not (Test-IdConfirmation $id 'ABCDEFX'))
Check 'empty input refused' (-not (Test-IdConfirmation $id ''))
Check 'a shorter prefix refused' (-not (Test-IdConfirmation $id 'ABC'))

'-- a hostile folder list'
function Get-Spec {
    [pscustomobject]@{
        canonical = [pscustomobject]@{ deviceId = 'X'; HOME = $h; DESKTOP = "$h\Desktop"; APPDATA = $env:APPDATA }
        devices = @(); ignore = @()
        folders = @(
            [pscustomobject]@{ id = 'app'; label = 'app'; path = '{DESKTOP}\app' },
            [pscustomobject]@{ id = 'startup'; label = 'x'; path = '{APPDATA}\Microsoft\Windows\Start Menu\Programs\Startup' },
            [pscustomobject]@{ id = 'keys'; label = 'x'; path = '{HOME}\.ssh' },
            [pscustomobject]@{ id = '../../system/shutdown'; label = 'x'; path = '{DESKTOP}\y' })
        mirrors = @([pscustomobject]@{ id = 'grab'; label = 'x'; path = '{HOME}\.ssh' })
    }
}
$ids = @(Get-FolderPlan 3>$null | ForEach-Object { $_.Id })
Check 'the normal folder stays' ($ids -contains 'app')
Check 'Startup entry dropped' ($ids -notcontains 'startup')
Check '.ssh entry dropped' ($ids -notcontains 'keys')
Check 'traversal ID dropped' (-not ($ids | Where-Object { $_ -like '*system*' }))
Check '.ssh mirror dropped' (-not ($ids | Where-Object { $_ -like 'grab*' }))

"`n$fails failure(s)"
exit $fails
