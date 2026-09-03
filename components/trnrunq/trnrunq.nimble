import std/strutils

# Package
version = "0.5.0"
author = "Alex Lachance"
description = "Bounded concurrent launcher for TRNRun simulations"
license = "MIT"
srcDir = "src"

# Dependencies
requires "nim >= 2.2.10"

# Build configuration
const
  exeName = "trnrunq"
  buildDir = "build"
  cacheDir = buildDir & "/nimcache"
  distDir = "dist"
  pythonBinDir = "../../libraries/python/trnrun/bin"
  target = "x86_64-windows-gnu"
  zigcc = "scripts/zigcc.bat"

# Build
proc compileExe() =
  let
    output = buildDir & "/" & exeName & ".exe"
    source = srcDir & "/trnrunq.nim"

  if not fileExists(zigcc):
    quit("Missing zig cc wrapper: " & zigcc)

  mkDir buildDir

  var args: seq[string]
  args.add "nim c"
  args.add "--verbosity:3"
  args.add "--cc:clang"
  args.add "--clang.exe:" & zigcc
  args.add "--clang.linkerexe:" & zigcc
  args.add "--passC:--target=" & target
  args.add "--passL:--target=" & target
  args.add "--passL:-s"
  args.add "-d:NimblePkgVersion=" & version
  args.add "--nimcache:" & cacheDir
  args.add "--out:" & output
  args.add "--os:windows"
  args.add "--cpu:amd64"
  args.add "-d:release"
  args.add "--opt:speed"
  args.add source

  exec args.join(" ")

# Distribution
proc assemblePackage() =
  let
    packageDir = distDir & "/" & exeName & "-v" & version & "-win_amd64"
    builtExe = buildDir & "/" & exeName & ".exe"

  if not fileExists(builtExe):
    quit("Missing built executable: " & builtExe)

  mkDir packageDir

  cpFile(builtExe, packageDir & "/" & exeName & ".exe")
  cpFile("README.md", packageDir & "/README.md")
  cpFile("../../LICENSE", packageDir & "/LICENSE")

proc assembleDistribution() =
  if dirExists(distDir):
    rmDir distDir

  assemblePackage()

proc deployPackage() =
  mkDir pythonBinDir

  cpFile(
    distDir & "/" & exeName & "-v" & version & "-win_amd64/" & exeName & ".exe",
    pythonBinDir & "/" & exeName & ".exe",
  )

# Tasks
task bin, "Build the release executable":
  compileExe()

task dist, "Build and assemble the distribution":
  compileExe()
  assembleDistribution()

task deploy, "Build, assemble, and deploy to the manager":
  compileExe()
  assembleDistribution()
  deployPackage()
