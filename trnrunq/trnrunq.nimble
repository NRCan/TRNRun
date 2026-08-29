import std/strutils

version = "0.1.0"
author = "Alex Lachance"
description = "Concurrent process supervisor for TRNRun simulations"
license = "MIT"
srcDir = "src"

requires "nim >= 2.2.10"

const
  exeName = "trnrunq"
  buildDir = "build"
  cacheDir = buildDir & "/nimcache"
  distDir = "dist"
  target = "x86_64-windows-gnu"
  zigcc = "scripts/zigcc.bat"
  runnerExe = "../runner/build/trnrun.exe"

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
  args.add "--threads:on"
  args.add "-d:release"
  args.add "--opt:speed"
  args.add source

  exec args.join(" ")

proc assembleDistribution() =
  echo "Assembling trnrunq distribution"
  let
    packageDir = distDir & "/" & exeName & "-v" & version & "-win_amd64"
    builtExe = buildDir & "/" & exeName & ".exe"

  if not fileExists(builtExe):
    quit("Missing built executable: " & builtExe)
  if not fileExists(runnerExe):
    quit("Missing runner executable: " & runnerExe & " (build runner first)")

  if dirExists(distDir):
    rmDir distDir
  mkDir distDir
  mkDir packageDir
  cpFile(builtExe, packageDir & "/" & exeName & ".exe")
  cpFile(runnerExe, packageDir & "/trnrun.exe")
  cpFile("README.md", packageDir & "/README.md")
  cpFile("../LICENSE", packageDir & "/LICENSE")
  echo "Assembled " & packageDir

task bin, "Build the release executable":
  compileExe()

task dist, "Build and assemble the distribution":
  compileExe()
  assembleDistribution()

task deploy, "Build and assemble the distribution":
  compileExe()
  assembleDistribution()
