import std/[json, options, times, unittest]

import ../src/events


proc fixedTimestamp(): DateTime =
  dateTime(2026, mJun, 19, 19, 37, 13, 456_000_000, utc())

proc logEventWithSeverity(severity: LogSeverity): SimulationEvent =
  SimulationEvent(
    kind: eventLog,
    logData: LogEvent(
      timestamp: fixedTimestamp(),
      severity: severity,
      time: 0.0,
      unitId: none(int),
      typeId: none(int),
      messageCode: none(int),
      message: none(string),
      information: none(string),
    ),
  )


suite "simulation event JSON serialization":
  test "serializes a setting event":
    let event = SimulationEvent(
      kind: eventSetting,
      settingData: SettingEvent(
        timestamp: fixedTimestamp(),
        trnexePath: "C:\\TRNSYS18\\Exe\\TrnEXE64.exe",
        guiVisibility: "hidden",
        waitForGui: true,
        waitForLst: true,
        waitForTmp: false,
        detectTimeoutMs: 300_000,
        extraDelayMs: 25,
        watchLog: true,
        watchTmp: false,
        watchTimeoutMs: 60_000,
        stallTimeoutMs: 30_000,
        pollMs: 100,
        cleanOnSuccess: true,
        killOnTimeout: true,
        killOnStall: false,
        severity: Notice,
        writeEvents: true,
      ),
    )

    check event.toJson() == %*{
      "kind": "SETTING",
      "timestamp": "2026-06-19T19:37:13",
      "trnexePath": "C:\\TRNSYS18\\Exe\\TrnEXE64.exe",
      "guiVisibility": "hidden",
      "waitForGui": true,
      "waitForLst": true,
      "waitForTmp": false,
      "detectTimeoutMs": 300_000,
      "extraDelayMs": 25,
      "watchLog": true,
      "watchTmp": false,
      "watchTimeoutMs": 60_000,
      "stallTimeoutMs": 30_000,
      "pollMs": 100,
      "cleanOnSuccess": true,
      "killOnTimeout": true,
      "killOnStall": false,
      "severity": "Notice",
      "writeEvents": true,
    }

  test "serializes every simulation status using its wire value":
    let cases = [
      (statusPending, "PENDING"),
      (statusLaunching, "LAUNCHING"),
      (statusRunning, "RUNNING"),
      (statusDone, "DONE"),
      (statusCancelled, "CANCELLED"),
      (statusError, "ERROR"),
      (statusTimeout, "TIMEOUT"),
      (statusStalled, "STALLED"),
    ]

    for (status, wireValue) in cases:
      let event = SimulationEvent(
        kind: eventStatus,
        statusData: StatusEvent(
          timestamp: fixedTimestamp(),
          status: status,
          message: "",
        ),
      )

      check event.toJson() == %*{
        "kind": "STATUS",
        "timestamp": "2026-06-19T19:37:13",
        "status": wireValue,
        "message": "",
      }

  test "serializes a status message when present":
    let event = SimulationEvent(
      kind: eventStatus,
      statusData: StatusEvent(
        timestamp: fixedTimestamp(),
        status: statusError,
        message: "Failed to launch TRNSYS",
      ),
    )

    check event.toJson() == %*{
      "kind": "STATUS",
      "timestamp": "2026-06-19T19:37:13",
      "status": "ERROR",
      "message": "Failed to launch TRNSYS",
    }

  test "serializes a config event without rounding values":
    let event = SimulationEvent(
      kind: eventConfig,
      configData: ConfigEvent(
        timestamp: fixedTimestamp(),
        start: -24.5,
        stop: 8760.0,
        step: 0.125,
      ),
    )

    check event.toJson() == %*{
      "kind": "CONFIG",
      "timestamp": "2026-06-19T19:37:13",
      "start": -24.5,
      "stop": 8760.0,
      "step": 0.125,
    }

  test "rounds progress values to their wire precision":
    let event = SimulationEvent(
      kind: eventProgress,
      progressData: ProgressEvent(
        timestamp: fixedTimestamp(),
        time: 12.346,
        percent: 0.123456,
        elapsedMs: 987.654,
        etaMs: 1234.567,
      ),
    )

    check event.toJson() == %*{
      "kind": "PROGRESS",
      "timestamp": "2026-06-19T19:37:13",
      "time": 12.35,
      "percent": 0.1235,
      "elapsed": 987.65,
      "eta": 1234.57,
    }

  test "serializes a log event with every optional field":
    let event = SimulationEvent(
      kind: eventLog,
      logData: LogEvent(
        timestamp: fixedTimestamp(),
        severity: Warning,
        time: 24.126,
        unitId: some(5),
        typeId: some(139),
        messageCode: some(101),
        message: some("Example warning"),
        information: some("Example details"),
      ),
    )

    check event.toJson() == %*{
      "kind": "LOG",
      "timestamp": "2026-06-19T19:37:13",
      "severity": "Warning",
      "time": 24.13,
      "unitID": 5,
      "typeID": 139,
      "messageCode": 101,
      "message": "Example warning",
      "information": "Example details",
    }

  test "omits absent log fields instead of emitting null values":
    check logEventWithSeverity(Notice).toJson() == %*{
      "kind": "LOG",
      "timestamp": "2026-06-19T19:37:13",
      "severity": "Notice",
      "time": 0.0,
    }

  test "serializes every log severity using its wire value":
    let cases = [
      (Notice, "Notice"),
      (Warning, "Warning"),
      (Fatal, "Fatal"),
    ]

    for (severity, wireValue) in cases:
      let node = logEventWithSeverity(severity).toJson()
      check node["severity"].getStr() == wireValue

  test "leaves delivery sequence metadata to event sinks":
    let node = SimulationEvent(
      kind: eventStatus,
      statusData: StatusEvent(
        timestamp: fixedTimestamp(),
        status: statusRunning,
        message: "",
      ),
    ).toJson()

    check not node.hasKey("seq")
