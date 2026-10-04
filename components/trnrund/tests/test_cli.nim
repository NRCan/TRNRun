import std/[cpuinfo, os, unittest]
import ../src/cli

suite "CliInput":
  test "defaults use the executable directory and reserve one processor":
    let input = defaultCliInput()
    check input.trnrunPath == getAppDir() / "trnrun.exe"
    check input.maxConcurrent == max(countProcessors() - 1, 1)

  test "trnrun stores the supplied path without validation":
    var input = CliInput(trnrunPath: "original.exe", maxConcurrent: 3)
    for path in ["relative path/trnrun.exe", ""]:
      check input.applyOption("trnrun", path)
      check input.trnrunPath == path
      check input.maxConcurrent == 3

  test "maxConcurrent parses integers and leaves range validation to startup":
    var input = CliInput(trnrunPath: "original.exe", maxConcurrent: 3)
    for value in [1, 8, 0, -1]:
      check input.applyOption("maxConcurrent", $value)
      check input.maxConcurrent == value
      check input.trnrunPath == "original.exe"

  test "unknown option keys leave input unchanged":
    let original = CliInput(trnrunPath: "original.exe", maxConcurrent: 3)
    var input = original
    for key in ["", "unknown", "maxconcurrent", "help"]:
      check not input.applyOption(key, "8")
      check input == original

  test "invalid integers raise without changing input":
    let original = CliInput(trnrunPath: "original.exe", maxConcurrent: 3)
    var input = original
    for value in ["", "abc", "1.5", "2workers", "999999999999999999999999999999"]:
      expect ValueError:
        discard input.applyOption("maxConcurrent", value)
      check input == original

  test "repeated options use the last supplied value":
    var input = defaultCliInput()
    check input.applyOption("trnrun", "first.exe")
    check input.applyOption("trnrun", "last.exe")
    check input.applyOption("maxConcurrent", "2")
    check input.applyOption("maxConcurrent", "4")
    check input.trnrunPath == "last.exe"
    check input.maxConcurrent == 4
