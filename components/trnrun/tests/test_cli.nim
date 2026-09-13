import std/unittest

import ../src/[cli, events, settings]


suite "CLI options":
  test "defines empty input with default runner settings":
    check DefaultCliInput == CliInput(
      deckFile: "",
      runID: "",
      settings: DefaultRunnerSettings,
    )

  test "applies every documented option":
    var input = DefaultCliInput

    check input.applyOption("deckFile", "model.dck")
    check input.applyOption("runID", "run-42")
    check input.applyOption("trnexePath", r"D:\TRNSYS\TrnEXE64.exe")
    check input.applyOption("guiVisibility", "minimizedauto")
    check input.applyOption("waitForGui", "false")
    check input.applyOption("waitForLst", "false")
    check input.applyOption("waitForTmp", "true")
    check input.applyOption("detectTimeout", "1234")
    check input.applyOption("extraDelay", "25")
    check input.applyOption("watchLog", "false")
    check input.applyOption("watchTmp", "true")
    check input.applyOption("watchTimeout", "5000")
    check input.applyOption("stallTimeout", "3000")
    check input.applyOption("pollMs", "50")
    check input.applyOption("clean", "true")
    check input.applyOption("killOnTimeout", "true")
    check input.applyOption("killOnStall", "true")
    check input.applyOption("severity", "Warning")
    check input.applyOption("writeEvents", "true")

    check input == CliInput(
      deckFile: "model.dck",
      runID: "run-42",
      settings: RunnerSettings(
        trnexePath: r"D:\TRNSYS\TrnEXE64.exe",
        guiVisibility: guiMinimizedAuto,
        waitForGui: false,
        waitForLst: false,
        waitForTmp: true,
        detectTimeoutMs: 1234,
        extraDelayMs: 25,
        watchLog: false,
        watchTmp: true,
        watchTimeoutMs: 5000,
        stallTimeoutMs: 3000,
        pollMs: 50,
        cleanOnSuccess: true,
        killOnTimeout: true,
        killOnStall: true,
        severity: Warning,
        writeEvents: true,
      ),
    )

  test "accepts every GUI visibility spelling case-insensitively":
    let cases = [
      (value: "keep", expected: guiKeepOpen),
      (value: "KEEPOPEN", expected: guiKeepOpen),
      (value: "auto", expected: guiAutoClose),
      (value: "AUTOCLOSE", expected: guiAutoClose),
      (value: "min", expected: guiMinimized),
      (value: "MINIMIZED", expected: guiMinimized),
      (value: "minauto", expected: guiMinimizedAuto),
      (value: "MINIMIZEDAUTO", expected: guiMinimizedAuto),
      (value: "HIDDEN", expected: guiHidden),
    ]

    for testCase in cases:
      checkpoint("GUI visibility: " & testCase.value)
      var input = DefaultCliInput
      check input.applyOption("guiVisibility", testCase.value)
      check input.settings.guiVisibility == testCase.expected

  test "returns false for an unknown option without changing input":
    var input = DefaultCliInput

    check not input.applyOption("doesNotExist", "value")
    check input == DefaultCliInput

  test "raises ValueError for invalid known option values":
    var input = DefaultCliInput

    expect ValueError:
      discard input.applyOption("guiVisibility", "visible")
    expect ValueError:
      discard input.applyOption("watchLog", "maybe")
    expect ValueError:
      discard input.applyOption("pollMs", "not-a-number")
    expect ValueError:
      discard input.applyOption("severity", "Debug")
