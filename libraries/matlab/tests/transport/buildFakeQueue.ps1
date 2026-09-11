[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$buildDirectory = Join-Path $PSScriptRoot 'build'
[System.IO.Directory]::CreateDirectory($buildDirectory) | Out-Null
$output = Join-Path $buildDirectory 'fake_queue.exe'
$cache = Join-Path $buildDirectory 'nimcache'
$source = Join-Path $PSScriptRoot 'fake_queue.nim'

nim c --mm:orc --threads:on -d:release --out:$output --nimcache:$cache $source
if ($LASTEXITCODE -ne 0) {
    throw "Could not build fake_queue.exe (nim exit code $LASTEXITCODE)."
}
Write-Output "Built MATLAB transport fixture: $output"
