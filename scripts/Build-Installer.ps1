param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.1.7'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDirectory
$installerDir = Join-Path $projectRoot 'installer'
$cacheDir = Join-Path $installerDir 'cache'
$outputDir = Join-Path $installerDir 'output'
$installerScript = Join-Path $installerDir 'Sorryread.iss'
$bootstrapperPath = Join-Path $cacheDir 'MicrosoftEdgeWebView2Setup.exe'
$bootstrapperTemp = Join-Path $cacheDir 'MicrosoftEdgeWebView2Setup.download.exe'
$bootstrapperUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
$downloadAttempts = 3
$downloadTimeoutSeconds = 60
$downloadRetryDelaySeconds = 2
$expectedInstaller = Join-Path $outputDir "Sorryread-Setup-$Version-x64.exe"

function Find-InnoCompiler {
    $candidates = @(
        (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'
    }

    $registryRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in Get-ItemProperty $registryRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Inno Setup 7*' }) {
        if ($entry.InstallLocation) {
            $candidates += Join-Path $entry.InstallLocation 'ISCC.exe'
        }
    }

    foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw 'Inno Setup 7 compiler was not found.'
}

function Assert-MicrosoftSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "WebView2 bootstrapper signature is not valid: $($signature.Status)"
    }
    if ($null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
        throw "Unexpected WebView2 bootstrapper signer: $($signature.SignerCertificate.Subject)"
    }
}

if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
    throw "Installer script not found: $installerScript"
}

& (Join-Path $scriptDirectory 'Build-ReadAI.ps1') -Version $Version

$publishDir = Join-Path $projectRoot 'publish\Sorryread'
# Only the bundled usage guide is permitted; personal TXT exports remain excluded.
$usageFileName = (-join @(0x7D20, 0x82E5, 0x9605, 0x8BFB, 0x4F7F, 0x7528, 0x8BF4, 0x660E | ForEach-Object { [char]$_ })) + '.txt'
$publishedUsagePath = [IO.Path]::GetFullPath((Join-Path $publishDir $usageFileName))
$forbiddenPublishItems = @(Get-ChildItem -LiteralPath $publishDir -Recurse -Force | Where-Object {
    $_.Name -match '^(Data|UserData|WebView2|txt)$' -or
    $_.Extension -in @('.db', '.db-wal', '.db-shm', '.log') -or
    ($_.Extension -eq '.txt' -and $_.FullName -ne $publishedUsagePath)
})
if ($forbiddenPublishItems.Count -gt 0) {
    throw "Publish output contains forbidden data: $($forbiddenPublishItems.FullName -join ', ')"
}

New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

if (Test-Path -LiteralPath $bootstrapperTemp) {
    Remove-Item -LiteralPath $bootstrapperTemp -Force
}
try {
    $downloaded = $false
    for ($attempt = 1; $attempt -le $downloadAttempts; $attempt++) {
        try {
            Invoke-WebRequest -Uri $bootstrapperUrl -OutFile $bootstrapperTemp -UseBasicParsing -TimeoutSec $downloadTimeoutSeconds
            $downloaded = $true
            break
        }
        catch {
            if ($attempt -eq $downloadAttempts) {
                throw
            }
            Start-Sleep -Seconds $downloadRetryDelaySeconds
        }
    }
    if (-not $downloaded) {
        throw 'WebView2 bootstrapper download failed.'
    }
    Assert-MicrosoftSignature -Path $bootstrapperTemp
    Move-Item -LiteralPath $bootstrapperTemp -Destination $bootstrapperPath -Force
}
finally {
    if (Test-Path -LiteralPath $bootstrapperTemp) {
        Remove-Item -LiteralPath $bootstrapperTemp -Force
    }
}

if (Test-Path -LiteralPath $expectedInstaller) {
    Remove-Item -LiteralPath $expectedInstaller -Force
}

$iscc = Find-InnoCompiler
& $iscc '--no-ide-signtools' '--no-signing' "--define=AppVersion=$Version" $installerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $expectedInstaller -PathType Leaf)) {
    throw "Expected installer was not created: $expectedInstaller"
}

$installerFile = Get-Item -LiteralPath $expectedInstaller
$installerHash = Get-FileHash -LiteralPath $expectedInstaller -Algorithm SHA256
$installerSignature = Get-AuthenticodeSignature -LiteralPath $expectedInstaller

Write-Host "Installer completed: $($installerFile.FullName)"
Write-Host "Size: $($installerFile.Length) bytes"
Write-Host "SHA256: $($installerHash.Hash)"
Write-Host "Signature: $($installerSignature.Status)"
