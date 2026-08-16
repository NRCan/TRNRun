import std/strutils

# Package
version = "0.4.1"
author = "Alex Lachance, Natural Resources Canada"
description = "Custom TRNSYS Type to export simulation TIME, START, STOP and STEP at a set interval"
license = "MIT"
srcDir = "src"

# Dependencies
requires "nim >= 2.2.10"

# Config
type
  Arch = object
    cpu: string
    target: string
    trnLib: string
    installDir: string
    trnsysVersion: string
    tmfFile: string
    dllSuffix: string

  Mode = object
    name: string
    flags: seq[string]
    dirPrefix: string

const
  dllName = "type3830"
  dllExtension = ".dll"
  packageDllFile = dllName & dllExtension
  buildDir = "build"
  dllDir = buildDir & "/dll"
  cacheDir = buildDir & "/nimcache"
  distDir = "dist"
  proformaSourceDir = "proformas"
  proformaDir = "Studio/Proformas/Utility (NRCan)/Progress Tracker"
  packageBmpFile = "Type3830.bmp"
  packageTmfFile = "Type3830.tmf"
  zigcc = "scripts/zigcc.bat"

  arch64 = Arch(
    cpu: "amd64",
    target: "x86_64-windows-gnu",
    trnLib: "C:/TRNSYS18/Exe/TRNDll64.lib",
    installDir: "C:/TRNSYS18",
    trnsysVersion: "18",
    tmfFile: "Type3830_18.tmf",
    dllSuffix: "_win64",
  )

  arch32 = Arch(
    cpu: "i386",
    target: "x86-windows-gnu",
    trnLib: "C:/Trnsys17/Exe/TRNDll.lib",
    installDir: "C:/Trnsys17",
    trnsysVersion: "17",
    tmfFile: "Type3830_17.tmf",
    dllSuffix: "_win32",
  )

  releaseMode = Mode(
    name: "release",
    flags: @["-d:release", "--opt:speed"],
    dirPrefix: "ReleaseDLLs",
  )

  debugMode = Mode(
    name: "debug",
    flags: @["-d:debug", "--linedir:on"],
    dirPrefix: "DebugDLLs",
  )

# Build
proc compileDll(arch: Arch, mode: Mode) =
  let
    dir = dllDir & "/" & mode.dirPrefix
    output = dir & "/" & dllName & arch.dllSuffix & dllExtension
    source = srcDir & "/" & dllName & ".nim"
    cache = cacheDir & "/" & arch.cpu & "/" & mode.name

  if not fileExists(zigcc):
    quit("Missing zig cc wrapper: " & zigcc)
  if not fileExists(arch.trnLib):
    quit("Missing TRNSYS import library: " & arch.trnLib)

  mkDir dir

  var args: seq[string]
  args.add "nim c"
  args.add "--app:lib"
  args.add "--os:windows"
  args.add "--cpu:" & arch.cpu
  args.add "--cc:clang"
  args.add "--clang.exe:" & zigcc
  args.add "--clang.linkerexe:" & zigcc
  args.add "--passC:--target=" & arch.target
  args.add "--passL:--target=" & arch.target
  args.add "--passL:" & arch.trnLib
  args.add "--nimcache:" & cache
  args.add "--out:" & output
  args.add mode.flags
  args.add source

  exec args.join(" ")

proc compileAllDlls() =
  if dirExists(dllDir):
    rmDir dllDir

  compileDll(arch64, releaseMode)
  compileDll(arch64, debugMode)
  compileDll(arch32, releaseMode)
  compileDll(arch32, debugMode)

proc assemblePackage(arch: Arch) =
  let
    root = distDir & "/Type3830-TRNSYS" & arch.trnsysVersion & "-v" & version
    proformas = root & "/" & proformaDir
    debugDlls = root & "/UserLib/" & debugMode.dirPrefix
    releaseDlls = root & "/UserLib/" & releaseMode.dirPrefix
    builtDllFile = dllName & arch.dllSuffix & dllExtension

  mkDir proformas
  mkDir debugDlls
  mkDir releaseDlls

  cpFile(
    proformaSourceDir & "/" & packageBmpFile,
    proformas & "/" & packageBmpFile,
  )
  cpFile(
    proformaSourceDir & "/" & arch.tmfFile,
    proformas & "/" & packageTmfFile,
  )
  cpFile(
    dllDir & "/" & debugMode.dirPrefix & "/" & builtDllFile,
    debugDlls & "/" & packageDllFile,
  )
  cpFile(
    dllDir & "/" & releaseMode.dirPrefix & "/" & builtDllFile,
    releaseDlls & "/" & packageDllFile,
  )

proc assembleDistributions() =
  if dirExists(distDir):
    rmDir distDir

  assemblePackage(arch32)
  assemblePackage(arch64)

proc deployPackage(arch: Arch) =
  if not dirExists(arch.installDir):
    echo "Skipping TRNSYS ", arch.trnsysVersion, ": ", arch.installDir, " not found"
    return

  cpDir(
    distDir & "/Type3830-TRNSYS" & arch.trnsysVersion & "-v" & version,
    arch.installDir,
  )

# Tasks
task build, "Build all DLLs":
  compileAllDlls()

task dist, "Build all DLLs and distribution packages":
  compileAllDlls()
  assembleDistributions()

task deploy, "Build, deploy, and test installed TRNSYS versions":
  compileAllDlls()
  assembleDistributions()
  deployPackage(arch32)
  deployPackage(arch64)
  exec "nimble test"

task release64, "Build the 64-bit release DLL":
  compileDll(arch64, releaseMode)

task debug64, "Build the 64-bit debug DLL":
  compileDll(arch64, debugMode)

task release32, "Build the 32-bit release DLL":
  compileDll(arch32, releaseMode)

task debug32, "Build the 32-bit debug DLL":
  compileDll(arch32, debugMode)
