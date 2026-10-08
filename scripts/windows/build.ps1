[CmdletBinding()]
param([switch]$CaptureOnly)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$savedEnv = @{}
foreach ($key in @('GOOS', 'GOARCH', 'CGO_ENABLED')) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
Push-Location $repoRoot
try {
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        throw 'Install Go matching go.mod, then add its bin directory to PATH.'
    }
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:CGO_ENABLED = '0'
    New-Item -ItemType Directory -Force dist/windows-amd64 | Out-Null
    New-Item -ItemType Directory -Force dist/build | Out-Null
    # Substitute only the compiler input. Never edit or copy over upstream code.
    $overlayPath = Join-Path $repoRoot 'dist/build/overlay.json'
    $replacement = @{}
    $replacement[(Join-Path $repoRoot 'internal/livecap/livecap.go')] = Join-Path $PSScriptRoot 'livecap.stub'
    $overlay = @{ Replace = $replacement } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($overlayPath, $overlay, [Text.UTF8Encoding]::new($false))
    & go build -overlay $overlayPath -trimpath -o dist/windows-amd64/rocom-interfaces.exe ./cmd/rocom-interfaces
    if ($LASTEXITCODE -ne 0) { throw 'Adapter tool build failed.' }
    if ($CaptureOnly) { return }
    if (-not (Test-Path internal/gamedata/data/names.json) -or
        -not (Test-Path internal/gamedata/data/img) -or
        -not (Get-ChildItem internal/pb -Filter '*.go' -ErrorAction SilentlyContinue)) {
        throw 'Generate internal/gamedata/data and internal/pb using the sibling rocom-parse repository before building.'
    }
    & go build -overlay $overlayPath -trimpath -ldflags '-s -w' -o dist/windows-amd64/rocom-capture.unverified.exe ./cmd/rocom-capture
    if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }
    # With neither -iface nor -pcap, upstream loads assets/SQLite then exits.
    # This checks data compatibility without capturing traffic or writing a DB.
    & ./dist/windows-amd64/rocom-capture.unverified.exe -db ':memory:' -addr '127.0.0.1:0'
    if ($LASTEXITCODE -ne 0) {
        throw 'Application startup check failed. Regenerate matching game assets; the candidate remains rocom-capture.unverified.exe.'
    }
    Move-Item -LiteralPath dist/windows-amd64/rocom-capture.unverified.exe -Destination dist/windows-amd64/rocom-capture.exe -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launcher.ps1') -Destination dist/windows-amd64/launcher.ps1 -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start.bat') -Destination dist/windows-amd64/start.bat -Force
    Write-Host 'Built dist/windows-amd64/rocom-capture.exe'
}
finally {
    Pop-Location
    foreach ($key in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process')
    }
}
