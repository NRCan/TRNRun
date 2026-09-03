set shell := ["powershell.exe", "-c"]

deploy:
    Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue; New-Item dist -ItemType Directory -Force | Out-Null
    Set-Location components/type3830 -ErrorAction Stop; nimble deploy
    Set-Location components/trnrun -ErrorAction Stop; nimble deploy
    Set-Location components/trnrunq -ErrorAction Stop; nimble deploy
    Set-Location libraries/python -ErrorAction Stop; uv build --wheel --out-dir ../../dist
    Copy-Item components/type3830/dist/* dist -Recurse -Force
    Copy-Item components/trnrun/dist/* dist -Recurse -Force
    Copy-Item components/trnrunq/dist/* dist -Recurse -Force
    Get-ChildItem dist -Directory | ForEach-Object { Compress-Archive -Path $_.FullName -DestinationPath (Join-Path dist "$($_.Name).zip") -Force }
