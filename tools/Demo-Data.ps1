# Sample data for README screenshots (SyncDevices.ps1 -Screenshot <file>). Dot-sourced after
# SyncDevices.Common.ps1, it replaces the functions that talk to Syncthing, so the real window renders
# without any real machine names, user names or paths.

$env:COMPUTERNAME = 'WORKSTATION'
$script:DemoMe = 'WRKSTN1-AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG'
$script:DemoLaptop = 'LAPTOP2-AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG'
$script:DemoFolders = @(
    @{ id = 'sync-devices-config'; label = 'Sync Devices settings'; path = 'C:\Users\alex\AppData\Local\SyncDevices\shared'; state = 'idle'; need = 0; done = 100 },
    @{ id = 'claude-home'; label = 'Claude chats, memory, skills'; path = 'C:\Users\alex\.claude'; state = 'idle'; need = 0; done = 100 },
    @{ id = 'saas-app'; label = 'saas-app'; path = 'C:\Users\alex\Desktop\saas-app'; state = 'idle'; need = 0; done = 64; send = 38MB },
    @{ id = 'agent-lab'; label = 'agent-lab'; path = 'D:\code\agent-lab'; state = 'syncing'; need = 12MB; done = 100 },
    @{ id = 'notes'; label = 'notes'; path = 'C:\Users\alex\notes'; state = 'idle'; need = 0; done = 100 },
    @{ id = 'claude-scratch-workstation'; label = 'Claude app scratch work (WORKSTATION)'; path = 'C:\Users\alex\AppData\Roaming\Claude\scratch-workspaces'; state = 'idle'; need = 0; done = 100 }
)

function Test-StRunning { $true }
function Get-MyId { $script:DemoMe }
function Get-PendingDevices { @() }
function Get-Peers { @([pscustomobject]@{ deviceID = $script:DemoLaptop; name = 'LAPTOP'; paused = $false }) }
function Get-Spec {
    [pscustomobject]@{
        canonical = [pscustomobject]@{ deviceId = $script:DemoMe; machine = 'WORKSTATION'; HOME = 'C:\Users\alex'; DESKTOP = 'C:\Users\alex\Desktop'; APPDATA = 'C:\Users\alex\AppData\Roaming' }
        devices = @($script:DemoLaptop); ignore = @()
        folders = @($script:DemoFolders | Where-Object { $_.id -in 'saas-app', 'agent-lab', 'notes' } | ForEach-Object { [pscustomobject]@{ id = $_.id; label = $_.label; path = $_.path } })
        mirrors = @([pscustomobject]@{ id = 'claude-scratch'; label = 'Claude app scratch work'; path = '{APPDATA}\Claude\scratch-workspaces' })
    }
}
function Invoke-St {
    # Same signature as the real Invoke-St; the sample data only needs the path.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param([string]$Path, [string]$Method = 'GET', $Body = $null)
    $folder = $null
    if ($Path -match 'folder=([^&]+)') { $id = [uri]::UnescapeDataString($Matches[1]); $folder = $script:DemoFolders | Where-Object { $_.id -eq $id } }
    switch -Wildcard ($Path) {
        'system/connections' {
            $c = New-Object psobject
            $c | Add-Member -NotePropertyName $script:DemoLaptop -NotePropertyValue ([pscustomobject]@{ connected = $true })
            return [pscustomobject]@{ connections = $c }
        }
        'config/folders' {
            return $script:DemoFolders | ForEach-Object {
                [pscustomobject]@{ id = $_.id; label = $_.label; path = $_.path; paused = $false
                    devices = @([pscustomobject]@{ deviceID = $script:DemoMe }, [pscustomobject]@{ deviceID = $script:DemoLaptop }) }
            }
        }
        'db/status*' { return [pscustomobject]@{ state = $folder.state; needBytes = $folder.need; pullErrors = 0 } }
        'db/completion*' {
            $left = $(if ($folder.ContainsKey('send')) { $folder.send } else { 0 })
            return [pscustomobject]@{ completion = $folder.done; needBytes = $left }
        }
    }
}
