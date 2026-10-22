# The folder scan on made-up transcripts. Builds folders and transcripts in a temp folder only.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\SyncDevices.Common.ps1')

$fails = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { "PASS  $Name" } else { "FAIL  $Name"; $script:fails++ } }

$T = Join-Path $env:LOCALAPPDATA ('Temp\sd-scan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
# The scan skips AppData, LOCALAPPDATA and TEMP, where this temp tree lives; point them elsewhere so it counts.
$env:LOCALAPPDATA = 'C:\sd-test-nowhere\local'
$env:TEMP = 'C:\sd-test-nowhere\temp'
$env:USERPROFILE = Join-Path $T 'home'
try {
    $repo = Join-Path $T 'repo'; $outer = Join-Path $T 'outer'; $notes = Join-Path $T 'notes'
    New-Item -ItemType Directory -Force -Path "$repo\.git", "$repo\src", "$outer\.git", "$outer\inner\.git", $notes | Out-Null
    Set-Content "$notes\a.md" 'x'
    New-Item -ItemType File -Force -Path "$repo\src\big.bin" | Out-Null
    [IO.File]::WriteAllBytes("$repo\src\big.bin", (New-Object byte[] 2048))
    New-Item -ItemType Directory -Force -Path "$repo\node_modules" | Out-Null
    [IO.File]::WriteAllBytes("$repo\node_modules\skip.bin", (New-Object byte[] 4096))

    $proj = Join-Path $T 'projects\key'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    function Write-Transcript([string]$Name, $Records) {
        $lines = $Records | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 6 }
        Set-Content -LiteralPath (Join-Path $proj "$Name.jsonl") -Value $lines
    }
    Write-Transcript 'chat1' @(
        @{ type = 'user'; cwd = "$repo\src" },
        @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; input = @{ file_path = "$notes\a.md" } }) } },
        @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; input = @{ file_path = "$notes\deleted.md" } }) } },
        @{ type = 'user'; cwd = "$outer\inner" })
    Write-Transcript 'chat2' @(
        @{ type = 'user'; cwd = $repo },
        @{ type = 'user'; cwd = $outer },
        @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; input = @{ file_path = "$env:USERPROFILE\.claude\settings.json" } }) } },
        @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; input = @{ file_path = 'C:\loose-file.txt' } }) } })

    $found = @(Find-ClaudeFolders (Join-Path $T 'projects'))
    $byPath = @{}; foreach ($f in $found) { $byPath[$f.Path] = $f }
    Check 'git root found from a subfolder' ($byPath.ContainsKey($repo))
    Check 'chats counted per root (2 transcripts)' ($byPath[$repo].Chats -eq 2)
    Check 'plain folder found from a file and a deleted file' ($byPath.ContainsKey($notes))
    Check 'nested repo listed on its own' ($byPath.ContainsKey("$outer\inner") -and $byPath.ContainsKey($outer))
    Check '~\.claude is never a sync folder' (-not ($found | Where-Object { $_.Path -like "$env:USERPROFILE\.claude*" }))
    Check 'a drive root is never a sync folder' (-not ($found | Where-Object { $_.Path -match '^[A-Za-z]:\\?$' }))
    Check 'size skips node_modules' ($byPath[$repo].Bytes -eq 2048)
    Check 'small folders start ticked' ($byPath[$repo].Selected)

    $spec = @(ConvertTo-SpecFolders $found)
    Check 'inner repo folds into the outer one' (-not ($spec | Where-Object { $_.label -eq 'inner' }) -and ($spec | Where-Object { $_.label -eq 'outer' }))
    Check 'folder IDs are unique' (@($spec.id | Select-Object -Unique).Count -eq $spec.Count)
    Check 'IDs avoid the reserved names' (-not ($spec | Where-Object { $_.id -in 'claude-home', 'sync-devices-config' }))
    $vars = @{ HOME = 'C:\Users\alex'; DESKTOP = 'C:\Users\alex\Desktop'; APPDATA = 'C:\Users\alex\AppData\Roaming' }
    Check 'Desktop path becomes {DESKTOP}' ((ConvertTo-SpecPath 'C:\Users\alex\Desktop\app' $vars) -eq '{DESKTOP}\app')
    Check 'home path becomes {HOME}' ((ConvertTo-SpecPath 'C:\Users\alex\code' $vars) -eq '{HOME}\code')
    Check 'other paths stay absolute' ((ConvertTo-SpecPath 'D:\work\app' $vars) -eq 'D:\work\app')
    Check 'a similar prefix is not a match' ((ConvertTo-SpecPath 'C:\Users\alexander\x' $vars) -eq 'C:\Users\alexander\x')
} finally {
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$fails failure(s)"
exit $fails
