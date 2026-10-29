set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]

# List available recipes
default:
    @just --list

# Set the version of every component and library, such as `just version 0.9.0`
version new:
    ./scripts/Set-Version.ps1 {{new}}

# Build every component
bin: \
    trnrun-bin \
    trnrund-bin \
    type3830-bin

# Run every component test suite
test: \
    trnrun-test \
    trnrund-test \
    python-test \
    dotnet-test \
    type3830-test \
    matlab-test

# Build all artifacts and assemble the root distribution
deploy: \
    clean \
    type3830-deploy \
    trnrun-deploy \
    trnrund-deploy \
    python-dist \
    dotnet-dist \
    matlab-dist \
    assemble

# Recreate an empty root dist directory
clean:
    Remove-Item dist -Recurse -Force -ErrorAction SilentlyContinue; New-Item dist -ItemType Directory | Out-Null

# Copy the component distributions and MATLAB toolbox into dist and zip each component
assemble:
    Copy-Item components/*/dist/* dist -Recurse -Force
    Copy-Item libraries/matlab/dist/*.mltbx dist -Force
    Get-ChildItem dist -Directory | ForEach-Object { Compress-Archive -Path (Join-Path $_.FullName '*') -DestinationPath (Join-Path dist "$($_.Name).zip") -Force }

# Run any nimble task in a component, such as `just nimble type3830 debug64`
nimble component task:
    Set-Location components/{{component}} -ErrorAction Stop; nimble {{task}}

# Package the MATLAB toolbox
[group('matlab')]
[working-directory('libraries/matlab')]
matlab-dist:
    matlab -batch "buildtool clean package"

# Run the MATLAB test suite
[group('matlab')]
[working-directory('libraries/matlab')]
matlab-test:
    matlab -batch "buildtool test"

# Pack the .NET NuGet package; links trnrun.exe and trnrund.exe from their build directories
[group('dotnet')]
[working-directory('libraries/dotnet')]
dotnet-dist:
    dotnet pack src/TRNRun/TRNRun.csproj --configuration Release --output ../../dist

# Run the .NET test suite
[group('dotnet')]
[working-directory('libraries/dotnet')]
dotnet-test:
    dotnet test TRNRun.slnx --logger "trx;LogFileName=dotnet.trx" --results-directory ../../TestResults

# Build the Python wheel
[group('python')]
[working-directory('libraries/python')]
python-dist:
    uv build --wheel --out-dir ../../dist

# Run the Python test suite
[group('python')]
[working-directory('libraries/python')]
python-test:
    uv run pytest --junitxml=../../TestResults/python.xml

# Build the TRNRun release executable
[group('trnrun')]
[working-directory('components/trnrun')]
trnrun-bin:
    nimble bin

# Assemble the TRNRun distribution
[group('trnrun')]
[working-directory('components/trnrun')]
trnrun-dist:
    nimble dist

# Build, assemble, and deploy TRNRun to the Python and MATLAB packages
[group('trnrun')]
[working-directory('components/trnrun')]
trnrun-deploy:
    nimble deploy

# Build TRNRun and run its tests
[group('trnrun')]
[working-directory('components/trnrun')]
trnrun-test: trnrun-bin
    nimble test

# Build the TRNRunD release executable
[group('trnrund')]
[working-directory('components/trnrund')]
trnrund-bin:
    nimble bin

# Assemble the TRNRunD distribution
[group('trnrund')]
[working-directory('components/trnrund')]
trnrund-dist:
    nimble dist

# Build, assemble, and deploy TRNRunD to the Python and MATLAB packages
[group('trnrund')]
[working-directory('components/trnrund')]
trnrund-deploy:
    nimble deploy

# Run the TRNRunD tests against a fake TRNRun
[group('trnrund')]
[working-directory('components/trnrund')]
trnrund-test:
    nimble test

# Build all Type3830 DLLs
[group('type3830')]
[working-directory('components/type3830')]
type3830-bin:
    nimble bin

# Assemble the Type3830 distributions
[group('type3830')]
[working-directory('components/type3830')]
type3830-dist:
    nimble dist

# Build and deploy Type3830 to installed TRNSYS versions
[group('type3830')]
[working-directory('components/type3830')]
type3830-deploy:
    nimble deploy

# Build TRNRun and run the Type3830 integration tests
[group('type3830')]
[working-directory('components/type3830')]
type3830-test:
    nimble test
