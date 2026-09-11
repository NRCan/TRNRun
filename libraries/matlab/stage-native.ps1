[CmdletBinding()]
param(
    [string]$Version = '0.5.0',
    [string]$RunnerPath,
    [string]$QueuePath,
    [string]$InteropPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($RunnerPath)) {
    $RunnerPath = Join-Path $repositoryRoot 'components\trnrun\build\trnrun.exe'
}
if ([string]::IsNullOrWhiteSpace($QueuePath)) {
    $QueuePath = Join-Path $repositoryRoot 'components\trnrunq\build\trnrunq.exe'
}
if ([string]::IsNullOrWhiteSpace($InteropPath)) {
    $InteropPath = Join-Path $PSScriptRoot 'bin\win64\TrnRun.Interop.dll'
}

$sources = [ordered]@{
    'trnrun.exe' = [System.IO.Path]::GetFullPath($RunnerPath)
    'trnrunq.exe' = [System.IO.Path]::GetFullPath($QueuePath)
    'TrnRun.Interop.dll' = [System.IO.Path]::GetFullPath($InteropPath)
}
foreach ($entry in $sources.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Missing native runtime artifact $($entry.Key): $($entry.Value)"
    }
}

$pythonBin = Join-Path $repositoryRoot 'libraries\python\trnrun\bin'
$matlabBin = Join-Path $repositoryRoot 'libraries\matlab\bin\win64'
[System.IO.Directory]::CreateDirectory($pythonBin) | Out-Null
[System.IO.Directory]::CreateDirectory($matlabBin) | Out-Null

# Copy each executable from one authoritative build output to both clients.
foreach ($name in @('trnrun.exe', 'trnrunq.exe')) {
    Copy-Item -LiteralPath $sources[$name] -Destination (Join-Path $pythonBin $name) -Force
    Copy-Item -LiteralPath $sources[$name] -Destination (Join-Path $matlabBin $name) -Force
}
Copy-Item -LiteralPath $sources['TrnRun.Interop.dll'] `
    -Destination (Join-Path $matlabBin 'TrnRun.Interop.dll') -Force

$artifacts = [ordered]@{}
foreach ($name in @('trnrun.exe', 'trnrunq.exe')) {
    $pythonHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $pythonBin $name)).Hash.ToLowerInvariant()
    $matlabHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $matlabBin $name)).Hash.ToLowerInvariant()
    if ($pythonHash -ne $matlabHash) {
        throw "Staged clients contain mismatched $name bytes."
    }
    $artifacts[$name] = [ordered]@{ sha256 = $pythonHash }
}
$interopHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $matlabBin 'TrnRun.Interop.dll')).Hash.ToLowerInvariant()
$artifacts['TrnRun.Interop.dll'] = [ordered]@{ sha256 = $interopHash }

$manifest = [ordered]@{
    schema_version = 1
    version = $Version
    platform = 'win_amd64'
    artifacts = $artifacts
}
$json = $manifest | ConvertTo-Json -Depth 5
Set-Content -LiteralPath (Join-Path $pythonBin 'runtime-manifest.json') -Value $json -Encoding UTF8
Set-Content -LiteralPath (Join-Path $matlabBin 'runtime-manifest.json') -Value $json -Encoding UTF8

Write-Output "Staged matched runtime version $Version for Python and MATLAB."
