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
    for key in ["doesNotExist", "maxconcurrent", "help", "overwrite", "database", "maxLogsPerRun"]:
      checkpoint("option: " & key)
      var input = defaultCliInput()
      check not input.applyOption(key, "value")
      check input == defaultCliInput()

  test "raises InputError for invalid known option values":
    var input = defaultCliInput()

    expect InputError:
      discard input.applyOption("maxConcurrent", "many")
    expect InputError:
      discard input.applyOption("maxConcurrent", "")

suite "command line":
  test "serves with the defaults when given no arguments":
    check parseCommandLine([]) == CliCommand(action: caServe, input: defaultCliInput())

  test "serves with every option applied":
    var expected = defaultCliInput()
    expected.trnrunPath = "trnrun.exe"
    expected.maxConcurrent = 3
    check parseCommandLine(["--maxConcurrent:3", "--trnrun=trnrun.exe"]) ==
      CliCommand(action: caServe, input: expected)

  test "stops at the first help or version option":
    for (args, action) in [
      (@["-h"], caHelp), (@["--help"], caHelp), (@["-v"], caVersion), (@["--version"], caVersion),
      (@["--help", "--doesNotExist"], caHelp), (@["--version", "extra"], caVersion),
    ]:
      checkpoint($args)
      check parseCommandLine(args).action == action

  test "raises InputError for unknown options, arguments, and bad values":
    for (args, expected) in [
      (@["--doesNotExist"], "Unknown option: --doesNotExist"),
      (@["-x"], "Unknown option: -x"),
      (@["extra"], "Unexpected argument: extra"),
      (@["--maxConcurrent:many", "--help"], "invalid integer: many"),
    ]:
      checkpoint($args)
      try:
        discard parseCommandLine(args)
        fail()
      except InputError as error:
        check error.msg == expected
