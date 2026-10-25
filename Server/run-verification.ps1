$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path $env:TEMP 'MaisonZenVerification'
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$tempFolder = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempFolder | Out-Null

$savedEnvironment = $env:ASPNETCORE_ENVIRONMENT
$savedUrls = $env:ASPNETCORE_URLS
$savedDatabasePath = $env:DatabasePath
$env:ASPNETCORE_ENVIRONMENT = 'Development'
$env:ASPNETCORE_URLS = 'http://127.0.0.1:5080'
$env:DatabasePath = Join-Path $tempFolder 'test.db'

$stdoutPath = Join-Path $tempFolder 'server.out.log'
$stderrPath = Join-Path $tempFolder 'server.err.log'
$server = $null
try {
    $server = Start-Process -FilePath 'dotnet' -ArgumentList @('.\bin\Debug\net10.0\MaisonZen.Server.dll', '--urls', 'http://127.0.0.1:5080') -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $healthy = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri 'http://127.0.0.1:5080/health' -TimeoutSec 2
            if ($health.status -eq 'ok') { $healthy = $true; break }
        } catch { Start-Sleep -Milliseconds 400 }
    }
    if (-not $healthy) {
        $serverLog = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
        throw "Le serveur n’est pas devenu disponible. $serverLog"
    }
    & (Join-Path $PSScriptRoot 'verify-api.ps1') -BaseUrl 'http://127.0.0.1:5080'
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    $env:ASPNETCORE_ENVIRONMENT = $savedEnvironment
    $env:ASPNETCORE_URLS = $savedUrls
    $env:DatabasePath = $savedDatabasePath
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedTempFolder = [System.IO.Path]::GetFullPath($tempFolder)
    if ($resolvedTempFolder.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedTempFolder -Parent) -eq $resolvedTempRoot) {
        Remove-Item -LiteralPath $resolvedTempFolder -Recurse -Force
    }
}
