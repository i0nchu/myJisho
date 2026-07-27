[CmdletBinding()]
param(
    [string]$Model = $env:MYJISHO_LLM_MODEL,
    [switch]$SkipModelPull
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$deployDirectory = Join-Path $repoRoot 'deploy'
$environmentFile = Join-Path $deployDirectory '.env'

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $environmentFile)) {
        return ''
    }
    foreach ($line in Get-Content -LiteralPath $environmentFile -Encoding utf8) {
        if ($line -match "^$([regex]::Escape($Name))=(.*)$") {
            return $Matches[1].Trim()
        }
    }
    return ''
}

function Set-EnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Value
    )

    $lines = @(
        if (Test-Path -LiteralPath $environmentFile) {
            Get-Content -LiteralPath $environmentFile -Encoding utf8
        }
    )
    $found = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match "^$([regex]::Escape($Name))=") {
            $lines[$index] = "$Name=$Value"
            $found = $true
        }
    }
    if (-not $found) {
        $lines += "$Name=$Value"
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($environmentFile, $lines, $utf8NoBom)
}

if ([string]::IsNullOrWhiteSpace($Model)) {
    $Model = Get-EnvironmentValue -Name 'MYJISHO_LLM_MODEL'
}
if ([string]::IsNullOrWhiteSpace($Model) -or $Model -match '\s') {
    throw 'MYJISHO_LLM_MODEL is required. Set -Model, the process environment, or deploy/.env to an explicit model name.'
}
$Model = $Model.Trim()

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
        "MYJISHO_API_TOKEN=$token"
        "MYJISHO_LLM_MODEL=$Model"
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines(
        $environmentFile,
        $environmentLines,
        $utf8NoBom
    )
    Write-Host 'Created deploy/.env with a random API token.'
}
else {
    Set-EnvironmentValue -Name 'MYJISHO_LLM_MODEL' -Value $Model
}

Push-Location $deployDirectory
try {
    docker compose up -d ollama
    if ($LASTEXITCODE -ne 0) { throw 'Could not start Ollama.' }

    if (-not $SkipModelPull) {
        docker compose exec -T ollama ollama pull $Model
        if ($LASTEXITCODE -ne 0) { throw "Could not pull model $Model." }
    }

    docker compose up -d --build myjisho-api
    if ($LASTEXITCODE -ne 0) { throw 'Could not build or start the myJisho API.' }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $environmentFile -Encoding utf8) {
        if ($line -match '^([^#=]+)=(.*)$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    $headers = @{ Authorization = "Bearer $($values['MYJISHO_API_TOKEN'])" }
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
        throw 'myJisho API did not become healthy within 120 seconds.'
    }
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host 'myJisho self-hosted services are healthy.' -ForegroundColor Green
Write-Host 'API: http://127.0.0.1:8766'
Write-Host 'Build the app with these values from deploy/.env:'
Write-Host '  --dart-define=MYJISHO_LOCAL_API=http://127.0.0.1:8766'
Write-Host '  --dart-define=MYJISHO_LOCAL_API_TOKEN=<MYJISHO_API_TOKEN>'
