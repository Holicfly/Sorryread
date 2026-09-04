#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Commit', 'Rollback')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [Parameter(Mandatory = $true)][string]$StateFile,
    [Parameter(Mandatory = $true)][string]$ResultFile
)

# This helper is embedded in Setup and never called by the application.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding($true)
$sourceRoot = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
$installRoot = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$targetRoot = [IO.Path]::GetFullPath((Join-Path $installRoot 'Data'))
$state = $null
$exitCode = 0
$message = ''
$aclTimeoutMilliseconds = 60000

function Assert-NoReparseAncestors([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Links/junctions are not migrated or deleted automatically: $cursor"
            }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}

function Get-FileDigest([string]$Path) {
    # Share.Read rejects concurrent writers, including an unfinished WebView2 process.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hash = $null
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '')
    } finally {
        if ($null -ne $hash) { $hash.Dispose() }
        $stream.Dispose()
    }
}

function Get-Manifest([string]$Root, [string]$ExcludedName = '') {
    Assert-NoReparseAncestors $Root
    if (-not [IO.Directory]::Exists($Root)) { throw "Data directory is missing: $Root" }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $entries = New-Object 'Collections.Generic.List[object]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $directory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Links/junctions are not migrated or deleted automatically: $($item.FullName)"
            }
            $relative = $item.FullName.Substring($Root.Length + 1)
            if ($relative -eq $ExcludedName) { continue }
            if ($item.PSIsContainer) {
                $entries.Add([pscustomobject]@{ Path=$relative; Kind='Directory'; Length=0; Hash='';
                    Written=$item.LastWriteTimeUtc.Ticks; Attributes=[int]$item.Attributes })
                $pending.Push($item.FullName)
            } else {
                $entries.Add([pscustomobject]@{ Path=$relative; Kind='File'; Length=$item.Length;
                    Hash=(Get-FileDigest $item.FullName); Written=$item.LastWriteTimeUtc.Ticks;
                    Attributes=[int]$item.Attributes })
            }
        }
    }
    return $entries.ToArray() | Sort-Object Path
}

function Assert-Matches([string]$Root, [object[]]$Expected, [string]$ExcludedName = '') {
    $actual = @(Get-Manifest $Root $ExcludedName)
    if ($actual.Count -ne $Expected.Count) { throw "Data contents changed (item count): $Root" }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        $a = $actual[$index]; $b = $Expected[$index]
        if ($a.Path -cne $b.Path -or $a.Kind -ne $b.Kind -or
            $a.Length -ne $b.Length -or $a.Hash -ne $b.Hash) {
            throw "Data contents changed or copy verification failed: $Root\$($b.Path)"
        }
    }
}

function Grant-DataWriteAccess([string]$Root) {
    # Check the entire tree before recursively granting rights; never follow a junction.
    Assert-NoReparseAncestors $Root
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $directory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Cannot grant data permissions through a link: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\icacls.exe'
    # SID avoids dependence on the localized name of the built-in Users group.
    $start.Arguments = '"' + $Root + '" /inheritance:e /grant "*S-1-5-32-545:(OI)(CI)M" /T /Q'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Unable to start icacls.' }
    try {
        if (-not $process.WaitForExit($aclTimeoutMilliseconds)) {
            $process.Kill()
            throw "Timed out granting Data write access: $Root"
        }
        if ($process.ExitCode -ne 0) {
            throw "Could not grant Users inherited Modify access (icacls $($process.ExitCode)): $Root"
        }
    } finally { $process.Dispose() }
}

function Save-State {
    # State is confined to Setup's private temporary directory, not the writable Data tree.
    [IO.File]::WriteAllText($StateFile, ($script:state | ConvertTo-Json -Depth 6), $utf8)
}

function Write-Marker([string]$Reason) {
    [IO.File]::WriteAllLines($script:state.Marker,
        @('Sorryread data migration', $Reason, "Source: $sourceRoot", "Data: $targetRoot",
            "Staging: $($script:state.Stage)"), $utf8)
}

function Assert-OwnedCopy([string]$Root) {
    Assert-NoReparseAncestors $Root
    $ownerPath = Join-Path $Root $script:state.OwnerFile
    Assert-NoReparseAncestors $ownerPath
    if (-not [IO.File]::Exists($ownerPath) -or [IO.File]::ReadAllText($ownerPath) -ne $script:state.Id) {
        throw "This directory is not owned by this migration; it will not be removed: $Root"
    }
}

