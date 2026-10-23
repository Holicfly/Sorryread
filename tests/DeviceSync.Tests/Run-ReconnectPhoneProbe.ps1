param(
    [Parameter(Mandatory)][string]$HostExecutable,
    [Parameter(Mandatory)][string]$HostDirectory,
    [Parameter(Mandatory)][string]$TestLog,
    [string]$DeviceId = '84aa696e',
    [string]$PackageName = 'com.sorryread.sorryread_mobile.dev',
    [string]$Adb = 'adb'
)
$ErrorActionPreference = 'Stop'
$hostExe = (Resolve-Path -LiteralPath $HostExecutable).Path
$testRoot = [IO.Path]::GetFullPath($HostDirectory)
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$process = $null
$outputTask = $null
$errorTask = $null
$generation = 0
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 120) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while (-not (& $Condition)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Reconnect probe timed out' }
        Start-Sleep -Milliseconds 200
    }
}
function Start-TestHost {
    $start = [Diagnostics.ProcessStartInfo]::new($hostExe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--serve', $testRoot)) { $start.ArgumentList.Add($argument) }
    $script:process = [Diagnostics.Process]::Start($start)
    $script:outputTask = $process.StandardOutput.ReadToEndAsync()
    $script:errorTask = $process.StandardError.ReadToEndAsync()
    $script:generation++
    Wait-Until { (Test-Path "$testRoot/state.json") -and (Get-Item "$testRoot/state.json").LastWriteTimeUtc -gt $process.StartTime.ToUniversalTime() } 60
}
function Stop-TestHost {
    if ($null -eq $script:process) { return }
    Set-Content -LiteralPath "$testRoot/stop" -Value ''
    if (-not $process.WaitForExit(25000)) {
        $process.Kill($true) # Only the process this probe started.
        throw 'Isolated host failed to exit'
    }
    [IO.File]::WriteAllText("$testRoot/host-$generation.log", $outputTask.GetAwaiter().GetResult() + $errorTask.GetAwaiter().GetResult())
    if ($process.ExitCode -ne 0) { throw 'Isolated host failed' }
    $process.Dispose()
    $script:process = $null
    Remove-Item -LiteralPath "$testRoot/stop"
}
try {
    Start-TestHost
    & "$PSScriptRoot/Send-PhoneTestTicket.ps1" -DeviceId $DeviceId -HostDirectory $testRoot -TestLog $TestLog -Adb $Adb -PackageName $PackageName -ReadyPattern 'RECONNECT: ready'
    foreach ($mode in @('stable', 'changed')) {
        Wait-Until { (Test-Path -LiteralPath $TestLog) -and (Select-String -LiteralPath $TestLog -Pattern "RECONNECT: restart $mode" -Quiet) }
        $before = Get-Content "$testRoot/state.json" -Raw | ConvertFrom-Json
        Stop-TestHost
        if ($mode -eq 'changed') { Set-Content -LiteralPath "$testRoot/identity/port.txt" -Value '0' -NoNewline }
        Start-TestHost
        $after = Get-Content "$testRoot/state.json" -Raw | ConvertFrom-Json
        if (-not $after.paired) { throw 'Restart lost the test pairing' }
        if (($mode -eq 'stable') -ne ($before.port -eq $after.port)) { throw 'Unexpected port reuse/change' }
        $progress = if ($mode -eq 'stable') { 0.6 } else { 0.8 }
        @{kind='desktop-read'; progress=$progress} | ConvertTo-Json | Set-Content "$testRoot/command.json"
        Wait-Until { -not (Test-Path "$testRoot/command.json") } 10
        & $Adb -s $DeviceId shell run-as $PackageName touch "files/reconnect-$mode"
        if ($LASTEXITCODE -ne 0) { throw 'Phone signal failed' }
        Wait-Until { Select-String -LiteralPath $TestLog -Pattern "RECONNECT: $mode passed" -Quiet }
        Write-Output "PASS phone wireless reconnect after desktop process restart: $mode"
    }
}
finally { Stop-TestHost }
