import std/[cpuinfo, os, unittest]

import ../src/cli


suite "CLI options":
  test "defaults to the TRNRun beside trnrund and one worker per CPU but one":
    check defaultCliInput() == CliInput(
      trnrunPath: getAppDir() / "trnrun.exe",
      maxConcurrent: max(countProcessors() - 1, 1),
    )

  test "applies every documented option":
    var input = defaultCliInput()

    check input.applyOption("trnrun", r"D:\Tools\trnrun.exe")
    check input.applyOption("maxConcurrent", "3")

    check input == CliInput(trnrunPath: r"D:\Tools\trnrun.exe", maxConcurrent: 3)

  test "returns false for an unknown option without changing input":
    for key in ["doesNotExist", "maxconcurrent", "help"]:
      checkpoint("option: " & key)
      var input = defaultCliInput()
      check not input.applyOption(key, "value")
      check input == defaultCliInput()

  test "raises ValueError for invalid known option values":
    var input = defaultCliInput()

    expect ValueError:
      discard input.applyOption("maxConcurrent", "many")
