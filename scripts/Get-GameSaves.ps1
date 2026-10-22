<#
.SYNOPSIS
Finds likely game-save folders under the user's AppData, Documents, Saved Games,
Public Documents, ProgramData, and optionally Steam userdata.

.DESCRIPTION
Read-only scan. Emits candidate objects; never copies, moves, or deletes anything.
Confidence is heuristic: High >= 6, Medium >= 4, Low >= 2.
#>
[CmdletBinding()]
param(
    [string]$ProfileRoot = $env:USERPROFILE,
    [ValidateSet('Low', 'Medium', 'High')]
    [string]$MinConfidence = 'Medium',
    [ValidateRange(1, 8)]
    [int]$MaxDepth = 4,
    [ValidateSet('Local', 'LocalLow', 'Roaming', 'Documents', 'SavedGames', 'PublicDocuments', 'ProgramData', 'SteamUserdata', 'All')]
    [string[]]$Roots = @('Local', 'LocalLow', 'Roaming', 'Documents', 'SavedGames', 'PublicDocuments', 'ProgramData', 'SteamUserdata'),
    [string]$KnownPathsFile,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'Common.ps1')

$StrongSaveNames = @(
    'save', 'saves', 'savegame', 'savegames', 'save data', 'savedata', 'save_data',
    'saved games', 'savedgames', 'save files', 'savefiles', 'gamesave', 'gamesaves',
    'game save', 'game saves', 'game_saves'
)
# Chinese folder names built from code points so this file stays ASCII.
$StrongSaveNames += ([string]([char]0x5B58) + [char]0x6863)
$StrongSaveNames += ([string]([char]0x5B58) + [char]0x6863 + [char]0x6570 + [char]0x636E)
$WeakSaveNames = @('profile', 'profiles', 'slot', 'slots', 'checkpoint', 'checkpoints')
$StrongExt = @('.sav', '.save', '.savx', '.srm', '.sl2', '.ess', '.fos', '.lsv', '.savegame', '.sg', '.psv', '.mcr', '.co3', '.zks', '.jkr')
$MediumExt = @('.dat', '.bin', '.json', '.xml', '.db', '.sqlite', '.sqlite3', '.state', '.bak', '.backup')

$CommonPrune = @(
    'cache', 'caches', 'gpucache', 'code cache', 'shadercache', 'crashpad', 'crashdumps',
    'temp', 'tmp', 'logs', 'node_modules', '.git', 'pip', 'npm-cache', 'nuget'
)
$AppDataPrune = @(
    'microsoft', 'google', 'mozilla', 'nvidia', 'nvidia corporation', 'amd', 'intel',
    'apple', 'apple computer', 'adobe', 'jetbrains', 'docker', 'slack', 'discord',
    'zoom', 'spotify', 'steam', 'epicgameslauncher', 'riot client', 'baidunetdisk',
    'baidu', 'tokens', 'programs', 'virtualstore', 'packages', 'package cache', 'windows defender',
    'dell', 'hp', 'lenovo', 'realtek'
)
$DocumentsPrune = @(
    'google', 'mozilla', 'adobe', 'apple', 'zoom', 'slack', 'discord', 'spotify',
    'onenote', 'visual studio 2022', 'visual studio code', 'github', 'powershell',
    'windowspowershell', 'my music', 'my pictures', 'my videos', 'fax',
    'scanned documents', 'my shapes', 'custom office templates'
)
$ProgramDataPrune = @(
    'microsoft', 'microsoft office', 'microsoft update', 'windows', 'package cache',
    'windows defender', 'nvidia', 'nvidia corporation', 'amd', 'intel', 'dell', 'hp',
    'lenovo', 'realtek', 'google', 'mozilla', 'adobe', 'apple', 'packagemanagement',
    'usoshared', 'softwaredistribution', 'regid.1991-06.com.microsoft'
)
$Rank = @{ Low = 1; Medium = 2; High = 3 }

if (-not $KnownPathsFile) {
    $KnownPathsFile = Join-Path $PSScriptRoot '..\references\known-game-paths.json'
}

$KnownExact = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$KnownPatterns = [System.Collections.Generic.List[regex]]::new()
$GameNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$PublisherNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

if (Test-Path -LiteralPath $KnownPathsFile) {
    $data = Get-Content -LiteralPath $KnownPathsFile -Raw | ConvertFrom-Json
    foreach ($k in @($data.knownSavePaths)) {
        if (-not $k.root -or -not $k.path) { continue }
        $key = "$($k.root)\$($k.path)".TrimEnd('\')
        if ($key.Contains('*')) {
            $parts = $key.Split('*')
            $regex = '^' + (($parts | ForEach-Object { [regex]::Escape($_) }) -join '[^\\]+') + '$'
            [void]$KnownPatterns.Add([regex]::new($regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
        }
        else {
            [void]$KnownExact.Add($key)
        }
    }
    foreach ($n in @($data.gameFolderNames)) { if ($n) { [void]$GameNames.Add($n) } }
    foreach ($n in @($data.publisherNames)) { if ($n) { [void]$PublisherNames.Add($n) } }
}

function Test-PruneName {
    param([string]$Name, [string]$RootName)
    $lower = $Name.ToLowerInvariant()
    if ($CommonPrune -contains $lower) { return $true }
    switch ($RootName) {
        'Local' { return ($AppDataPrune -contains $lower) }
        'LocalLow' { return ($AppDataPrune -contains $lower) }
        'Roaming' { return ($AppDataPrune -contains $lower) }
        'ProgramData' { return ($ProgramDataPrune -contains $lower) }
        'SteamUserdata' { return ($lower -eq '760' -or $lower -eq 'config' -or $lower -eq 'stats') }
        default { return ($DocumentsPrune -contains $lower) }
    }
}

function Get-RelativePath {
    param([string]$Base, [string]$Path)
    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($baseFull.Length)
    }
    return $full
}

function Get-DirFacts {
    param([string]$Path)
    $files = 0
    $strong = 0
    $medium = 0
    $unity = $false
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path)) {
            $files++
            if ($files -ge 500) { break }
            $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
            if ($StrongExt -contains $ext) { $strong++ }
            elseif ($MediumExt -contains $ext) { $medium++ }
            $leaf = [System.IO.Path]::GetFileName($f)
            if ($leaf -ieq 'Player.log' -or $leaf -ieq 'output_log.txt') { $unity = $true }
        }
    }
    catch { }
    [pscustomobject]@{ Files = $files; Strong = $strong; Medium = $medium; UnityLog = $unity }
}

