import std/[json, options, unittest]

import ../src/events


proc parseLine(line: string): SimulationEvent =
  parseSimulationEvent(parseJson(line))


suite "TRNRun event parsing":
  test "parses every event kind into its payload":
    let setting = SettingEvent(
      trnexePath: r"C:\TRNSYS18\Exe\TrnEXE64.exe",
      guiVisibility: "hidden",
      waitForGui: true,
      detectTimeoutMs: 300000,
      pollMs: 100,
      severity: Warning,
    )
    let settingNode = %setting
    settingNode["kind"] = %"SETTING"
    check parseSimulationEvent(settingNode).settingData == setting

    let status = parseLine("""{"kind":"STATUS","status":"DONE","message":"ok"}""")
    check status.kind == eventStatus
    check status.statusData == StatusEvent(status: statusDone, message: "ok")

    let config = parseLine("""{"kind":"CONFIG","start":0,"stop":8760,"step":0.25}""")
    check config.kind == eventConfig
    check config.configData == ConfigEvent(start: 0, stop: 8760, step: 0.25)

    let progress = parseLine(
      """{"kind":"PROGRESS","time":10,"percent":50,"elapsedMs":20,"etaMs":20}"""
    )
    check progress.kind == eventProgress
    check progress.progressData ==
      ProgressEvent(time: 10, percent: 50, elapsedMs: 20, etaMs: 20)

    let log = parseLine(
      """{"kind":"LOG","severity":"Fatal","time":1.5,"unitId":3,"typeId":56,""" &
      """"messageCode":100,"message":"Bad input","information":"Check unit 3"}"""
    )
    check log.kind == eventLog
    check log.logData == LogEvent(
      severity: Fatal,
      time: 1.5,
      unitId: some(3),
      typeId: some(56),
      messageCode: some(100),
      message: some("Bad input"),
      information: some("Check unit 3"),
    )

  test "ignores fields the types do not declare, such as timestamps":
    let status = parseLine(
      """{"kind":"STATUS","timestamp":"2026-06-19T19:37:13","runId":"run",""" &
      """"status":"RUNNING","message":""}"""
    )
    check status.statusData == StatusEvent(status: statusRunning, message: "")

  test "leaves absent optional LOG fields empty":
    let log = parseLine("""{"kind":"LOG","severity":"Notice","time":0}""")
    check log.logData == LogEvent(severity: Notice, time: 0)

  test "raises ValueError for lines that are not known events":
    for line in [
      """[1]""",
      """{"kind":"BOGUS"}""",
      """{"kind":"STATUS","status":"BOGUS","message":""}""",
      """{"kind":"STATUS","status":5,"message":""}""",
    ]:
      checkpoint("line: " & line)
      expect ValueError:
        discard parseLine(line)

  test "parseEventLine returns none for lines that are not valid events":
    check parseEventLine("""{"kind":"STATUS","status":"DONE","message":""}""").isSome
    for line in [
      "TRNRun says hello",
      "[1]",
      """{"kind":"BOGUS"}""",
      """{"kind":"STATUS","status":"DONE"}""",
      """{"kind":"LOG","severity":"Debug","time":0}""",
    ]:
      checkpoint("line: " & line)
      check parseEventLine(line).isNone

  test "raises KeyError for events missing a required field":
    for line in [
      """{"status":"DONE","message":""}""",
      """{"kind":"CONFIG","start":0,"stop":10}""",
    ]:
      checkpoint("line: " & line)
      expect KeyError:
        discard parseLine(line)
