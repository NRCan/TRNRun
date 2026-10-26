set shell := ["powershell.exe", "-c"]

# List available recipes
default:
    @just --list

# Set the version of every component and library, such as `just version 0.9.0`
version new:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Set-Version.ps1 {{new}}

# Build every component
bin:
    just trnrun-bin
    just trnrund-bin
    just type3830-bin

# Assemble every component distribution
dist:
    just trnrun-dist
    just trnrund-dist
    just type3830-dist
    just python-dist
    just matlab-dist
    just dotnet-dist

# Run every component test suite
test:
    just trnrun-test
    just trnrund-test
    # just type3830-test
    just python-test
    # just matlab-test
    just dotnet-test

# Build all artifacts and assemble the root distribution
deploy:
    Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue; New-Item dist -ItemType Directory -Force | Out-Null
    just type3830-deploy
    just trnrun-deploy
    just trnrund-deploy
    just python-dist
    # just matlab-dist
    just dotnet-dist
    Copy-Item components/type3830/dist/* dist -Recurse -Force
    Copy-Item components/trnrun/dist/* dist -Recurse -Force
    Copy-Item components/trnrund/dist/* dist -Recurse -Force
    # Copy-Item libraries/matlab/dist/*.mltbx dist -Force
    Get-ChildItem dist -Directory | ForEach-Object { Compress-Archive -Path (Join-Path $_.FullName '*') -DestinationPath (Join-Path dist "$($_.Name).zip") -Force }

# Build and package the native, Python, and .NET clients
clients-ci-prepare:
    Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue; New-Item dist -ItemType Directory -Force | Out-Null
    just trnrun-deploy
    just trnrund-deploy
    just python-dist
    just dotnet-dist

# Test the native, Python, and .NET clients; run after clients-ci-prepare, which deploys the executables they use
clients-ci-test:
    just trnrun-test
    just trnrund-test
    just python-test
    just dotnet-test

# Assemble the client distributions after MATLAB packaging
clients-ci-assemble:
    Copy-Item components/trnrun/dist/* dist -Recurse -Force
    Copy-Item components/trnrund/dist/* dist -Recurse -Force
    Copy-Item libraries/matlab/dist/*.mltbx dist -Force
    Get-ChildItem dist -Directory | ForEach-Object { Compress-Archive -Path (Join-Path $_.FullName '*') -DestinationPath (Join-Path dist "$($_.Name).zip") -Force }

# Package the MATLAB toolbox
matlab-dist:
    Set-Location libraries/matlab -ErrorAction Stop; matlab -batch "buildtool clean package"

# Run the MATLAB test suite
matlab-test:
    Set-Location libraries/matlab -ErrorAction Stop; matlab -batch "buildtool test"

# Pack the .NET NuGet and symbol packages; links trnrun.exe and trnrund.exe from their build directories
dotnet-dist:
    Set-Location libraries/dotnet -ErrorAction Stop; dotnet pack src/TRNRun/TRNRun.csproj --configuration Release --output ../../dist

# Run the .NET test suite
dotnet-test:
    Set-Location libraries/dotnet -ErrorAction Stop; dotnet test TRNRun.slnx

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

# Build the TRNRunD release executable
trnrund-bin:
    Set-Location components/trnrund -ErrorAction Stop; nimble bin

# Assemble the TRNRunD distribution
trnrund-dist:
    Set-Location components/trnrund -ErrorAction Stop; nimble dist

# Build, assemble, and deploy TRNRunD to the Python package
trnrund-deploy:
    Set-Location components/trnrund -ErrorAction Stop; nimble deploy

# Run the TRNRunD tests against a fake TRNRun
trnrund-test:
    Set-Location components/trnrund -ErrorAction Stop; nimble test

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
