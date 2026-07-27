[CmdletBinding()]
param(
    [string]$Device = 'windows',
    [string]$ApiUrl = 'http://127.0.0.1:8766'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$environmentFile = Join-Path $repoRoot 'deploy\.env'
$flutter = Join-Path $repoRoot '.tooling\flutter\bin\flutter.bat'

if (-not (Test-Path -LiteralPath $environmentFile)) {
    throw 'deploy/.env does not exist. Run scripts/deploy-self-hosted.ps1 first.'
}
if (-not (Test-Path -LiteralPath $flutter)) {
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutterCommand) {
        throw 'Flutter was not found in .tooling/flutter or PATH.'
    }
    $flutter = $flutterCommand.Source
}

$token = $null
foreach ($line in Get-Content -LiteralPath $environmentFile -Encoding utf8) {
    if ($line -match '^MYJISHO_API_TOKEN=(.+)$') {
        $token = $Matches[1]
        break
    }
}
if (-not $token) {
    throw 'MYJISHO_API_TOKEN is missing from deploy/.env.'
}

Push-Location (Join-Path $repoRoot 'apps\dictionary_app')
try {
    & $flutter run `
        -d $Device `
        "--dart-define=MYJISHO_LOCAL_API=$ApiUrl" `
        "--dart-define=MYJISHO_LOCAL_API_TOKEN=$token"
    if ($LASTEXITCODE -ne 0) {
        throw 'Flutter app failed to start.'
    }
}
finally {
    Pop-Location
}
