# Sign a file with AzureSignTool
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'

$missing = @(
    'NRCAN_SIGN_VAULT_URL'
    'NRCAN_SIGN_CERT'
    'NRCAN_SIGN_CLIENT_ID'
    'NRCAN_SIGN_CLIENT_SECRET'
    'NRCAN_SIGN_TENANT_ID'
    'NRCAN_SIGN_TIMESTAMP_URL'
) | Where-Object { -not (Test-Path "env:$_") }
if ($missing) {
    Write-Host "Not signing ${Path}: missing $($missing -join ', ')"
    exit 0
}

$signArgs = @(
    'sign'
    '-kvu', $env:NRCAN_SIGN_VAULT_URL
    '-kvc', $env:NRCAN_SIGN_CERT
    '-kvi', $env:NRCAN_SIGN_CLIENT_ID
    '-kvs', $env:NRCAN_SIGN_CLIENT_SECRET
    '-kvt', $env:NRCAN_SIGN_TENANT_ID
    '-tr', $env:NRCAN_SIGN_TIMESTAMP_URL
    '-d', 'TRNRun'
    '-du', 'https://github.com/NRCan/TRNRun'
    '-fd', 'sha256'
    '-td', 'sha256'
)
azuresigntool @signArgs $Path
if ($LASTEXITCODE -ne 0) {
    throw "AzureSignTool failed with exit code $LASTEXITCODE"
}
