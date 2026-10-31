$ErrorActionPreference = 'Stop'

$extensionRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $extensionRoot
$dist = Join-Path $repoRoot 'dist'
$manifest = Get-Content -LiteralPath (Join-Path $extensionRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$output = Join-Path $dist "PiliPlus-Adaptive-CDN-Web-$($manifest.version).zip"
# $env:TEMP is unset for PowerShell on Linux (the release runner), so resolve
# the platform temp directory through .NET instead of assuming Windows.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) 'PiliPlus-Adaptive-CDN-Web-package'

if (!(Test-Path -LiteralPath $dist)) {
    New-Item -ItemType Directory -Path $dist | Out-Null
}

if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
New-Item -ItemType Directory -Path $staging | Out-Null

$files = @(
    'manifest.json',
    'core.js',
    'page.js',
    'bridge.js',
    'popup.html',
    'popup.js',
    'options.html',
    'options.js',
    'ui.css',
    'README.md'
)
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $extensionRoot $file) -Destination $staging
}

if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Force
}
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $output -CompressionLevel Optimal
Remove-Item -LiteralPath $staging -Recurse -Force
Write-Output $output
