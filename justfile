set shell := ["powershell.exe", "-c"]

# List available recipes
default:
    @just --list

# Build every component
bin:
    just trnrun-bin
    just trnrunq-bin
    just type3830-bin

# Assemble every component distribution
dist:
    just trnrun-dist
    just trnrunq-dist
    just type3830-dist
    just python-dist

# Run every component test suite
test:
    just trnrun-test
    just trnrunq-test
    just type3830-test
    just python-test

# Build all artifacts and assemble the root distribution
deploy:
    Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue; New-Item dist -ItemType Directory -Force | Out-Null
    just type3830-deploy
    just trnrun-deploy
    just trnrunq-deploy
    just python-dist
    Copy-Item components/type3830/dist/* dist -Recurse -Force
    Copy-Item components/trnrun/dist/* dist -Recurse -Force
    Copy-Item components/trnrunq/dist/* dist -Recurse -Force
    Get-ChildItem dist -Directory | ForEach-Object { Compress-Archive -Path $_.FullName -DestinationPath (Join-Path dist "$($_.Name).zip") -Force }

# Build the Python wheel
python-dist:
    Set-Location libraries/python -ErrorAction Stop; uv build --wheel --out-dir ../../dist

# Run the Python test suite
python-test:
    Set-Location libraries/python -ErrorAction Stop; uv run pytest

# Build the TRNRun release executable
trnrun-bin:
    Set-Location components/trnrun -ErrorAction Stop; nimble bin

# Assemble the TRNRun distribution
trnrun-dist:
    Set-Location components/trnrun -ErrorAction Stop; nimble dist

# Build, assemble, and deploy TRNRun to the Python package
trnrun-deploy:
    Set-Location components/trnrun -ErrorAction Stop; nimble deploy

# Build TRNRun and run its tests
trnrun-test: trnrun-bin
    Set-Location components/trnrun -ErrorAction Stop; nimble test

# Build the TRNRunQ release executable
trnrunq-bin:
    Set-Location components/trnrunq -ErrorAction Stop; nimble bin

# Assemble the TRNRunQ distribution
trnrunq-dist:
    Set-Location components/trnrunq -ErrorAction Stop; nimble dist

# Build, assemble, and deploy TRNRunQ to the Python package
trnrunq-deploy:
    Set-Location components/trnrunq -ErrorAction Stop; nimble deploy

# Deploy TRNRun and run the TRNRunQ tests
trnrunq-test:
    Set-Location components/trnrunq -ErrorAction Stop; nimble test

# Build all Type3830 DLLs
type3830-bin:
    Set-Location components/type3830 -ErrorAction Stop; nimble bin

# Assemble the Type3830 distributions
type3830-dist:
    Set-Location components/type3830 -ErrorAction Stop; nimble dist

# Build and deploy Type3830 to installed TRNSYS versions
type3830-deploy:
    Set-Location components/type3830 -ErrorAction Stop; nimble deploy

# Build TRNRun and run the Type3830 integration tests
type3830-test:
    Set-Location components/type3830 -ErrorAction Stop; nimble test

# Build the 64-bit release Type3830 DLL
type3830-release64:
    Set-Location components/type3830 -ErrorAction Stop; nimble release64

# Build the 64-bit debug Type3830 DLL
type3830-debug64:
    Set-Location components/type3830 -ErrorAction Stop; nimble debug64

# Build the 32-bit release Type3830 DLL
type3830-release32:
    Set-Location components/type3830 -ErrorAction Stop; nimble release32

# Build the 32-bit debug Type3830 DLL
type3830-debug32:
    Set-Location components/type3830 -ErrorAction Stop; nimble debug32
