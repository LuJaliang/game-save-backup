# Shared helpers for game-save-backup scripts. Dot-source this file.

function Get-SteamUserdataPath {
    $candidates = @()
    try {
        $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        if ($steamPath) { $candidates += ($steamPath -replace '/', '\') }
    }
    catch { }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Steam') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Steam') }

    foreach ($p in $candidates) {
        $userdata = Join-Path $p 'userdata'
        if (Test-Path -LiteralPath $userdata -PathType Container) { return $userdata }
    }
    return $null
}

function Get-SaveRoots {
    param([string]$ProfileRoot = $env:USERPROFILE)

    $profileFull = [System.IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
    $realFull = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')

    if ($profileFull -ieq $realFull) {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $saved = Join-Path $ProfileRoot 'Saved Games'
        if (-not (Test-Path -LiteralPath $saved) -and (Test-Path -LiteralPath (Join-Path $ProfileRoot 'Documents\Saved Games'))) {
            $saved = Join-Path $ProfileRoot 'Documents\Saved Games'
        }
        $publicDocs = [Environment]::GetFolderPath('CommonDocuments')
        $programData = $env:ProgramData
        $steam = Get-SteamUserdataPath
    }
    else {
        # Custom profile: keep every root under it so tests are self-contained.
        $docs = Join-Path $ProfileRoot 'Documents'
        $saved = Join-Path $ProfileRoot 'Saved Games'
        $publicDocs = Join-Path $ProfileRoot 'PublicDocuments'
        $programData = Join-Path $ProfileRoot 'ProgramData'
        $steam = Join-Path $ProfileRoot 'Steam\userdata'
    }

    $roots = [ordered]@{}
    $roots['Local'] = Join-Path $ProfileRoot 'AppData\Local'
    $roots['LocalLow'] = Join-Path $ProfileRoot 'AppData\LocalLow'
    $roots['Roaming'] = Join-Path $ProfileRoot 'AppData\Roaming'
    if ($docs) { $roots['Documents'] = $docs }
    if ($saved) { $roots['SavedGames'] = $saved }
    if ($publicDocs) { $roots['PublicDocuments'] = $publicDocs }
    if ($programData) { $roots['ProgramData'] = $programData }
    if ($steam) { $roots['SteamUserdata'] = $steam }

    return $roots
}

function Get-TreeStats {
    param([string]$Path)
    $count = 0
    [long]$bytes = 0
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Files = 0; Bytes = 0 }
    }
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                $count++
                try { $bytes += ([System.IO.FileInfo]::new($f)).Length } catch { }
            }
            foreach ($child in [System.IO.Directory]::EnumerateDirectories($dir)) {
                $di = [System.IO.DirectoryInfo]::new($child)
                if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($child)
            }
        }
        catch { }
    }
    [pscustomobject]@{ Files = $count; Bytes = $bytes }
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}