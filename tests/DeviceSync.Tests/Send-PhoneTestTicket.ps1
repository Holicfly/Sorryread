param(
    [Parameter(Mandatory)][string]$DeviceId,
    [Parameter(Mandatory)][string]$HostDirectory,
    [Parameter(Mandatory)][string]$TestLog,
    [string]$Adb = 'adb',
    [string]$PackageName = 'com.sorryread.sorryread_mobile.dev',
    [string]$ReadyPattern = 'LAN: discover'
)
$ErrorActionPreference = 'Stop'
$testHostRoot = (Resolve-Path -LiteralPath $HostDirectory).Path
$testLogPath = [IO.Path]::GetFullPath($TestLog)
$deadline = [DateTime]::UtcNow.AddMinutes(3)
while ([DateTime]::UtcNow -lt $deadline) {
    if ((Test-Path -LiteralPath $testLogPath) -and
        (Select-String -LiteralPath $testLogPath -Pattern $ReadyPattern -Quiet)) { break }
    Start-Sleep -Milliseconds 500
}
if ([DateTime]::UtcNow -ge $deadline) { throw 'Phone test did not start.' }
$refreshFile = Join-Path $testHostRoot 'refresh-ticket'
Set-Content -LiteralPath $refreshFile -Value ''
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ((Test-Path -LiteralPath $refreshFile) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
}
if (Test-Path -LiteralPath $refreshFile) { throw 'Isolated host did not refresh its pairing offer.' }
& $Adb -s $DeviceId shell run-as $PackageName mkdir -p files
if ($LASTEXITCODE -ne 0) { throw 'Test application is not installed or debuggable.' }
function Copy-TestInput([string]$Source, [string]$Name) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Adb
    foreach ($argument in @('-s', $DeviceId, 'shell', '-T', 'run-as',
        $PackageName, 'sh', '-c', "'base64 -d > files/$Name'")) {
        $start.ArgumentList.Add($argument)
    }
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $bytes = [IO.File]::ReadAllBytes($Source)
        # Windows adb stdin treats CR/LF and Ctrl-Z as text. Use ASCII base64
        # so binary PNG signatures and UTF-8 JSON survive without conversion.
        $process.StandardInput.Write([Convert]::ToBase64String($bytes))
        $process.StandardInput.Close()
        # Never print credentials or QR payloads.
        $null = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Copying isolated test input failed.' }
    }
    finally { $process.Dispose() }
}
$image = Join-Path $testHostRoot 'pairing.png'
if (Test-Path -LiteralPath $image) { Copy-TestInput $image 'sync-qr.png' }
Copy-TestInput (Join-Path $testHostRoot 'pairing.json') 'sync-ticket.json'
Write-Output 'Injected fresh isolated test inputs; no credential was printed.'
