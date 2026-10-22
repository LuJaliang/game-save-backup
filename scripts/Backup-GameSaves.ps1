<#
.SYNOPSIS
Backs up detected game-save folders to <Dest>\<Root>\<relative path>.

.DESCRIPTION
Copies (never moves or deletes) each candidate found by Get-GameSaves.ps1.
Writes logs\backup-<timestamp>.log, logs\manifest-<timestamp>.json, and appends
one line to logs\history.log. Run with -DryRun first to review the plan.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Dest,
    [string]$ProfileRoot = $env:USERPROFILE,
    [ValidateSet('Low', 'Medium', 'High')]
    [string]$MinConfidence = 'Medium',
    [ValidateRange(1, 8)]
    [int]$MaxDepth = 4,
    [ValidateSet('Local', 'LocalLow', 'Roaming', 'Documents', 'SavedGames', 'PublicDocuments', 'ProgramData', 'SteamUserdata', 'All')]
    [string[]]$Roots = @('Local', 'LocalLow', 'Roaming', 'Documents', 'SavedGames', 'PublicDocuments', 'ProgramData', 'SteamUserdata'),
    [string[]]$Include,
    [string[]]$Exclude,
    [string]$KnownPathsFile,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
    throw 'robocopy.exe not found; it ships with Windows and is required.'
}

$destFull = [System.IO.Path]::GetFullPath($Dest)
$destTrim = $destFull.TrimEnd('\')
$rootMap = Get-SaveRoots -ProfileRoot $ProfileRoot

foreach ($entry in $rootMap.GetEnumerator()) {
    $rootPath = [System.IO.Path]::GetFullPath($entry.Value).TrimEnd('\')
    if ($destTrim -ieq $rootPath -or $destTrim.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Destination must be outside scan root '$($entry.Key)': $rootPath"
    }
    if (($rootPath + '\').StartsWith($destTrim + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Destination must not contain scan root '$($entry.Key)': $rootPath"
    }
}

$scanScript = Join-Path $PSScriptRoot 'Get-GameSaves.ps1'
if (-not (Test-Path -LiteralPath $scanScript)) {
    throw "Scanner not found: $scanScript"
}

$scanArgs = @{
    ProfileRoot   = $ProfileRoot
    MinConfidence = $MinConfidence
    MaxDepth      = $MaxDepth
}
if ($PSBoundParameters.ContainsKey('Roots')) { $scanArgs['Roots'] = $Roots }
if ($PSBoundParameters.ContainsKey('KnownPathsFile')) { $scanArgs['KnownPathsFile'] = $KnownPathsFile }

$candidates = @(& $scanScript @scanArgs)

$selected = [System.Collections.Generic.List[object]]::new()
foreach ($c in $candidates) {
    $key = "$($c.Root)\$($c.RelativePath)"
    if ($Include -and -not (@($Include | Where-Object { $key -match $_ }).Count -gt 0)) { continue }
    if ($Exclude -and (@($Exclude | Where-Object { $key -match $_ }).Count -gt 0)) { continue }
    [void]$selected.Add($c)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$logsDir = Join-Path $destFull 'logs'
$logPath = Join-Path $logsDir "backup-$stamp.log"
$manifestPath = Join-Path $logsDir "manifest-$stamp.json"
$historyPath = Join-Path $logsDir 'history.log'

$log = [System.Collections.Generic.List[string]]::new()
[void]$log.Add('Game Save Backup')
[void]$log.Add("Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
[void]$log.Add("Profile: $ProfileRoot")
[void]$log.Add("Destination: $destFull")
[void]$log.Add("MinConfidence: $MinConfidence")
[void]$log.Add("Roots: $($Roots -join ', ')")
[void]$log.Add("Candidates: $($selected.Count)")
[void]$log.Add('')

$records = [System.Collections.Generic.List[object]]::new()

if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
}

$index = 0
foreach ($c in $selected) {
    $index++
    $relKey = Join-Path $c.Root $c.RelativePath
    $target = Join-Path $destFull $relKey
    $srcStats = Get-TreeStats $c.FullPath

    if ($DryRun) {
        [void]$records.Add([pscustomobject]@{
            Root = $c.Root; RelativePath = $c.RelativePath; Source = $c.FullPath; Target = $target
            Confidence = $c.Confidence; Score = $c.Score; Evidence = $c.Evidence
            Files = $srcStats.Files; Bytes = $srcStats.Bytes
            Status = 'planned'; ExitCode = $null; Note = ''
        })
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($target, "Copy $($c.FullPath)")) { continue }

    $exitCode = 0
    $note = ''
    try {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $rcArgs = @(
            $c.FullPath, $target,
            '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ',
            '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
        )
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
        Root = $c.Root; RelativePath = $c.RelativePath; Source = $c.FullPath; Target = $target
        Confidence = $c.Confidence; Score = $c.Score; Evidence = $c.Evidence
        Files = $dstStats.Files; Bytes = $dstStats.Bytes
        Status = $status; ExitCode = $exitCode; Note = $note
    })

    [void]$log.Add("[$index/$($selected.Count)] $status  $relKey")
    [void]$log.Add("  confidence: $($c.Confidence) (score $($c.Score))")
    [void]$log.Add("  source: $($c.FullPath)")
    [void]$log.Add("  target: $target")
    [void]$log.Add("  files: $($dstStats.Files), size: $(Format-Bytes $dstStats.Bytes)")
    [void]$log.Add("  evidence: $($c.Evidence)")
    if ($note) { [void]$log.Add("  note: $note") }
    [void]$log.Add('')
}

$ok = @($records | Where-Object { $_.Status -in @('ok', 'planned') }).Count
$bad = $records.Count - $ok
$totalBytes = ($records | Measure-Object -Property Bytes -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }

if (-not $DryRun) {
    [void]$log.Add("Summary: folders=$($records.Count) ok=$ok problems=$bad files=$((($records | Measure-Object -Property Files -Sum).Sum)) size=$(Format-Bytes $totalBytes)")
    [void]$log.Add("Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    [void]$log.Add("Log: $logPath")

    [System.IO.File]::WriteAllLines($logPath, $log, (New-Object System.Text.UTF8Encoding($false)))

    [pscustomobject]@{
        createdAt     = (Get-Date).ToString('o')
        profileRoot   = $ProfileRoot
        destination   = $destFull
        minConfidence = $MinConfidence
        roots         = @($Roots)
        itemCount     = $records.Count
        logFile       = [System.IO.Path]::GetFileName($logPath)
        items         = @($records)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $historyLine = '{0} | backup | items={1} ok={2} problems={3} size={4} | {5}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $records.Count, $ok, $bad, (Format-Bytes $totalBytes), [System.IO.Path]::GetFileName($logPath)
    [System.IO.File]::AppendAllText($historyPath, $historyLine + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

$records | Sort-Object Root, RelativePath |
    Format-Table Root, RelativePath, Confidence, Files, Status -AutoSize | Out-String | Write-Host

if ($DryRun) {
    Write-Host ("Dry run: {0} candidate(s), {1}. Nothing copied." -f $records.Count, (Format-Bytes $totalBytes))
}
else {
    Write-Host ("Backed up {0} folder(s), {1}. Status ok={2}, problems={3}." -f $records.Count, (Format-Bytes $totalBytes), $ok, $bad)
    Write-Host "Log: $logPath"
    Write-Host "Manifest: $manifestPath"
    if ($bad -gt 0) {
        Write-Host 'Close any running game and rerun for rows marked failed or verify-mismatch.'
    }
}