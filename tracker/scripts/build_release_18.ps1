<#
.SYNOPSIS
    Copies Type3830 build files into the dist\TRNSYS18 folder structure for a GitHub release.

.DESCRIPTION
    Run this script from your project root (the folder that contains src\, proformas\,
    build\, and dist\). Or pass -RootPath to point at the project root explicitly.

.PARAMETER RootPath
    The project root folder. Defaults to the folder the script is run from.
#>

[CmdletBinding()]
param(
    [string]$RootPath = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

# Helper: ensure destination folder exists, then copy (and optionally rename) a file
function Copy-ReleaseFile {
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$DestFolder,
        [string]$NewFileName  # optional rename
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-Warning "SKIPPED (not found): $SourcePath"
        return
    }

    if (-not (Test-Path -LiteralPath $DestFolder)) {
        New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
    }

    $destFile = if ($NewFileName) {
        Join-Path $DestFolder $NewFileName
    } else {
        Join-Path $DestFolder (Split-Path $SourcePath -Leaf)
    }

    Copy-Item -LiteralPath $SourcePath -Destination $destFile -Force
    Write-Host "Copied: $SourcePath" -ForegroundColor Green
    Write-Host "    -> $destFile" -ForegroundColor DarkGray
}

# --- Define source/destination pairs ---

$srcSourceCode = Join-Path $RootPath "src\Type3830.f90"
$dstSourceCode = Join-Path $RootPath "dist\TRNSYS18\SourceCode\Types\NRCan"

$srcBmp = Join-Path $RootPath "proformas\Type3830.bmp"
$dstProformas = Join-Path $RootPath "dist\TRNSYS18\Studio\Proformas\Utility (NRCan)\Progress Tracker"

$srcTmf = Join-Path $RootPath "proformas\Type3830_18.tmf"

$srcDebugDll = Join-Path $RootPath "build\DebugDLLs_18\Type3830.dll"
$dstDebugDll = Join-Path $RootPath "dist\TRNSYS18\UserLib\DebugDLLs"

$srcReleaseDll = Join-Path $RootPath "build\ReleaseDLLs_18\Type3830.dll"
$dstReleaseDll = Join-Path $RootPath "dist\TRNSYS18\UserLib\ReleaseDLLs"

# --- Perform copies ---

Write-Host "Project root: $RootPath`n" -ForegroundColor Cyan

Copy-ReleaseFile -SourcePath $srcSourceCode -DestFolder $dstSourceCode
Copy-ReleaseFile -SourcePath $srcBmp        -DestFolder $dstProformas
Copy-ReleaseFile -SourcePath $srcTmf        -DestFolder $dstProformas -NewFileName "Type3830.tmf"
Copy-ReleaseFile -SourcePath $srcDebugDll   -DestFolder $dstDebugDll
Copy-ReleaseFile -SourcePath $srcReleaseDll -DestFolder $dstReleaseDll

Write-Host "`nDone." -ForegroundColor Cyan
