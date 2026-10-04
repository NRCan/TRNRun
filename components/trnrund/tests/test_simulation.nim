import std/[options, unittest]
import ../src/[events, simulation]

proc initQueuedSimulation(): Simulation =
  initSimulation("run-1", "deck.dck", @["--watch"])

suite "Simulation":
  test "queued simulations have no results":
    let simulation = initQueuedSimulation()
    check simulation.state == ssQueued
    check simulation.exitCode.isNone
    check simulation.error == ""
    check not simulation.succeeded()

  test "malformed output is ignored without changing existing state":
    var simulation = initQueuedSimulation()
    check simulation.applyLine("""{"kind":"STATUS","status":"RUNNING","message":"Running"}""")
    check simulation.applyLine("""{"kind":"PROGRESS","time":1,"percent":10,"elapsedMs":20,"etaMs":180}""")
    check simulation.applyLine("""{"kind":"LOG","severity":"Notice","time":1,"message":"Started"}""")
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
      check not simulation.applyLine(line)
      check simulation == before

  test "progress and status events are applied and replaced":
    var simulation = initQueuedSimulation()
    check simulation.applyLine("""{"kind":"PROGRESS","time":2.5,"percent":25,"elapsedMs":100,"etaMs":300}""")
    check simulation.progress == some(ProgressEvent(time: 2.5, percent: 25, elapsedMs: 100, etaMs: 300))
    check simulation.applyLine("""{"kind":"PROGRESS","time":10,"percent":100,"elapsedMs":400,"etaMs":0}""")
    check simulation.progress == some(ProgressEvent(time: 10, percent: 100, elapsedMs: 400, etaMs: 0))
    check simulation.applyLine("""{"kind":"STATUS","status":"RUNNING","message":"Running"}""")
    check simulation.status == some(StatusEvent(status: statusRunning, message: "Running"))
    # The return value can be discarded by callers that only need the update.
    simulation.applyLine("""{"kind":"STATUS","status":"DONE","message":"Completed"}""")
    check simulation.status == some(StatusEvent(status: statusDone, message: "Completed"))
    check simulation.state == ssQueued
    check not simulation.succeeded()

  test "log events accumulate with severity counts and optional fields":
    var simulation = initQueuedSimulation()
    check simulation.applyLine("""{"kind":"LOG","severity":"Notice","time":0}""")
    check simulation.applyLine("""{"kind":"LOG","severity":"Warning","time":1,"unitId":2,"typeId":3,"messageCode":4,"message":"Warning message","information":"Details"}""")
    check simulation.applyLine("""{"kind":"LOG","severity":"Fatal","time":2,"message":"Fatal message"}""")
    check simulation.applyLine("""{"kind":"LOG","severity":"Warning","time":3}""")
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
