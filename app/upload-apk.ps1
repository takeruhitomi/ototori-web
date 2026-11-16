# Uploads the arm64 release APK (with bundled models) to the Google Drive
# folder グリークラブ/音鳥 as choir-omr-<version>-models-arm64.apk. A file of
# the same name is overwritten; other versions are left alone. A copy also
# goes to work/ as before.
#
#   .\upload-apk.ps1
#
# One-time setup (rclone remote rooted at the 音鳥 folder):
#   rclone config create ototori-drive drive scope=drive root_folder_id=<folder id>
param(
    [string]$Remote = $(if ($env:CHOIR_APK_REMOTE) { $env:CHOIR_APK_REMOTE } else { 'ototori-drive:' })
)
$ErrorActionPreference = 'Stop'

$rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
if (-not $rclone) {
    $rclone = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $rclone) { throw 'rclone が見つかりません（winget install Rclone.Rclone）。' }

$apk = Join-Path $PSScriptRoot 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
if (-not (Test-Path $apk)) { throw "APK がありません: $apk" }

# Installs from Drive start without models, so never upload an APK without them.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($apk)
try { $hasModels = [bool]($zip.Entries | Where-Object { $_.FullName -eq 'assets/omr/models.zip' }) } finally { $zip.Dispose() }
if (-not $hasModels) { throw 'APK にモデルが入っていません（CHOIR_MODEL_BUNDLE を指定してビルドしてください）。' }

$version = (Select-String -Path (Join-Path $PSScriptRoot 'pubspec.yaml') -Pattern '^version:\s*([^+\s]+)').Matches[0].Groups[1].Value
$name = "choir-omr-$version-models-arm64.apk"
$work = Join-Path $PSScriptRoot "../../work/$name"
Copy-Item $apk $work -Force

# rclone writes notices to stderr; under Windows PowerShell 'Stop' would
# turn them into errors when output is redirected. Check the exit code instead.
$ErrorActionPreference = 'Continue'
& $rclone copyto $apk "$Remote$name" --stats-one-line --stats 15s
if ($LASTEXITCODE -ne 0) { throw "アップロードに失敗しました（rclone $LASTEXITCODE）。" }
Write-Host "Google ドライブ（グリークラブ/音鳥）にアップロードしました: $name"
