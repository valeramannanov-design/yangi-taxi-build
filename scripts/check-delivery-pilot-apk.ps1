param(
    [Parameter(Mandatory=$true)][string]$Apk,
    [string]$ExpectedCertificateSha256 = '7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997'
)
$ErrorActionPreference='Stop'
if(!$env:ANDROID_HOME){throw 'ANDROID_HOME is required for APK verification'}
if($ExpectedCertificateSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Expected certificate must be a SHA-256 fingerprint'}
$tools=Join-Path $env:ANDROID_HOME 'build-tools\36.0.0'
$certificate=& (Join-Path $tools 'apksigner.bat') verify --print-certs $Apk
if($LASTEXITCODE -ne 0){throw 'APK signature verification failed'}
$fingerprints=@($certificate|Select-String '^Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]{64})$')
if($fingerprints.Count -ne 1 -or $fingerprints[0].Matches[0].Groups[1].Value.ToLower() -ne $ExpectedCertificateSha256.ToLower()){
    throw 'Passenger pilot signing key mismatch. Restore its original Android user home; do not uninstall the app.'
}
$badging=& (Join-Path $tools 'aapt.exe') dump badging $Apk
if($LASTEXITCODE -ne 0 -or !($badging|Select-String "^package: name='uz.yangi.yangi_taxi.deliverydev' ")){throw 'Expected the separate passenger pilot package'}
Write-Output 'Passenger pilot package and original signing certificate verified'
