# Set the version of every component and library, such as: Set-Version.ps1 0.9.0
param([Parameter(Mandatory)][string]$Version)

$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must look like 0.9.0, got '$Version'"
}

$root = Split-Path $PSScriptRoot
$targets = @(
    @{ Path = 'components/*/*.nimble'; Pattern = '(?m)^version = "[^"]*"'; Value = "version = `"$Version`"" }
    @{ Path = 'libraries/python/trnrun/__init__.py'; Pattern = '(?m)^__version__ = "[^"]*"'; Value = "__version__ = `"$Version`"" }
    @{ Path = 'libraries/matlab/toolbox/+trnrun/version.m'; Pattern = "value = '[^']*';"; Value = "value = '$Version';" }
    @{ Path = 'libraries/dotnet/src/TRNRun/TRNRun.csproj'; Pattern = '<Version>[^<]*</Version>'; Value = "<Version>$Version</Version>" }
)

# Check every file before writing any, so a missing version never leaves the repo half updated.
$changes = foreach ($target in $targets) {
    $files = @(Get-ChildItem (Join-Path $root $target.Path))
    if ($files.Count -eq 0) { throw "No file matches $($target.Path)" }

    foreach ($file in $files) {
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text -notmatch $target.Pattern) { throw "No version found in $($file.FullName)" }
        @{ Path = $file.FullName; Text = $text -replace $target.Pattern, $target.Value }
    }
}

foreach ($change in $changes) {
    # WriteAllText keeps UTF-8 without a BOM, unlike Set-Content in Windows PowerShell.
    [IO.File]::WriteAllText($change.Path, $change.Text)
    Write-Host "$Version  $($change.Path.Substring($root.Length + 1))"
}
