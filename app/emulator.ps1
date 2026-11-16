param(
    [ValidateSet('start', 'status', 'stop')][string]$Action = 'start',
    [switch]$ShowWindow,
    [switch]$Silent,
    [ValidateRange(5554, 5682)][int]$Port = 5554,
    [ValidateRange(10, 600)][int]$BootTimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
if ($Port % 2) { throw 'Use an even emulator console port.' }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$sdk = Join-Path $repo 'work/mobile-sdk'
$env:ANDROID_HOME = Join-Path $sdk 'android'
$env:ANDROID_USER_HOME = Join-Path $sdk 'android-user'
$env:ANDROID_EMULATOR_HOME = $env:ANDROID_USER_HOME
$env:ANDROID_AVD_HOME = Join-Path $env:ANDROID_USER_HOME 'avd'
Remove-Item Env:ANDROID_SDK_HOME -ErrorAction SilentlyContinue
$env:TEMP = Join-Path $sdk 'tmp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
$emulator = Join-Path $env:ANDROID_HOME 'emulator/emulator.exe'
$adb = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$serial = "emulator-$Port"
foreach ($tool in @($emulator, $adb)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "SDK tool not found: $tool" }
}
function Test-Booted {
    $ErrorActionPreference = 'Continue'
    $state = & $adb -s $serial get-state 2>$null
    if ($LASTEXITCODE -ne 0 -or $state -ne 'device') { return $false }
    $booted = & $adb -s $serial shell getprop sys.boot_completed 2>$null
    return $LASTEXITCODE -eq 0 -and "$booted".Trim() -eq '1'
}
if ($Action -eq 'status') {
    & $adb devices -l
    if (Test-Booted) { Write-Output "$serial Android boot complete"; exit 0 }
    Write-Output "$serial Android not ready"
    exit 1
}
if ($Action -eq 'stop') {
    & $adb -s $serial emu kill
    exit $LASTEXITCODE
}
if (Test-Booted) {
    Write-Output "$serial Android boot complete (already running)"
    exit 0
}
$properties = Join-Path $env:ANDROID_HOME 'emulator/source.properties'
if ((Get-Content -LiteralPath $properties) -notcontains 'Pkg.Revision=37.3.8') {
    throw 'Install the tested emulator first: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup_mobile_emulator.ps1 (from the repository root).'
}
$devices = & $adb devices
if ($devices -match "^$serial\s") {
    throw "$serial exists but is not ready. Check its startup log before restarting."
}
if (-not (Test-Path -LiteralPath (Join-Path $env:ANDROID_AVD_HOME 'choir_phone.ini'))) {
    throw 'AVD choir_phone was not found.'
}
$arguments = @('-avd', 'choir_phone', '-port', "$Port", '-no-snapshot',
    '-gpu', 'swiftshader', '-feature', '-Vulkan', '-timezone', 'Asia/Tokyo')
if (-not $ShowWindow) { $arguments += '-no-window' }
if ($Silent) { $arguments += '-no-audio' }
$stdout = Join-Path $sdk "emulator-$Port.stdout.log"
$stderr = Join-Path $sdk "emulator-$Port.stderr.log"
$launch = @{
    FilePath = $emulator
    ArgumentList = $arguments
    WorkingDirectory = $repo
    RedirectStandardOutput = $stdout
    RedirectStandardError = $stderr
    PassThru = $true
}
if (-not $ShowWindow) { $launch.WindowStyle = 'Hidden' }
$process = Start-Process @launch
$deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
do {
    if (Test-Booted) {
        Write-Output "$serial Android boot complete; launcher PID $($process.Id)"
        Write-Output "Debug: ./mobile.ps1 run -d $serial"
        exit 0
    }
    $process.Refresh()
    if ($process.HasExited) { throw "Emulator exited ($($process.ExitCode)). Logs: $stdout ; $stderr" }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
throw "Android did not boot within ${BootTimeoutSeconds}s. Logs: $stdout ; $stderr"
