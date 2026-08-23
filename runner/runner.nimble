import std/strutils

# Package
version = "0.4.0"
author = "Alex Lachance"
description = "Process wrapper for TRNSYS TrnEXE with simulation monitoring and status reporting"
license = "../LICENSE"
srcDir = "src"
bin = @["trnrun"]

# Dependencies
requires "nim >= 2.2.10"

# Build configuration
const
  exeName = "trnrun"
  buildDir = "build"
  cacheDir = buildDir & "/nimcache"
  target = "x86_64-windows-gnu"
  zigcc = "scripts/zigcc.bat"

# Build
proc compileExe() =
  let
    output = buildDir & "/" & exeName & ".exe"
    source = srcDir & "/runner.nim"

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

# Tasks
task zigbuild, "Build with Zig cc":
  compileExe()
