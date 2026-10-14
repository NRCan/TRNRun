import std/[json, options, unittest]

import ../src/events
from ../../trnrun/src/events as trnrunEvents import nil
from ../../trnrun/src/settings as trnrunSettings import nil


proc parseLine(line: string): SimulationEvent =
  parseEventLine(line).get()


suite "TRNRun event parsing":
  test "parses every event kind into its payload":
    let setting = SettingEvent(
      trnexePath: r"C:\TRNSYS18\Exe\TrnEXE64.exe",
      guiVisibility: "hidden",
      waitForGui: true,
      detectTimeoutMs: 300000,
      pollMs: 100,
      severity: lsWarning,
    )
    let settingNode = %setting
    settingNode["kind"] = %"SETTING"
    let parsedSetting = parseLine($settingNode)
    check parsedSetting.kind == ekSetting
    check parsedSetting.setting == setting

    let status = parseLine("""{"kind":"STATUS","status":"DONE","message":"ok"}""")
    check status.kind == ekStatus
    check status.status == StatusEvent(status: stDone, message: "ok")

    let config = parseLine("""{"kind":"CONFIG","start":0,"stop":8760,"step":0.25}""")
    check config.kind == ekConfig
    check config.config == ConfigEvent(start: 0, stop: 8760, step: 0.25)

    let progress = parseLine(
      """{"kind":"PROGRESS","time":10,"percent":0.5,"elapsedMs":20,"etaMs":20}"""
    )
    check progress.kind == ekProgress
    check progress.progress ==
      ProgressEvent(time: 10, percent: 0.5, elapsedMs: 20, etaMs: 20)

    let log = parseLine(
      """{"kind":"LOG","severity":"Fatal","time":1.5,"unitId":3,"typeId":56,""" &
      """"messageCode":100,"message":"Bad input","information":"Check unit 3"}"""
    )
    check log.kind == ekLog
    check log.log == LogEvent(
      severity: lsFatal,
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
    check status.status == StatusEvent(status: stRunning, message: "")

  test "leaves absent optional LOG fields empty":
    let log = parseLine("""{"kind":"LOG","severity":"Notice","time":0}""")
    check log.log == LogEvent(severity: lsNotice, time: 0)

  test "returns none for lines that are not known events or miss a required field":
    for line in [
      "TRNRun says hello",
      "[1]",
      """{"kind":"BOGUS"}""",
      """{"kind":"STATUS","status":"BOGUS","message":""}""",
      """{"kind":"STATUS","status":5,"message":""}""",
      """{"kind":"STATUS","status":"DONE"}""",
      """{"kind":"LOG","severity":"Debug","time":0}""",
      """{"status":"DONE","message":""}""",
      """{"kind":"CONFIG","start":0,"stop":10}""",
      """{"kind":"SETTING","guiVisibility":"hidden","pollMs":100}""",
    ]:
      checkpoint("line: " & line)
      check parseEventLine(line).isNone

  test "SettingEvent holds exactly the SETTING event TRNRun builds":
    # Fails when TRNRun adds, renames, or retypes an option this module does not mirror.
    let sent = trnrunEvents.toJson(trnrunSettings.settingEvent(
      trnrunSettings.DefaultRunnerSettings, r"C:\TRNSYS18\Exe\TrnEXE64.exe"))
    let parsed = parseLine($sent)
    check parsed.kind == ekSetting
    let expected = sent.copy()
    expected.delete("kind")
    expected.delete("timestamp")
    check %parsed.setting == expected