function Resolve-ManifestPath([string]$Root, [string]$RelativePath) {
    $path = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not $path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected file outside the data directory: $path"
    }
    Assert-NoReparseAncestors $path
    return $path
}

function Remove-VerifiedFile([string]$Root, [object]$Entry) {
    $path = Resolve-ManifestPath $Root $Entry.Path
    # Keep a read handle without Share.Write through hashing AND deletion. A late
    # writer cannot change a verified file between those two operations.
    $sharing = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
    $hash = $null
    $originalAttributes = $null
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        $digest = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '')
        if ($stream.Length -ne $Entry.Length -or $digest -ne $Entry.Hash) {
            throw "File changed after copying; the changed original is retained: $path"
        }
        $originalAttributes = [IO.File]::GetAttributes($path)
        if (($originalAttributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
            [IO.File]::SetAttributes($path, ($originalAttributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        }
        [IO.File]::Delete($path)
    } catch {
        if ($null -ne $originalAttributes -and [IO.File]::Exists($path)) {
            [IO.File]::SetAttributes($path, $originalAttributes)
        }
        throw
    } finally {
        if ($null -ne $hash) { $hash.Dispose() }
        $stream.Dispose()
    }
}

function Remove-VerifiedTree([string]$Root, [object[]]$Manifest, [string]$OwnerFile = '') {
    Assert-Matches $Root $Manifest
    foreach ($entry in ($Manifest | Where-Object { $_.Kind -eq 'File' -and $_.Path -ne $OwnerFile })) {
        Remove-VerifiedFile $Root $entry
    }
    foreach ($entry in ($Manifest | Where-Object Kind -eq 'Directory' | Sort-Object { $_.Path.Length } -Descending)) {
        $path = Resolve-ManifestPath $Root $entry.Path
        # Never recursively delete the source: newly created/unrecognized files
        # keep their containing directory alive and produce a visible warning.
        [IO.Directory]::Delete($path, $false)
    }
    foreach ($entry in ($Manifest | Where-Object { $_.Kind -eq 'File' -and $_.Path -eq $OwnerFile })) {
        Remove-VerifiedFile $Root $entry
    }
    Assert-NoReparseAncestors $Root
    [IO.Directory]::Delete($Root, $false)
}

function Remove-OwnedCopy([string]$Root, [bool]$RequireComplete) {
    if (-not [IO.Directory]::Exists($Root)) { return }
    if ($Root -ne $targetRoot -and $Root -ne $script:state.Stage) {
        throw "Unexpected cleanup target: $Root"
    }
    Assert-OwnedCopy $Root
    # Enumerate even a partial staging tree before deletion to reject links.
    if ($RequireComplete) { Assert-Matches $Root @($script:state.Manifest) $script:state.OwnerFile }
    Remove-VerifiedTree $Root @(Get-Manifest $Root) $script:state.OwnerFile
}

try {
    # Reject nested roots and arbitrary deletion targets before touching either directory.
    if ([IO.Path]::GetFileName($sourceRoot) -ne 'Sorryread' -or
        $sourceRoot -eq $targetRoot -or
        $targetRoot.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $sourceRoot.StartsWith($targetRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $sourceRoot.StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The old Sorryread directory and the installation directory must be separate, non-nested directories.'
    }
    Assert-NoReparseAncestors $targetRoot

    if (Test-Path -LiteralPath $StateFile) {
        $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.Source -ne $sourceRoot -or $state.Target -ne $targetRoot -or
            $state.Id -notmatch '^[0-9a-f]{32}$' -or
            $state.Stage -ne (Join-Path $installRoot ('.Data-migration-' + $state.Id)) -or
            $state.Marker -ne (Join-Path $installRoot ('Data.migration-' + $state.Id + '.txt')) -or
            $state.OwnerFile -ne ('.migration-owner-' + $state.Id)) {
            throw 'The migration state does not match these exact source and destination directories.'
        }
    }

    if ($Mode -eq 'Prepare') {
        if ($null -ne $state) { throw 'A previous attempt is pending. Close Setup and retry after its rollback completes.' }
        [IO.Directory]::CreateDirectory($targetRoot) | Out-Null
        Grant-DataWriteAccess $targetRoot
        if (@(Get-ChildItem -LiteralPath $targetRoot -Force).Count -gt 0) {
            $message = "Data already contains files. Migration skipped; nothing was overwritten. Old directory retained: $sourceRoot"
        } elseif (-not [IO.Directory]::Exists($sourceRoot) -or
            @(Get-ChildItem -LiteralPath $sourceRoot -Force).Count -eq 0) {
            $message = "No old data found. Writable Data directory is ready: $targetRoot"
        } else {
            Assert-NoReparseAncestors $sourceRoot
            $id = [Guid]::NewGuid().ToString('N')
            $state = [pscustomobject]@{
                Id=$id; Source=$sourceRoot; Target=$targetRoot
                Stage=(Join-Path $installRoot ('.Data-migration-' + $id))
                Marker=(Join-Path $installRoot ('Data.migration-' + $id + '.txt'))
                OwnerFile=('.migration-owner-' + $id)
                Manifest=@(Get-Manifest $sourceRoot); Published=$false; Committed=$false
            }
            Save-State
            Write-Marker 'PENDING: the original directory is retained until installation succeeds.'
            [IO.Directory]::CreateDirectory($state.Stage) | Out-Null
            [IO.File]::WriteAllText((Join-Path $state.Stage $state.OwnerFile), $state.Id, $utf8)
            foreach ($entry in $state.Manifest) {
                $destination = Join-Path $state.Stage $entry.Path
                if ($entry.Kind -eq 'Directory') {
                    [IO.Directory]::CreateDirectory($destination) | Out-Null
                } else {
                    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
                    [IO.File]::Copy((Join-Path $sourceRoot $entry.Path), $destination, $false)
                }
            }
            # Restore directory metadata only after all its children have been copied.
            foreach ($entry in ($state.Manifest | Where-Object Kind -eq 'Directory' | Sort-Object { $_.Path.Length } -Descending)) {
                $directory = Join-Path $state.Stage $entry.Path
                [IO.Directory]::SetLastWriteTimeUtc($directory, [DateTime]::new([long]$entry.Written, [DateTimeKind]::Utc))
                [IO.File]::SetAttributes($directory, [IO.FileAttributes]$entry.Attributes)
            }
            Assert-Matches $state.Stage @($state.Manifest) $state.OwnerFile
            Assert-Matches $sourceRoot @($state.Manifest)
            # Delete only the still-empty placeholder. Directory.Move never overwrites another Data.
            [IO.Directory]::Delete($targetRoot, $false)
            $state.Published = $true
            Save-State
            [IO.Directory]::Move($state.Stage, $targetRoot)
            Grant-DataWriteAccess $targetRoot
            $message = 'The complete data copy is ready. The original is retained until installation finishes.'
        }
    } elseif ($null -eq $state) {
        $message = 'No data migration was required.'
    } elseif ($Mode -eq 'Commit') {
        Assert-OwnedCopy $targetRoot
        Assert-Matches $targetRoot @($state.Manifest) $state.OwnerFile
        # Recheck the original immediately before deletion; changing/locked files are retained.
        try {
            if ([IO.Directory]::Exists($sourceRoot)) {
                Remove-VerifiedTree $sourceRoot @($state.Manifest)
            }
            $state.Committed = $true
            Save-State
            [IO.File]::Delete((Join-Path $targetRoot $state.OwnerFile))
            [IO.File]::Delete($state.Marker)
            $message = "Migration completed. Data is at $targetRoot; the old directory has been removed."
        } catch {
            # The destination is complete even if removing the old tree stopped part-way.
            $state.Committed = $true
            Save-State
            Write-Marker ("COPY RETAINED: close any reader/WebView2 processes before handling the old directory. " + $_.Exception.Message)
            $exitCode = 2
            $message = "Data is complete at $targetRoot. The old directory or migration marker could not be fully removed and is retained. See $($state.Marker). Reason: $($_.Exception.Message)"
        }
    } elseif ($Mode -eq 'Rollback' -and -not $state.Committed) {
        # Never remove the new copy unless the original is still complete.
        Assert-Matches $sourceRoot @($state.Manifest)
        if ($state.Published -and [IO.Directory]::Exists($targetRoot)) {
            Remove-OwnedCopy $targetRoot $true
        }
        Remove-OwnedCopy $state.Stage $false
        [IO.File]::Delete($state.Marker)
        [IO.File]::Delete($StateFile)
        $message = "Installation canceled. The original data is unchanged: $sourceRoot"
    }
} catch {
    $exitCode = 1
    $message = "Data migration failed. Do not delete either data directory. Close the reader and any remaining WebView2 processes, then retry. Reason: $($_.Exception.Message)"
}
[IO.File]::WriteAllText($ResultFile, $message, $utf8)
exit $exitCode
