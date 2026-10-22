<#
.SYNOPSIS
Restores a game-save backup created by Backup-GameSaves.ps1.

.DESCRIPTION
Uses the newest manifest under <Backup>\logs by default and copies each backed-up
folder back to its original root. Before overwriting an existing folder, the current
contents are snapshotted to <Backup>\_rollback\<timestamp>. Writes
logs\restore-<timestamp>.log and logs\restore-<timestamp>.json.
Run with -DryRun first.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Backup,
    [string]$Manifest,
    [string[]]$Item,
    [string]$ProfileRoot = $env:USERPROFILE,
    [switch]$IncludeIncomplete,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
    throw 'robocopy.exe not found; it ships with Windows and is required.'
}

$backupFull = [System.IO.Path]::GetFullPath($Backup)
if (-not (Test-Path -LiteralPath $backupFull -PathType Container)) {
    throw "Backup directory not found: $backupFull"
}

if (-not $Manifest) {
    $found = @()
    $logsDir = Join-Path $backupFull 'logs'
    if (Test-Path -LiteralPath $logsDir) {
        $found += @(Get-ChildItem -LiteralPath $logsDir -Filter 'manifest-*.json' -File -ErrorAction SilentlyContinue)
    }
    $found += @(Get-ChildItem -LiteralPath $backupFull -Filter 'manifest-*.json' -File -ErrorAction SilentlyContinue)
    $latest = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $Manifest = $latest.FullName }
}
if (-not $Manifest -or -not (Test-Path -LiteralPath $Manifest)) {
    throw "No manifest found. Run Backup-GameSaves.ps1 first, or pass -Manifest <path>."
}

$data = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$manifestItems = @($data.items)

$selectedEntries = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $manifestItems) {
    if (-not $entry.Root -or -not $entry.RelativePath) { continue }
    $relKey = Join-Path $entry.Root $entry.RelativePath
    if ($Item -and -not (@($Item | Where-Object { $relKey -match $_ }).Count -gt 0)) { continue }
    [void]$selectedEntries.Add($entry)
}

$rootMap = Get-SaveRoots -ProfileRoot $ProfileRoot
$rootLookup = @{}
foreach ($k in $rootMap.Keys) { $rootLookup[$k] = $rootMap[$k] }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$logsDir = Join-Path $backupFull 'logs'
$logPath = Join-Path $logsDir "restore-$stamp.log"
$manifestPath = Join-Path $logsDir "restore-$stamp.json"
$historyPath = Join-Path $logsDir 'history.log'
$rollbackRoot = Join-Path $backupFull "_rollback\$stamp"

$log = [System.Collections.Generic.List[string]]::new()
[void]$log.Add('Game Save Restore')
[void]$log.Add("Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
[void]$log.Add("Backup: $backupFull")
[void]$log.Add("Manifest: $Manifest")
[void]$log.Add("Profile: $ProfileRoot")
[void]$log.Add("Items: $($selectedEntries.Count)")
[void]$log.Add("Rollback: $rollbackRoot")
[void]$log.Add('')

if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
}

