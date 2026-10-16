[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $RunnerPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $QueuePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $PackageVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-WindowsX64Executable([string] $Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Not a Windows executable: $Path"
        }

        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 6)) {
            throw "Invalid PE header: $Path"
        }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "Expected a win-x64 (AMD64) executable: $Path"
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-RunnerVersion([string] $Path) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.Arguments = '--version'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start $Path --version"
        }

        # Drain both streams while waiting so diagnostic output cannot fill a pipe.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw "Timed out after 10 seconds: $Path --version"
        }

        $version = $stdout.GetAwaiter().GetResult().Trim()
        $diagnostics = $stderr.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) {
            throw "$Path --version exited with code $($process.ExitCode): $diagnostics"
        }

        return $version
    }
    finally {
        $process.Dispose()
    }
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Native package validation must run on Windows.'
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($RunnerPath, $QueuePath)) {
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Missing native executable: $path. Run 'just dotnet-native' from the repository root."
            }

            $fullPath = (Resolve-Path -LiteralPath $path).ProviderPath
            Assert-WindowsX64Executable $fullPath
            $version = Get-RunnerVersion $fullPath
            if (-not [string]::Equals($version, $PackageVersion, [StringComparison]::Ordinal)) {
                throw "$fullPath reports version '$version'; expected package version '$PackageVersion'. Rebuild both native runners and align the package version."
            }

            Write-Host "Validated $([System.IO.Path]::GetFileName($fullPath)): win-x64, version $version"
        }
        catch {
            $failures.Add($_.Exception.Message)
        }
    }

    if ($failures.Count -gt 0) {
        throw ($failures -join [Environment]::NewLine)
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
