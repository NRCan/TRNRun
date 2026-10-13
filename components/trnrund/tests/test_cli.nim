import std/[cpuinfo, os, unittest]

import ../src/cli


suite "CLI options":
  test "defaults to the TRNRun beside trnrund, one worker per CPU but one, and a local database":
    check defaultCliInput() == CliInput(
      trnrunPath: getAppDir() / "trnrun.exe",
      maxConcurrent: max(countProcessors() - 1, 1),
      databasePath: "trnrund.sqlite3",
      overwrite: false,
    )

  test "applies every documented option":
    var input = defaultCliInput()

    check input.applyOption("trnrun", r"D:\Tools\trnrun.exe")
    check input.applyOption("maxConcurrent", "3")
    check input.applyOption("database", r"D:\Runs\my runs.sqlite3")
    check input.applyOption("overwrite", "true")

    check input == CliInput(
      trnrunPath: r"D:\Tools\trnrun.exe",
      maxConcurrent: 3,
      databasePath: r"D:\Runs\my runs.sqlite3",
      overwrite: true,
    )

  test "overwrite requires explicit true or false and can be disabled again":
    var input = defaultCliInput()
    check not input.overwrite
    check input.applyOption("overwrite", "true")
    check input.overwrite
    for value in ["", "yes", "1", "TRUE", "False", "false "]:
      checkpoint("overwrite: " & value)
      expect ValueError:
        discard input.applyOption("overwrite", value)
      check input.overwrite
    check input.applyOption("overwrite", "false")
    check not input.overwrite

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
    expect ValueError:
      discard input.applyOption("database", "")
