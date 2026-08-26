import std/[times, unittest]

import ../src/[events, settings]


proc fixedTimestamp(): DateTime =
  dateTime(2026, mJun, 19, 19, 37, 13, 0, utc())


suite "runner settings":
  test "defines the documented defaults":
    check DefaultRunnerSettings == RunnerSettings(
      trnexePath: r"C:\TRNSYS18\Exe\TrnEXE64.exe",
      guiVisibility: guiHidden,
      waitForGui: true,
      waitForLst: true,
      waitForTmp: false,
      detectTimeoutMs: 300_000,
      extraDelayMs: 0,
      watchLog: true,
      watchTmp: false,
      watchTimeoutMs: 0,
      stallTimeoutMs: 0,
      pollMs: 100,
      cleanOnSuccess: false,
      killOnTimeout: false,
      killOnStall: false,
      severity: Notice,
      writeEvents: false,
    )

  test "clamps negative timing values and polling to valid minimums":
    var settings = DefaultRunnerSettings
    settings.detectTimeoutMs = -10
    settings.extraDelayMs = -20
    settings.pollMs = -30
    settings.watchTimeoutMs = -40
    settings.stallTimeoutMs = -50

    let effective = settings.normalized()

    check effective.detectTimeoutMs == 0
    check effective.extraDelayMs == 0
    check effective.pollMs == 1
    check effective.watchTimeoutMs == 0
    check effective.stallTimeoutMs == 0

  test "raises positive timeout thresholds to the polling interval":
    var settings = DefaultRunnerSettings
    settings.pollMs = 250
    settings.watchTimeoutMs = 1
    settings.stallTimeoutMs = 249

    let effective = settings.normalized()

    check effective.pollMs == 250
    check effective.watchTimeoutMs == 250
    check effective.stallTimeoutMs == 250

  test "preserves disabled and sufficiently large timeout thresholds":
    var settings = DefaultRunnerSettings
    settings.pollMs = 100
    settings.watchTimeoutMs = 0
    settings.stallTimeoutMs = 500

    let effective = settings.normalized()

    check effective.watchTimeoutMs == 0
    check effective.stallTimeoutMs == 500

  test "normalization preserves the input and unrelated settings":
    var settings = DefaultRunnerSettings
    settings.trnexePath = r"D:\TRNSYS\TrnEXE64.exe"
    settings.guiVisibility = guiMinimizedAuto
    settings.waitForGui = false
    settings.watchLog = false
    settings.cleanOnSuccess = true
    settings.killOnTimeout = true
    settings.severity = Fatal
    settings.writeEvents = true
    settings.detectTimeoutMs = -1

    let effective = settings.normalized()

    check settings.detectTimeoutMs == -1
    check effective.detectTimeoutMs == 0
    check effective.trnexePath == settings.trnexePath
    check effective.guiVisibility == settings.guiVisibility
    check effective.waitForGui == settings.waitForGui
    check effective.watchLog == settings.watchLog
    check effective.cleanOnSuccess == settings.cleanOnSuccess
    check effective.killOnTimeout == settings.killOnTimeout
    check effective.severity == settings.severity
    check effective.writeEvents == settings.writeEvents

  test "maps every GUI visibility mode to its wire value and behavior":
    let cases = [
      (
        visibility: guiKeepOpen,
        wireValue: "keepOpen",
        switch: "",
        minimize: false,
      ),
      (
        visibility: guiAutoClose,
        wireValue: "autoClose",
        switch: "/n",
        minimize: false,
      ),
      (
        visibility: guiMinimized,
        wireValue: "minimized",
        switch: "",
        minimize: true,
      ),
      (
        visibility: guiMinimizedAuto,
        wireValue: "minimizedAuto",
        switch: "/n",
        minimize: true,
      ),
      (
        visibility: guiHidden,
        wireValue: "hidden",
        switch: "/h",
        minimize: false,
      ),
    ]

    for testCase in cases:
      checkpoint("visibility: " & testCase.wireValue)
      check $testCase.visibility == testCase.wireValue
      check testCase.visibility.flag() == testCase.switch
      check testCase.visibility.wantsMinimize() == testCase.minimize

  test "converts every setting to a setting event":
    let settings = RunnerSettings(
      trnexePath: "configured-path-is-not-emitted.exe",
      guiVisibility: guiMinimizedAuto,
      waitForGui: false,
      waitForLst: true,
      waitForTmp: true,
      detectTimeoutMs: 123_456,
      extraDelayMs: 25,
      watchLog: false,
      watchTmp: true,
      watchTimeoutMs: 60_000,
      stallTimeoutMs: 30_000,
      pollMs: 50,
      cleanOnSuccess: true,
      killOnTimeout: true,
      killOnStall: true,
      severity: Warning,
      writeEvents: true,
    )

    let event = settings.settingEvent(
      r"C:\Resolved\TrnEXE64.exe",
      fixedTimestamp(),
    )

    check event.kind == eventSetting
    check event.settingData == SettingEvent(
      timestamp: fixedTimestamp(),
      trnexePath: r"C:\Resolved\TrnEXE64.exe",
      guiVisibility: "minimizedAuto",
      waitForGui: false,
      waitForLst: true,
      waitForTmp: true,
      detectTimeoutMs: 123_456,
      extraDelayMs: 25,
      watchLog: false,
      watchTmp: true,
      watchTimeoutMs: 60_000,
      stallTimeoutMs: 30_000,
      pollMs: 50,
      cleanOnSuccess: true,
      killOnTimeout: true,
      killOnStall: true,
      severity: Warning,
      writeEvents: true,
    )