$records = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($entry in $selectedEntries) {
    $relKey = Join-Path $entry.Root $entry.RelativePath
    $index++
    $src = Join-Path $backupFull $relKey
    $targetRoot = $rootLookup[$entry.Root]
    $target = $null
    if ($targetRoot) { $target = Join-Path $targetRoot $entry.RelativePath }

    if ($entry.Status -and @('ok', 'planned') -notcontains $entry.Status -and -not $IncludeIncomplete) {
        $rec = [pscustomobject]@{
            Root = $entry.Root; RelativePath = $entry.RelativePath; Source = $src; Target = $target
            Status = 'backup-incomplete'; Files = 0; Bytes = 0; Rollback = ''; ExitCode = $null
            Note = "Backup status is '$($entry.Status)'; use -IncludeIncomplete to restore anyway"
        }
        [void]$records.Add($rec)
        [void]$log.Add("[$index] backup-incomplete  $relKey")
        [void]$log.Add("  note: backup status is '$($entry.Status)'; skipped")
        [void]$log.Add('')
        continue
    }

    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        $rec = [pscustomobject]@{
            Root = $entry.Root; RelativePath = $entry.RelativePath; Source = $src; Target = $target
            Status = 'missing-backup'; Files = 0; Bytes = 0; Rollback = ''; ExitCode = $null
            Note = 'Backed-up folder is missing'
        }
        [void]$records.Add($rec)
        [void]$log.Add("[$index] missing-backup  $relKey")
        [void]$log.Add('  source: missing')
        [void]$log.Add('')
        continue
    }

    if (-not $targetRoot -or -not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        $rec = [pscustomobject]@{
            Root = $entry.Root; RelativePath = $entry.RelativePath; Source = $src; Target = $target
            Status = 'root-unavailable'; Files = 0; Bytes = 0; Rollback = ''; ExitCode = $null
            Note = "Root '$($entry.Root)' is not available on this machine"
        }
        [void]$records.Add($rec)
        [void]$log.Add("[$index] root-unavailable  $relKey")
        [void]$log.Add("  note: root '$($entry.Root)' is not available")
        [void]$log.Add('')
        continue
    }

    $srcStats = Get-TreeStats $src

    if ($DryRun) {
        [void]$records.Add([pscustomobject]@{
            Root = $entry.Root; RelativePath = $entry.RelativePath; Source = $src; Target = $target
            Status = 'planned'; Files = $srcStats.Files; Bytes = $srcStats.Bytes; Rollback = ''
            ExitCode = $null; Note = ''
        })
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($target, "Restore $relKey")) { continue }

    $rollbackPath = ''
    $note = ''
    if (Test-Path -LiteralPath $target) {
        $rollbackPath = Join-Path (Join-Path $rollbackRoot $entry.Root) $entry.RelativePath
        try {
            New-Item -ItemType Directory -Force -Path $rollbackPath | Out-Null
            $rcArgs = @($target, $rollbackPath, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            & robocopy.exe @rcArgs | Out-Null
            $rollbackCode = $LASTEXITCODE
        }
        catch {
            $rollbackCode = 16
        }
        if ($rollbackCode -ge 8) {
            [void]$records.Add([pscustomobject]@{
                Root = $entry.Root; RelativePath = $entry.RelativePath; Source = $src; Target = $target
                Status = 'rollback-failed'; Files = 0; Bytes = 0; Rollback = $rollbackPath
                ExitCode = $rollbackCode; Note = 'Could not snapshot the current folder; restore skipped'
            })
            [void]$log.Add("[$index] rollback-failed  $relKey")
            [void]$log.Add("  target: $target")
            [void]$log.Add("  rollback: $rollbackPath")
            [void]$log.Add('  note: current folder could not be snapshotted; restore skipped')
            [void]$log.Add('')
            continue
        }
    }

    $exitCode = 0
    try {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $rcArgs = @($src, $target, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        & robocopy.exe @rcArgs | Out-Null
        $exitCode = $LASTEXITCODE
    }
    catch {
        $exitCode = 16
        $note = $_.Exception.Message
    }

    $dstStats = Get-TreeStats $target
    $status = 'ok'
    if ($exitCode -ge 8) { $status = 'failed' }
    elseif ($srcStats.Files -ne $dstStats.Files) { $status = 'verify-mismatch' }
    if ($exitCode -ge 8 -and -not $note) { $note = "robocopy exit $exitCode (locked file or access denied)" }

    [void]$records.Add([pscustomobject]@{
        Root = $entry.Root; RelativePath = $entry.RelativePath; Source = $src; Target = $target
        Status = $status; Files = $dstStats.Files; Bytes = $dstStats.Bytes
        Rollback = $rollbackPath; ExitCode = $exitCode; Note = $note
    })

    [void]$log.Add("[$index] $status  $relKey")
    [void]$log.Add("  target: $target")
    [void]$log.Add("  rollback: $(if ($rollbackPath) { $rollbackPath } else { 'none' })")
    [void]$log.Add("  files: $($dstStats.Files), size: $(Format-Bytes $dstStats.Bytes)")
    if ($note) { [void]$log.Add("  note: $note") }
    [void]$log.Add('')
}

$ok = @($records | Where-Object { $_.Status -in @('ok', 'planned') }).Count
$bad = $records.Count - $ok
$totalBytes = ($records | Measure-Object -Property Bytes -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }

if (-not $DryRun) {
    [void]$log.Add("Summary: folders=$($records.Count) ok=$ok problems=$bad size=$(Format-Bytes $totalBytes)")
    [void]$log.Add("Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    [void]$log.Add("Log: $logPath")

    [System.IO.File]::WriteAllLines($logPath, $log, (New-Object System.Text.UTF8Encoding($false)))

    [pscustomobject]@{
        createdAt     = (Get-Date).ToString('o')
        backup        = $backupFull
        manifest      = $Manifest
        profileRoot   = $ProfileRoot
        rollbackRoot  = $rollbackRoot
        itemCount     = $records.Count
        logFile       = [System.IO.Path]::GetFileName($logPath)
        items         = @($records)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $historyLine = '{0} | restore | items={1} ok={2} problems={3} size={4} | {5}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $records.Count, $ok, $bad, (Format-Bytes $totalBytes), [System.IO.Path]::GetFileName($logPath)
    [System.IO.File]::AppendAllText($historyPath, $historyLine + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

$records | Sort-Object Root, RelativePath |
    Format-Table Root, RelativePath, Files, Status -AutoSize | Out-String | Write-Host

if ($DryRun) {
    Write-Host ("Dry run: {0} item(s), {1}. Nothing restored." -f $records.Count, (Format-Bytes $totalBytes))
}
else {
    Write-Host ("Restored {0} folder(s), {1}. Status ok={2}, problems={3}." -f $records.Count, (Format-Bytes $totalBytes), $ok, $bad)
    Write-Host "Log: $logPath"
    Write-Host "Rollback: $rollbackRoot"
    if ($bad -gt 0) {
        Write-Host 'Close any running game and rerun for rows marked failed or verify-mismatch.'
    }
}