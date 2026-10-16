# Checks native deployment and resolution for project and NuGet consumers without running TRNSYS.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Runs an SDK command and fails the check on a nonzero exit code.
function Invoke-DotNet {
    & dotnet @args
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $args failed with exit code $LASTEXITCODE."
    }
}

$dotnetRoot = Split-Path $PSScriptRoot -Parent
$library = Join-Path $dotnetRoot 'src/TRNRun/TRNRun.csproj'
$version = ([xml](Get-Content -LiteralPath $library -Raw -Encoding UTF8)).Project.PropertyGroup.Version
foreach ($name in @('trnrun', 'trnrunq')) {
    $binary = Join-Path $dotnetRoot "../../components/$name/build/$name.exe"
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "Missing $binary. Run 'just dotnet-native' from the repository root first."
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('trnrun-layout-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
Push-Location $dotnetRoot
try {
    $feed = Join-Path $work 'feed'
    $cache = Join-Path $work 'packages'
    New-Item -ItemType Directory -Path $feed | Out-Null
    Invoke-DotNet restore $library --source $feed --packages $cache
    Invoke-DotNet pack $library --configuration Release --no-restore --output $feed

    $packageReference = "<PackageReference Include=`"TRNRun`" Version=`"$version`" />"
    foreach ($mode in @('project', 'package', 'transitive-package')) {
        $directory = Join-Path $work $mode
        New-Item -ItemType Directory -Path $directory | Out-Null
        $reference = $packageReference
        if ($mode -eq 'project') {
            $reference = '<ProjectReference Include="' + [Security.SecurityElement]::Escape($library) + '" />'
        }
        elseif ($mode -eq 'transitive-package') {
            $bridge = Join-Path $work 'bridge'
            New-Item -ItemType Directory -Path $bridge | Out-Null
            @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0-windows</TargetFramework>
    <PackageId>TRNRun.LayoutBridge</PackageId>
    <Version>1.0.0</Version>
  </PropertyGroup>
  <ItemGroup>$packageReference</ItemGroup>
</Project>
"@ | Set-Content -LiteralPath (Join-Path $bridge 'Bridge.csproj') -Encoding UTF8
            $bridgeProject = Join-Path $bridge 'Bridge.csproj'
            Invoke-DotNet restore $bridgeProject --source $feed --packages $cache
            Invoke-DotNet pack $bridgeProject --configuration Release --no-restore --output $feed
            $reference = '<PackageReference Include="TRNRun.LayoutBridge" Version="1.0.0" />'
        }

        $project = Join-Path $directory 'App.csproj'
        @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <SelfContained>false</SelfContained>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>$reference</ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $project -Encoding UTF8
        @'
using System.Reflection;
using TRNRun;

Environment.CurrentDirectory = Path.GetTempPath();
string runner = Path.Combine(AppContext.BaseDirectory, "native", "trnrun.exe");
string queue = Path.Combine(AppContext.BaseDirectory, "native", "trnrunq.exe");
foreach (string expected in new[] { runner, queue })
{
    string name = Path.GetFileName(expected);
    if (!File.Exists(expected))
        throw new Exception($"Bundled executable was not deployed to {expected}.");
    if (Directory.GetFiles(AppContext.BaseDirectory, name, SearchOption.AllDirectories).Length != 1)
        throw new Exception($"Unexpected duplicate deployment of {name}.");
}

// Submission resolves the runner; a deployed .exe stands in for TRNSYS so nothing is launched.
var toCliArgs = typeof(SimulationConfig).GetMethod("ToCliArgs", BindingFlags.Instance | BindingFlags.NonPublic)!;
string? Resolve(string? trnRunPath)
{
    object?[] arguments = new object?[1];
    toCliArgs.Invoke(new SimulationConfig { TrnExePath = queue, TrnRunPath = trnRunPath }, arguments);
    return (string?)arguments[0];
}

if (Resolve(null) != runner)
    throw new Exception($"Bundled runner did not resolve to {runner}.");
if (Resolve(runner) != runner)
    throw new Exception($"Explicit runner did not resolve to {runner}.");
try
{
    Resolve(Path.Combine(AppContext.BaseDirectory, "missing.exe"));
    throw new Exception("An invalid explicit path fell back to the bundled executable.");
}
catch (TargetInvocationException error) when (error.InnerException is FileNotFoundException) { }
Console.WriteLine("Both executables deployed to native/, and the runner resolved from it.");
'@ | Set-Content -LiteralPath (Join-Path $directory 'Program.cs') -Encoding UTF8

        Invoke-DotNet restore $project --source $feed --packages $cache
        $build = Join-Path $directory 'bin/Release/net10.0-windows/win-x64'
        Invoke-DotNet build $project --configuration Release --no-restore
        Invoke-DotNet (Join-Path $build 'App.dll')

        foreach ($singleFile in @('false', 'true')) {
            $publish = Join-Path $work "$mode-publish-$singleFile"
            # Bundling needs no extra packages when the single-file analyzer is disabled.
            Invoke-DotNet publish $project --configuration Release --no-restore --output $publish "-p:PublishSingleFile=$singleFile" -p:EnableSingleFileAnalyzer=false
            if ($singleFile -eq 'true') {
                & (Join-Path $publish 'App.exe')
                if ($LASTEXITCODE -ne 0) { throw "Single-file layout check failed for $mode." }
            }
            else {
                Invoke-DotNet (Join-Path $publish 'App.dll')
            }
        }
    }
    Write-Host 'Native layout checks passed for project, NuGet, and transitive NuGet consumers.'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $work -Recurse -Force
}
