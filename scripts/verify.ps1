[CmdletBinding()]
param(
    [switch]$SkipWebBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$flutter = Join-Path $repoRoot '.tooling\flutter\bin\flutter.bat'

Push-Location $repoRoot
try {
    python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) { throw 'Data/search tests failed.' }

    python -m unittest discover -s services/editor_api/tests -v
    if ($LASTEXITCODE -ne 0) { throw 'Editor tests failed.' }

    if (-not (Test-Path -LiteralPath $flutter)) {
        $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
        if (-not $flutterCommand) {
            throw 'Flutter was not found in .tooling/flutter or PATH.'
        }
        $flutter = $flutterCommand.Source
    }
    $dart = Join-Path (Split-Path -Parent $flutter) 'dart.bat'
    if (-not (Test-Path -LiteralPath $dart)) {
        $dartCommand = Get-Command dart -ErrorAction SilentlyContinue
        if (-not $dartCommand) { throw 'Dart was not found beside Flutter or in PATH.' }
        $dart = $dartCommand.Source
    }

    Push-Location (Join-Path $repoRoot 'apps\dictionary_app')
    try {
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        & $dart format --output=none --set-exit-if-changed lib test
        if ($LASTEXITCODE -ne 0) { throw 'Flutter formatting check failed.' }
        & $flutter analyze
        if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
        & $flutter test
        if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
        if (-not $SkipWebBuild) {
            & $flutter build web --release
            if ($LASTEXITCODE -ne 0) { throw 'Flutter Web build failed.' }
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    Pop-Location
}

Write-Host 'Kotoba verification passed.' -ForegroundColor Green
