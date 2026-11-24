[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2100000000)]
    [int] $VersionCode,
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $VersionName = '1.0.0',
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [string] $Flutter = 'flutter',
    [switch] $Unsigned
)

# Supply ANDROID_KEYSTORE_PATH, ANDROID_STORE_PASSWORD, ANDROID_KEY_ALIAS and
# ANDROID_KEY_PASSWORD privately, or use ignored app/android/key.properties.
# This script never creates keys, uploads a bundle or prints signing values.
$ErrorActionPreference = 'Stop'
$repoDirectory = Split-Path -Parent $PSScriptRoot
$artifactDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$previousUnsigned = [Environment]::GetEnvironmentVariable('DECKOS_ALLOW_UNSIGNED_RELEASE')
$signingNames = @('ANDROID_KEYSTORE_PATH', 'ANDROID_STORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')
if ($Unsigned -and ((Test-Path -LiteralPath (Join-Path $repoDirectory 'app/android/key.properties')) -or
    ($signingNames | Where-Object { [Environment]::GetEnvironmentVariable($_) }))) {
    throw 'Unsigned mode requires no configured signing values or key.properties. Use a separate build environment; existing keys are never overwritten.'
}
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$suffix = if ($Unsigned) { 'unsigned-candidate' } else { 'upload-signed-candidate' }
$bundleName = "DeckOS-$VersionName-$VersionCode-$suffix.aab"
$bundleDestination = Join-Path $artifactDirectory $bundleName
if (Test-Path -LiteralPath $bundleDestination) { throw 'Artifact already exists; choose a new output directory.' }

Push-Location (Join-Path $repoDirectory 'app')
try {
    $env:DECKOS_ALLOW_UNSIGNED_RELEASE = if ($Unsigned) { 'true' } else { 'false' }
    & $Flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    & $Flutter build appbundle --release "--build-name=$VersionName" "--build-number=$VersionCode" `
        "--split-debug-info=$(Join-Path $artifactDirectory 'private-dart-symbols')"
    if ($LASTEXITCODE -ne 0) { throw 'Release bundle build failed.' }
    Copy-Item -LiteralPath 'build/app/outputs/bundle/release/app-release.aab' -Destination $bundleDestination
    $commit = (& git rev-parse HEAD).Trim()
    $hash = (Get-FileHash -LiteralPath $bundleDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{
        packageName = 'io.github.itskavin.deckos'
        versionName = $VersionName
        versionCode = $VersionCode
        signing = $suffix
        consoleVersionCodeConfirmed = $false
        sourceCommit = $commit
        sourceHasTrackedChanges = [bool](& git status --porcelain --untracked-files=no)
        bundle = $bundleName
        sha256 = $hash
        uploadReady = $false
        note = 'Candidate only. Validate signature, manifest, native alignment, transport/privacy readiness and Play account state before upload.'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifactDirectory 'bundle-build.json') -Encoding utf8
    Write-Output "Built $bundleDestination"
    Write-Output "SHA256 $hash"
} finally {
    [Environment]::SetEnvironmentVariable('DECKOS_ALLOW_UNSIGNED_RELEASE', $previousUnsigned)
    Pop-Location
}
