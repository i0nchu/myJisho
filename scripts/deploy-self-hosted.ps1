[CmdletBinding()]
param(
    [string]$Model = 'qwen3:8b',
    [switch]$SkipModelPull
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$deployDirectory = Join-Path $repoRoot 'deploy'
$environmentFile = Join-Path $deployDirectory '.env'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker Desktop / Docker Engine is required but docker was not found.'
}

docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Compose v2 is required.'
}

if (-not (Test-Path -LiteralPath $environmentFile)) {
    $secretBytes = New-Object byte[] 32
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($secretBytes)
    }
    finally {
        $random.Dispose()
    }
    $token = -join ($secretBytes | ForEach-Object { $_.ToString('x2') })
    $environmentLines = @(
        "KOTOBA_API_TOKEN=$token"
        "KOTOBA_LLM_MODEL=$Model"
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines(
        $environmentFile,
        $environmentLines,
        $utf8NoBom
    )
    Write-Host 'Created deploy/.env with a random API token.'
}

Push-Location $deployDirectory
try {
    docker compose up -d ollama
    if ($LASTEXITCODE -ne 0) { throw 'Could not start Ollama.' }

    if (-not $SkipModelPull) {
        docker compose exec -T ollama ollama pull $Model
        if ($LASTEXITCODE -ne 0) { throw "Could not pull model $Model." }
    }

    docker compose up -d --build kotoba-api
    if ($LASTEXITCODE -ne 0) { throw 'Could not build or start the Kotoba API.' }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $environmentFile -Encoding utf8) {
        if ($line -match '^([^#=]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    $headers = @{ Authorization = "Bearer $($values['KOTOBA_API_TOKEN'])" }
    $healthy = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $response = Invoke-RestMethod `
                -Uri 'http://127.0.0.1:8766/api/health' `
                -Headers $headers `
                -TimeoutSec 3
            if ($response.ok -eq $true) {
                $healthy = $true
                break
            }
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $healthy) {
        docker compose ps
        throw 'Kotoba API did not become healthy within 120 seconds.'
    }
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host 'Kotoba self-hosted services are healthy.' -ForegroundColor Green
Write-Host 'API: http://127.0.0.1:8766'
Write-Host 'Build the app with these values from deploy/.env:'
Write-Host '  --dart-define=KOTOBA_LOCAL_API=http://127.0.0.1:8766'
Write-Host '  --dart-define=KOTOBA_LOCAL_API_TOKEN=<KOTOBA_API_TOKEN>'
