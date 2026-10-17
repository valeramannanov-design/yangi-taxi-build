param(
    [Parameter(Mandatory=$true)][string]$DefinesFile,
    [Parameter(Mandatory=$true)][string]$OutputApk,
    [string]$FlutterCommand = 'flutter',
    [string]$NodeCommand = 'node',
    [string]$ExpectedCertificateSha256 = '7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997'
)
$ErrorActionPreference = 'Stop'
$configPath = (Resolve-Path -LiteralPath $DefinesFile).Path
$destination = [System.IO.Path]::GetFullPath($OutputApk)
$projectRoot = Split-Path -Parent $PSScriptRoot
& $NodeCommand (Join-Path $PSScriptRoot 'check-delivery-build.mjs') --file $configPath --probe
if ($LASTEXITCODE -ne 0) { throw 'Delivery build configuration or live preflight failed' }
Push-Location (Join-Path $projectRoot 'flutter')
try {
    # A pilot uses the separate debug package. No production application is replaced.
    & $FlutterCommand build apk --debug "--dart-define-from-file=$configPath"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed' }
    $source = Join-Path $projectRoot 'flutter/build/app/outputs/flutter-apk/app-debug.apk'
    & (Join-Path $PSScriptRoot 'check-delivery-pilot-apk.ps1') -Apk $source -ExpectedCertificateSha256 $ExpectedCertificateSha256
    $parent = Split-Path -Parent $destination
    if (!(Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination
    [pscustomobject]@{ apk=$destination; sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash; distribution='pilot-debug' } | ConvertTo-Json
} finally { Pop-Location }
