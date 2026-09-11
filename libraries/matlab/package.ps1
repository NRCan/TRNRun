[CmdletBinding()]
param(
    [string]$Version = '0.5.0',
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'dist'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$requiredRuntime = @(
    'bin\win64\trnrun.exe',
    'bin\win64\trnrunq.exe',
    'bin\win64\TrnRun.Interop.dll',
    'bin\win64\runtime-manifest.json'
)
foreach ($relativePath in $requiredRuntime) {
    $path = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing staged MATLAB runtime artifact: $path. Run just native-stage first."
    }
}

$packageName = "trnrun-matlab-v$Version-win64"
$packageRoot = Join-Path $OutputDirectory $packageName
$zipPath = Join-Path $OutputDirectory "$packageName.zip"
if (Test-Path -LiteralPath $packageRoot) {
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
[System.IO.Directory]::CreateDirectory($packageRoot) | Out-Null

Copy-Item -LiteralPath (Join-Path $PSScriptRoot '+trnrun') -Destination $packageRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bin') -Destination $packageRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'examples') -Destination $packageRoot -Recurse -Force
foreach ($name in @('README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $packageRoot $name) -Force
}
Set-Content -LiteralPath (Join-Path $packageRoot 'VERSION') -Value $Version -Encoding ASCII

Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal
Write-Output "Created MATLAB ZIP package: $zipPath"
