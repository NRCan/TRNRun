set shell := ["powershell.exe", "-c"]

deploy:
    Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue; New-Item dist -ItemType Directory -Force | Out-Null
    Set-Location type3830 -ErrorAction Stop; nimble deploy
    Set-Location trnrun -ErrorAction Stop; nimble deploy
    Set-Location manager -ErrorAction Stop; uv build --wheel --out-dir ../dist
    Copy-Item type3830/dist/* dist -Recurse -Force
    Copy-Item trnrun/dist/* dist -Recurse -Force
    Get-ChildItem dist -Directory | ForEach-Object { Compress-Archive -Path $_.FullName -DestinationPath (Join-Path dist "$($_.Name).zip") -Force }
