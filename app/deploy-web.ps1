# Publishes the browser version of 音鳥 to the public ototori-web repository
# (GitHub Pages serves its docs/ folder at https://takeruhitomi.github.io/ototori-web/).
#
#   .\deploy-web.ps1 -Message "Web: ..."            build, copy, commit and push
#   .\deploy-web.ps1 -NoPush                         build and copy only
#
# docs/ is the built site (with the homr models). app/ is the source of this
# folder (the files git would track here, so .gitignore'd build output,
# local paths and model weights are left out), published for AGPL-3.0.
param(
    [string]$Repo = (Join-Path $PSScriptRoot '..\..\..\ototori-web'),
    [string]$Message = 'Update the web version',
    [switch]$NoPush
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path $Repo).Path
if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "ototori-web リポジトリがありません: $Repo" }

# Models: not tracked here; taken from the local model bundle.
$models = Join-Path $PSScriptRoot 'web\models'
if (-not (Test-Path (Join-Path $models 'decoder.onnx'))) {
    $bundle = Join-Path $PSScriptRoot '..\..\work\mobile-model-bundle\homr-0.7.zip'
    if (-not (Test-Path $bundle)) { throw "モデルがありません: $bundle" }
    Expand-Archive -Path $bundle -DestinationPath $models -Force
}

Push-Location $PSScriptRoot
try {
    & (Join-Path $PSScriptRoot 'mobile.ps1') build web --release --no-web-resources-cdn --base-href /ototori-web/ --no-wasm-dry-run
    if ($LASTEXITCODE -ne 0) { throw 'Web ビルドに失敗しました。' }
    $site = Join-Path $PSScriptRoot 'build\web'
    foreach ($extra in 'test', 'test-local') { $p = Join-Path $site $extra; if (Test-Path $p) { Remove-Item $p -Recurse -Force } }

    $docs = Join-Path $Repo 'docs'
    robocopy $site $docs /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "サイトのコピーに失敗しました（robocopy $LASTEXITCODE）。" }
    Set-Content -Path (Join-Path $docs '.nojekyll') -Value '' -Encoding ascii

    # Source snapshot: exactly the files git sees in this folder.
    $app = Join-Path $Repo 'app'
    if (Test-Path $app) { Remove-Item $app -Recurse -Force }
    $files = git ls-files -co --exclude-standard
    foreach ($f in $files) {
        $from = Join-Path $PSScriptRoot $f
        if (-not (Test-Path $from -PathType Leaf)) { continue }
        $to = Join-Path $app $f
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        Copy-Item $from $to
    }
} finally { Pop-Location }

if ($NoPush) { Write-Host "コピーしました: $Repo"; return }
# git prints warnings (line endings) on stderr; judge by exit codes instead.
$ErrorActionPreference = 'Continue'
Push-Location $Repo
try {
    git add -A 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'git add に失敗しました。' }
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { Write-Host '変更はありません。'; return }
    $msgFile = New-TemporaryFile
    [IO.File]::WriteAllText($msgFile, "$Message`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`n", [Text.UTF8Encoding]::new($false))
    git commit -q -F $msgFile 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'git commit に失敗しました。' }
    Remove-Item $msgFile
    git push -q 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'git push に失敗しました。' }
    Write-Host 'https://takeruhitomi.github.io/ototori-web/ に公開しました（反映まで1〜2分）。'
} finally { Pop-Location }
