[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\bin\win64')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $PSScriptRoot 'KillOnCloseJob.cs'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "C# source not found: $sourcePath"
}

$frameworkDirectories = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319')
)

$compilerPath = $null
foreach ($frameworkDirectory in $frameworkDirectories) {
    $candidate = Join-Path $frameworkDirectory 'csc.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $compilerPath = $candidate
        break
    }
}

if ($null -eq $compilerPath) {
    throw 'The .NET Framework 4.x C# compiler was not found. Enable the Windows .NET Framework development tools and retry.'
}

$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
$outputPath = Join-Path $resolvedOutputDirectory 'TrnRun.Interop.dll'

$compilerArguments = @(
    '/nologo',
    '/target:library',
    '/platform:anycpu',
    '/optimize+',
    '/warn:4',
    '/warnaserror+',
    "/out:$outputPath",
    $sourcePath
)

& $compilerPath $compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "C# compilation failed with exit code $LASTEXITCODE."
}

Write-Output "Built AnyCPU .NET Framework assembly: $outputPath"
