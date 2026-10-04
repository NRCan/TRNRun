import std/[json, options, unittest]
import ../src/[events, simulation]

proc initQueuedSimulation(): Simulation =
  initSimulation("run-1", "deck.dck", @["--watch"])

const SettingLine = """{
  "kind": "SETTING", "timestamp": "2026-10-04T12:00:00Z",
  "trnexePath": "trnsys.exe", "guiVisibility": "hidden",
  "waitForGui": true, "waitForLst": true, "waitForTmp": true,
  "detectTimeoutMs": 1000, "extraDelayMs": 20,
  "watchLog": true, "watchTmp": true,
  "watchTimeoutMs": 2000, "stallTimeoutMs": 3000, "pollMs": 10,
  "cleanOnSuccess": true, "killOnTimeout": true, "killOnStall": true,
  "severity": "Warning", "writeEvents": true
}"""

proc sampleSetting(): SettingEvent =
  SettingEvent(
    trnexePath: "trnsys.exe", guiVisibility: "hidden",
    waitForGui: true, waitForLst: true, waitForTmp: true,
    detectTimeoutMs: 1000, extraDelayMs: 20,
    watchLog: true, watchTmp: true,
    watchTimeoutMs: 2000, stallTimeoutMs: 3000, pollMs: 10,
    cleanOnSuccess: true, killOnTimeout: true, killOnStall: true,
    severity: Warning, writeEvents: true,
  )

