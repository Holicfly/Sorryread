param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDirectory
$publishDir = Join-Path $projectRoot 'publish\Sorryread'
$appName = -join @(
    [char]0x7D20,
    [char]0x82E5,
    [char]0x9605,
    [char]0x8BFB)
$appExeName = $appName + '.exe'

$publishedAppPath = [IO.Path]::GetFullPath((Join-Path $publishDir $appExeName))
$runningPublishedReader = @(Get-Process -Name $appName -ErrorAction SilentlyContinue | Where-Object {
    try {
        $_.Path -and [IO.Path]::GetFullPath($_.Path).Equals(
            $publishedAppPath,
            [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        $false
    }
})
if ($runningPublishedReader.Count -gt 0) {
    throw 'The published application is running. Close it before rebuilding.'
}

if (Test-Path -LiteralPath $publishDir) {
    $expectedPublishParent = [IO.Path]::GetFullPath((Join-Path $projectRoot 'publish'))
    $resolvedPublishDir = [IO.Path]::GetFullPath($publishDir)
    if (-not [IO.Path]::GetDirectoryName($resolvedPublishDir).Equals(
            $expectedPublishParent,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected publish directory: $resolvedPublishDir"
    }
    Remove-Item -LiteralPath $resolvedPublishDir -Recurse -Force
}

$dotnetCandidates = @(
    (Get-Command dotnet -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Join-Path $env:LOCALAPPDATA 'ReadAISdk\dotnet8\dotnet.exe')
)
$dotnetExe = $null
foreach ($candidate in $dotnetCandidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
        $sdkList = & $candidate --list-sdks 2>$null
        if ($sdkList -match '^8\.') {
            $dotnetExe = $candidate
            break
        }
    }
}
if ($null -eq $dotnetExe) {
    throw 'The .NET 8 SDK was not found. Install the .NET 8 SDK and run again.'
}

$projectFile = Join-Path $projectRoot 'ReadAI.csproj'
& $dotnetExe restore $projectFile --runtime win-x64
if ($LASTEXITCODE -ne 0) {
    throw 'NuGet restore failed.'
}

$fileVersion = $Version + '.0'
$publishArguments = @(
    $projectFile,
    '--configuration', 'Release',
    '--runtime', 'win-x64',
    '--self-contained', 'true',
    '--output', $publishDir,
    '--no-restore',
    '-p:PublishSingleFile=false',
    '-p:DebugSymbols=false',
    '-p:DebugType=None',
    "-p:Version=$Version",
    "-p:AssemblyVersion=$fileVersion",
    "-p:FileVersion=$fileVersion",
    "-p:InformationalVersion=$Version"
)
& $dotnetExe publish @publishArguments
if ($LASTEXITCODE -ne 0) {
    throw 'Application publish failed.'
}

Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\icons\app.ico') -Destination (Join-Path $publishDir 'app.ico') -Force

Get-ChildItem -LiteralPath $publishDir -Recurse -File -Filter '*.xml' | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
}

$requiredFiles = @(
    $appExeName,
    ($appName + '.dll'),
    ($appName + '.deps.json'),
    ($appName + '.runtimeconfig.json'),
    'app.ico'
)
$publishedFiles = @(Get-ChildItem -LiteralPath $publishDir -Recurse -File)
$topLevelFiles = @(Get-ChildItem -LiteralPath $publishDir -File | Select-Object -ExpandProperty Name)
$missingFiles = @($requiredFiles | Where-Object { $_ -notin $topLevelFiles })
$dependencyFiles = @($publishedFiles | Where-Object { $_.Extension -eq '.dll' })
$forbiddenPublishItems = @($publishedFiles | Where-Object {
    $_.Name -match '^(UserData|WebView2|txt)$' -or
    $_.Extension -in @('.db', '.db-wal', '.db-shm', '.txt', '.log', '.pdb')
})
if ($missingFiles.Count -gt 0 -or $dependencyFiles.Count -eq 0 -or $forbiddenPublishItems.Count -gt 0) {
    throw ("Publish manifest validation failed. Missing=[{0}] DependencyCount={1} Forbidden=[{2}]" -f
        ($missingFiles -join ', '),
        $dependencyFiles.Count,
        (($forbiddenPublishItems | Select-Object -ExpandProperty FullName) -join ', '))
}

Write-Host "Publish completed: $publishDir"
Write-Host "Version: $Version"
Write-Host "Mode: self-contained multi-file"
Write-Host "Files: $($publishedFiles.Count)"