$results = [System.Collections.Generic.List[object]]::new()

function Scan-Dir {
    param([string]$Path, [string]$RootName, [string]$RootBase, [int]$Depth)

    if ($Depth -ge $MaxDepth) { return }

    $children = @()
    try { $children = @([System.IO.Directory]::EnumerateDirectories($Path)) } catch { return }

    foreach ($child in $children) {
        $info = [System.IO.DirectoryInfo]::new($child)
        if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

        $name = $info.Name
        $lower = $name.ToLowerInvariant()
        if (Test-PruneName $name $RootName) { continue }

        $childDepth = $Depth + 1
        $rel = Get-RelativePath $RootBase $child
        $facts = Get-DirFacts $child

        $score = 0
        $evidence = [System.Collections.Generic.List[string]]::new()

        if ($StrongSaveNames -contains $lower) {
            $score += 5
            [void]$evidence.Add('save-folder-name')
        }
        elseif ($WeakSaveNames -contains $lower) {
            $score += 2
            [void]$evidence.Add('profile-or-slot-name')
        }

        if ($rel -match '(?i)(^|\\)Saved\\SaveGames$') {
            $score += 6
            [void]$evidence.Add('unreal-savegames')
        }

        $key = "$RootName\$rel"
        $knownHit = $KnownExact.Contains($key)
        if (-not $knownHit) {
            foreach ($pattern in $KnownPatterns) {
                if ($pattern.IsMatch($key)) { $knownHit = $true; break }
            }
        }
        if ($knownHit) {
            $score += 6
            [void]$evidence.Add('known-path')
        }

        if ($facts.Strong -ge 1) {
            $score += 2
            [void]$evidence.Add("save-files=$($facts.Strong)")
        }
        if ($facts.Strong -ge 3) { $score += 2 }
        if ($facts.Strong -ge 5) { $score += 1 }
        if ($facts.Medium -ge 3) {
            $score += 1
            [void]$evidence.Add("data-files=$($facts.Medium)")
        }
        if ($facts.UnityLog) {
            $score += 1
            [void]$evidence.Add('unity-log')
            if (($facts.Strong + $facts.Medium) -ge 1) { $score += 2 }
        }
        if ($childDepth -ge 2 -and $facts.Strong -ge 1) {
            $score += 2
            [void]$evidence.Add('nested-save-files')
        }
        if ($childDepth -ge 2 -and $facts.Medium -ge 1) { $score += 1 }

        if ($GameNames.Contains($name)) {
            $score += 2
            [void]$evidence.Add('game-name')
        }
        if ($PublisherNames.Contains($name)) {
            $score += 1
            [void]$evidence.Add('publisher-name')
        }

        $confidence = $null
        if ($score -ge 6) { $confidence = 'High' }
        elseif ($score -ge 4) { $confidence = 'Medium' }
        elseif ($score -ge 2) { $confidence = 'Low' }

        $accepted = $confidence -and $Rank[$confidence] -ge $Rank[$MinConfidence]
        if ($accepted) {
            $stats = Get-TreeStats $child
            [void]$results.Add([pscustomobject]@{
                Root         = $RootName
                RelativePath = $rel
                FullPath     = $child
                Confidence   = $confidence
                Score        = $score
                Files        = $stats.Files
                SizeBytes    = $stats.Bytes
                Evidence     = ($evidence -join '; ')
            })
        }
        # A nested folder can be a stronger match than its parent; only High/Medium stop the walk.
        if (-not $accepted -or $Rank[$confidence] -lt 2) {
            Scan-Dir -Path $child -RootName $RootName -RootBase $RootBase -Depth $childDepth
        }
    }
}

$rootMap = Get-SaveRoots -ProfileRoot $ProfileRoot
$scanRoots = @($Roots)
if ($scanRoots -contains 'All') { $scanRoots = @($rootMap.Keys) }

foreach ($rootName in $scanRoots) {
    if (-not $rootMap.Contains($rootName)) { continue }
    $rootPath = $rootMap[$rootName]
    if (-not $rootPath -or -not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
    $rootFull = [System.IO.Path]::GetFullPath($rootPath)
    Scan-Dir -Path $rootFull -RootName $rootName -RootBase $rootFull -Depth 0
}

$final = [System.Collections.Generic.List[object]]::new()
foreach ($r in $results) {
    $prefix = $r.FullPath.TrimEnd('\') + '\'
    $hasChild = $false
    foreach ($o in $results) {
        if ([object]::ReferenceEquals($o, $r)) { continue }
        if ($o.FullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $hasChild = $true; break }
    }
    if (-not $hasChild) { [void]$final.Add($r) }
}

$sorted = @($final | Sort-Object Root, RelativePath)
if ($Json) {
    ConvertTo-Json -InputObject @($sorted) -Depth 5
}
else {
    $sorted
}