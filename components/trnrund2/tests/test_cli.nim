import std/[cpuinfo, os, unittest]

import ../src/cli

suite "command line":
  test "defaults to trnrun.exe beside the daemon and one worker per spare CPU":
    let command = parseCommandLine([])
    check command.action == caServe
    check command.input.trnrunPath == getAppDir() / "trnrun.exe"
    check command.input.workers == max(countProcessors() - 1, 1)

  test "reads --trnrun and --workers":
    let command = parseCommandLine(["--trnrun:C:/tools/trnrun.exe", "--workers:3"])
    check command.action == caServe
    check command.input == CliInput(trnrunPath: "C:/tools/trnrun.exe", workers: 3)

  test "help and version win over the other options":
    check parseCommandLine(["--workers:3", "-h"]).action == caHelp
    check parseCommandLine(["--help", "--bogus"]).action == caHelp
    check parseCommandLine(["-v"]).action == caVersion
    check parseCommandLine(["--version", "--workers:3"]).input == defaultCliInput()

  test "rejects unknown options, arguments and bad workers":
    for args in [
      @["--bogus"],
      @["-x"],
      @["extra"],
      @["--workers:0"],
      @["--workers:x"],
    ]:
      expect InputError:
        discard parseCommandLine(args)