suite "Simulation":
  test "queued simulations have no results":
    let simulation = initQueuedSimulation()
    check simulation.state == ssQueued
    check simulation.exitCode.isNone
    check simulation.error == ""
    check not simulation.succeeded()

  test "malformed output is ignored without changing existing state":
    var simulation = initQueuedSimulation()
    simulation.applyLine("""{"kind":"STATUS","status":"RUNNING","message":"Running"}""")
    simulation.applyLine("""{"kind":"PROGRESS","time":1,"percent":10,"elapsedMs":20,"etaMs":180}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Notice","time":1,"message":"Started"}""")
    let before = simulation

    for line in [
      "", "ordinary TRNRun output", "{", "null", "[]", "42", "\"text\"",
      "{}", """{"kind":"UNKNOWN"}""", """{"kind":42}""",
      """{"kind":"STATUS"}""",
      """{"kind":"STATUS","status":"DONE"}""",
      """{"kind":"STATUS","status":"UNKNOWN","message":"Bad status"}""",
      """{"kind":"STATUS","status":"DONE","message":false}""",
      """{"kind":"SETTING"}""", """{"kind":"CONFIG"}""",
      """{"kind":"PROGRESS","time":2,"percent":20,"elapsedMs":30}""",
      """{"kind":"PROGRESS","time":"bad","percent":20,"elapsedMs":30,"etaMs":120}""",
      """{"kind":"LOG","severity":"Fatal"}""",
      """{"kind":"LOG","severity":"Unknown","time":2}""",
      """{"kind":"LOG","severity":"Fatal","time":2,"unitId":"bad"}""",
    ]:
      checkpoint "Malformed line: " & line
      simulation.applyLine(line)
      check simulation == before

  test "complete setting events are applied and replaced without changing other state":
    var simulation = initQueuedSimulation()
    simulation.applyLine("""{"kind":"STATUS","status":"RUNNING","message":"Running"}""")
    simulation.applyLine("""{"kind":"CONFIG","start":0,"stop":10,"step":0.5}""")
    simulation.applyLine("""{"kind":"PROGRESS","time":1,"percent":10,"elapsedMs":20,"etaMs":180}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Notice","time":1,"message":"Started"}""")
    var expected = simulation

    simulation.applyLine(SettingLine)
    expected.setting = some(sampleSetting())
    check simulation == expected

    simulation.applyLine("""{
      "kind": "SETTING", "timestamp": "2026-10-04T12:01:00Z",
      "trnexePath": "other-trnsys.exe", "guiVisibility": "visible",
      "waitForGui": false, "waitForLst": false, "waitForTmp": false,
      "detectTimeoutMs": 0, "extraDelayMs": 0,
      "watchLog": false, "watchTmp": false,
      "watchTimeoutMs": 0, "stallTimeoutMs": 0, "pollMs": 0,
      "cleanOnSuccess": false, "killOnTimeout": false, "killOnStall": false,
      "severity": "Fatal", "writeEvents": false
    }""")
    expected.setting = some(SettingEvent(
      trnexePath: "other-trnsys.exe", guiVisibility: "visible", severity: Fatal,
    ))
    check simulation == expected

  test "complete config events are applied and replaced without changing other state":
    var simulation = initQueuedSimulation()
    simulation.applyLine(SettingLine)
    simulation.applyLine("""{"kind":"STATUS","status":"RUNNING","message":"Running"}""")
    simulation.applyLine("""{"kind":"PROGRESS","time":1,"percent":10,"elapsedMs":20,"etaMs":180}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Notice","time":1,"message":"Started"}""")
    var expected = simulation

    simulation.applyLine("""{"kind":"CONFIG","start":0,"stop":10,"step":0.5,"timestamp":"first"}""")
    expected.config = some(ConfigEvent(start: 0, stop: 10, step: 0.5))
    check simulation == expected

    simulation.applyLine("""{"kind":"CONFIG","start":2.5,"stop":20,"step":0.25,"timestamp":"second"}""")
    expected.config = some(ConfigEvent(start: 2.5, stop: 20, step: 0.25))
    check simulation == expected

  test "progress and status events are applied and replaced":
    var simulation = initQueuedSimulation()
    simulation.applyLine("""{"kind":"PROGRESS","time":2.5,"percent":25,"elapsedMs":100,"etaMs":300}""")
    check simulation.progress == some(ProgressEvent(time: 2.5, percent: 25, elapsedMs: 100, etaMs: 300))
    simulation.applyLine("""{"kind":"PROGRESS","time":10,"percent":100,"elapsedMs":400,"etaMs":0}""")
    check simulation.progress == some(ProgressEvent(time: 10, percent: 100, elapsedMs: 400, etaMs: 0))
    simulation.applyLine("""{"kind":"STATUS","status":"RUNNING","message":"Running"}""")
    check simulation.status == some(StatusEvent(status: statusRunning, message: "Running"))
    # The return value can be discarded by callers that only need the update.
    simulation.applyLine("""{"kind":"STATUS","status":"DONE","message":"Completed"}""")
    check simulation.status == some(StatusEvent(status: statusDone, message: "Completed"))
    check simulation.state == ssQueued
    check not simulation.succeeded()

  test "log events accumulate with severity counts and optional fields":
    var simulation = initQueuedSimulation()
    simulation.applyLine("""{"kind":"LOG","severity":"Notice","time":0}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Warning","time":1,"unitId":2,"typeId":3,"messageCode":4,"message":"Warning message","information":"Details"}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Fatal","time":2,"message":"Fatal message"}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Warning","time":3}""")
    check simulation.logs.len == 4
    check simulation.logs[0] == LogEvent(severity: Notice, time: 0)
    check simulation.logs[1] == LogEvent(
      severity: Warning, time: 1, unitId: some(2), typeId: some(3),
      messageCode: some(4), message: some("Warning message"),
      information: some("Details"),
    )
    check simulation.logs[2].message == some("Fatal message")
    check simulation.notices == 1
    check simulation.warnings == 2
    check simulation.fatals == 1

  test "queued snapshot has the exact wire fields and null results without logs":
    let snapshot = %initQueuedSimulation()
    check snapshot == %*{
      "runId": "run-1", "deckFile": "deck.dck", "trnrunArgs": ["--watch"],
      "state": "QUEUED", "exitCode": nil, "error": "",
      "setting": nil, "status": nil, "config": nil, "progress": nil,
      "notices": 0, "warnings": 0, "fatals": 0, "succeeded": false,
    }
    check "logs" notin snapshot

  test "populated snapshot serializes nested events and verdict without logs":
    var simulation = initQueuedSimulation()
    simulation.setting = some(sampleSetting())
    simulation.status = some(StatusEvent(status: statusDone, message: "Completed"))
    simulation.config = some(ConfigEvent(start: 0, stop: 10, step: 0.5))
    simulation.progress = some(ProgressEvent(time: 10, percent: 100, elapsedMs: 400, etaMs: 0))
    simulation.applyLine("""{"kind":"LOG","severity":"Notice","time":0}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Warning","time":1}""")
    simulation.applyLine("""{"kind":"LOG","severity":"Fatal","time":2}""")
    simulation.finish(some(0), "")

    let snapshot = %simulation
    check snapshot == %*{
      "runId": "run-1", "deckFile": "deck.dck", "trnrunArgs": ["--watch"],
      "state": "FINISHED", "exitCode": 0, "error": "",
      "setting": {
        "trnexePath": "trnsys.exe", "guiVisibility": "hidden",
        "waitForGui": true, "waitForLst": true, "waitForTmp": true,
        "detectTimeoutMs": 1000, "extraDelayMs": 20,
        "watchLog": true, "watchTmp": true,
        "watchTimeoutMs": 2000, "stallTimeoutMs": 3000, "pollMs": 10,
        "cleanOnSuccess": true, "killOnTimeout": true, "killOnStall": true,
        "severity": "Warning", "writeEvents": true,
      },
      "status": {"status": "DONE", "message": "Completed"},
      "config": {"start": 0.0, "stop": 10.0, "step": 0.5},
      "progress": {"time": 10.0, "percent": 100.0, "elapsedMs": 400.0, "etaMs": 0.0},
      "notices": 1, "warnings": 1, "fatals": 1, "succeeded": true,
    }
    check simulation.logs.len == 3
    check "logs" notin snapshot

  test "successful finish requires finished state DONE zero exit and no error":
    var simulation = initQueuedSimulation()
    simulation.status = some(StatusEvent(status: statusDone, message: "Completed"))
    simulation.exitCode = some(0)
    for state in [ssQueued, ssAccepted, ssRunning]:
      simulation.state = state
      check not simulation.succeeded()
    simulation.finish(some(0), "")
    check simulation.state == ssFinished
    check simulation.exitCode == some(0)
    check simulation.error == ""
    check simulation.status == some(StatusEvent(status: statusDone, message: "Completed"))
    check simulation.succeeded()

    simulation.exitCode = none(int)
    check not simulation.succeeded()
    simulation.exitCode = some(1)
    check not simulation.succeeded()
    simulation.exitCode = some(0)
    simulation.error = "Execution failed"
    check not simulation.succeeded()
    simulation.error = ""
    simulation.status = none(StatusEvent)
    check not simulation.succeeded()
    for status in SimStatus:
      simulation.status = some(StatusEvent(status: status))
      check simulation.succeeded() == (status == statusDone)

  test "finish retains execution errors and preserves every terminal status":
    for status in [statusDone, statusCancelled, statusError, statusTimeout, statusStalled]:
      var simulation = initQueuedSimulation()
      let terminal = StatusEvent(status: status, message: "TRNRun outcome")
      simulation.status = some(terminal)
      simulation.finish(some(0), "Could not collect TRNRun output")
      check simulation.state == ssFinished
      check simulation.exitCode == some(0)
      check simulation.error == "Could not collect TRNRun output"
      check simulation.status == some(terminal)
      check not simulation.succeeded()

  test "finish synthesizes ERROR for missing or nonterminal TRNRun status":
    for status in [none(StatusEvent), some(StatusEvent(status: statusRunning))]:
      var simulation = initQueuedSimulation()
      simulation.status = status
      simulation.finish(none(int), "Launch failed")
      check simulation.state == ssFinished
      check simulation.exitCode.isNone
      check simulation.error == "Launch failed"
      check simulation.status == some(StatusEvent(status: statusError, message: "Launch failed"))
      check not simulation.succeeded()

  test "zero exit without terminal status is not a success":
    var simulation = initQueuedSimulation()
    simulation.finish(some(0), "")
    check simulation.state == ssFinished
    check simulation.exitCode == some(0)
    check simulation.error == ""
    check simulation.status == some(StatusEvent(
      status: statusError, message: "TRNRun exited without a terminal status",
    ))
    check not simulation.succeeded()
