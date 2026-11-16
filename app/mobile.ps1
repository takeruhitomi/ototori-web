# Keep each argument separate under Windows PowerShell 5.1. Binding a splatted
# array with ValueFromRemainingArguments can combine it into one command name.
$FlutterArgs = @($args)

$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$sdk = Join-Path $root 'work/mobile-sdk'
$flutter = Join-Path $sdk 'flutter/bin/flutter.bat'
if (-not (Test-Path $flutter)) { throw "Flutter SDK が見つかりません: $flutter" }
$env:PUB_CACHE = Join-Path $sdk 'pub-cache'
$env:ANDROID_HOME = Join-Path $sdk 'android'
$env:ANDROID_USER_HOME = Join-Path $sdk 'android-user'
$env:ANDROID_EMULATOR_HOME = $env:ANDROID_USER_HOME
# ANDROID_SDK_HOME is deprecated and points to a different preferences
# directory than ANDROID_USER_HOME. AGP rejects that combination.
Remove-Item Env:ANDROID_SDK_HOME -ErrorAction SilentlyContinue
$env:ANDROID_AVD_HOME = Join-Path $sdk 'android-user/avd'
$env:GRADLE_USER_HOME = Join-Path $sdk 'gradle'
$taskTemp = Join-Path $sdk 'tmp'
New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
if (Test-Path 'C:\Program Files\Java\jdk-21') { $env:JAVA_HOME = 'C:\Program Files\Java\jdk-21' }
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
if ($FlutterArgs.Count -eq 0) { $FlutterArgs = @('doctor') }
# A release APK build also uploads the arm64 APK to Google Drive
# (upload-apk.ps1); --no-upload skips that.
$upload = $FlutterArgs -notcontains '--no-upload'
$FlutterArgs = @($FlutterArgs | Where-Object { $_ -ne '--no-upload' })
$releaseApk = $FlutterArgs.Count -ge 2 -and $FlutterArgs[0] -eq 'build' -and $FlutterArgs[1] -eq 'apk' -and $FlutterArgs -contains '--release'
# The Drive copy is installed on fresh devices, so it carries the models.
$modelZip = Join-Path $root 'work/mobile-model-bundle/homr-0.7.zip'
if ($releaseApk -and $upload -and -not $env:CHOIR_MODEL_BUNDLE -and (Test-Path $modelZip)) { $env:CHOIR_MODEL_BUNDLE = $modelZip }
Push-Location $PSScriptRoot
try {
    & $flutter @FlutterArgs
    $code = $LASTEXITCODE
    if ($code -eq 0 -and $releaseApk -and $upload) {
        try { & (Join-Path $PSScriptRoot 'upload-apk.ps1') }
        catch { Write-Warning "Google ドライブへのアップロードに失敗しました: $_" }
    }
    exit $code
} finally { Pop-Location }
