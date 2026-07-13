$ErrorActionPreference = 'Stop'

$extensionRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $extensionRoot
$output = Join-Path $repoRoot 'dist\PiliPlus-Adaptive-CDN-Web-0.2.4.zip'
$staging = Join-Path $env:TEMP 'PiliPlus-Adaptive-CDN-Web-package'

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
