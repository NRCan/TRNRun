# Package

version       = "0.3.0"
author        = "Alex Lachance"
description   = "Process wrapper for TRNSYS TRNEXE with simulation monitoring and status reporting"
license       = "MIT"
srcDir        = "src"
bin           = @["trnrun"]

# Dependencies

requires "nim >= 2.2.2"

# Tasks
const zigcc = "scripts/zigcc.bat"

task zigbuild, "Build with zigcc":
  exec "nim c " &
       "--cc:clang " &
       "--clang.exe:" & zigcc & " " &
       "--clang.linkerexe:" & zigcc & " " &
       "--passC:\"-target x86_64-windows-gnu\" " &
       "--passL:\"-target x86_64-windows-gnu\" " &
       "--passL:-s " &
       "-d:NimblePkgVersion=" & version & " " &
       "--nimcache:build/nimcache " &
       "--out:build/trnrun.exe " &
       "--os:windows --cpu:amd64 " &
       "-d:release --opt:speed " &
       "src/trnrun.nim"
