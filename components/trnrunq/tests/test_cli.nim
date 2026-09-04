import std/[cpuinfo, unittest]

import ../src/cli


suite "queue command-line input":
  test "defaults to one fewer worker than available processors":
    let input = defaultCliInput()

    check input.maxConcurrent == max(countProcessors() - 1, 1)

  test "applies the maximum concurrency option":
    var input = CliInput(maxConcurrent: 1)

    check input.applyOption("maxConcurrent", "12")
    check input.maxConcurrent == 12

  test "rejects unknown options without changing the input":
    var input = CliInput(maxConcurrent: 4)

    check not input.applyOption("workers", "8")
    check input.maxConcurrent == 4

  test "raises ValueError for a non-integer maximum concurrency":
    var input = CliInput(maxConcurrent: 4)

    expect ValueError:
      discard input.applyOption("maxConcurrent", "many")

    check input.maxConcurrent == 4
