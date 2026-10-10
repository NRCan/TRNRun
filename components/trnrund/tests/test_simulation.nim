import std/[json, options, times, unittest]

import ../src/[events, simulation]

const TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"


proc statusLine(status: string, message = ""): string =
  $(%*{"kind": "STATUS", "status": status, "message": message})

proc logLine(severity: string, message: string): string =
  $(%*{"kind": "LOG", "severity": severity, "time": 0, "message": message})


suite "simulation state":
  test "starts queued":
    const submittedAt = "2026-01-02T03:04:05.678Z"
    check initSimulation("run", "deck.dck", @["--pollMs:50"], submittedAt) == Simulation(
      runId: "run",
      deckFile: "deck.dck",
      trnrunArgs: @["--pollMs:50"],
      state: ssQueued,
      submittedAt: submittedAt,
    )

  test "stamps submission, start, and finish in UTC ISO 8601 with milliseconds":
    let before = now().utc()
    var simulation = initSimulation("run", "deck.dck", @[])
    check simulation.startedAt.isNone
    simulation.start()
    check simulation.state == ssRunning
    check simulation.finishedAt.isNone
    simulation.finish(some(0), "")
    let after = now().utc()

    let stamps = [
      simulation.submittedAt, simulation.startedAt.get(), simulation.finishedAt.get()
    ]
    for stamp in stamps:
      checkpoint("timestamp: " & stamp)
      let time = parse(stamp, TimestampFormat, utc())
      check time >= before - initDuration(milliseconds = 1)
      check time <= after
    check stamps[0] <= stamps[1]
    check stamps[1] <= stamps[2]

  test "keeps the latest SETTING, STATUS, CONFIG and PROGRESS":
    var simulation = initSimulation("run", "deck.dck", @[])
    let setting = %SettingEvent(guiVisibility: "hidden", severity: Warning)
    setting["kind"] = %"SETTING"

    simulation.applyLine($setting)
    simulation.applyLine(statusLine("RUNNING"))
    simulation.applyLine(statusLine("DONE", "finished"))
    simulation.applyLine("""{"kind":"CONFIG","start":0,"stop":10,"step":1}""")
    simulation.applyLine("""{"kind":"CONFIG","start":2,"stop":20,"step":0.5}""")
    simulation.applyLine(
      """{"kind":"PROGRESS","time":20,"percent":100,"elapsedMs":9,"etaMs":0}"""
    )

    check simulation.setting == some(SettingEvent(guiVisibility: "hidden", severity: Warning))
    check simulation.status == some(StatusEvent(status: statusDone, message: "finished"))
    check simulation.config == some(ConfigEvent(start: 2, stop: 20, step: 0.5))
    check simulation.progress ==
      some(ProgressEvent(time: 20, percent: 100, elapsedMs: 9, etaMs: 0))

  test "counts logs by severity and returns each entry":
    var simulation = initSimulation("run", "deck.dck", @[])
    for (severity, message) in [
      ("Notice", "first"),
      ("Warning", "second"),
      ("Warning", "third"),
    ]:
      simulation.applyLine(logLine(severity, message))

    let event = simulation.applyLine(logLine("Fatal", "fourth"))
    check event.get().kind == eventLog
    check event.get().logData == LogEvent(severity: Fatal, time: 0, message: some("fourth"))
    check simulation.notices == 1
    check simulation.warnings == 2
    check simulation.fatals == 1

  test "ignores lines that are not valid events":
    var simulation = initSimulation("run", "deck.dck", @[])
    simulation.applyLine(statusLine("RUNNING"))
    let before = simulation

    for line in [
      "TRNRun says hello",
      "[1]",
      """{"kind":"BOGUS"}""",
      """{"kind":"STATUS","status":"DONE"}""",
      """{"kind":"LOG","severity":"Debug","time":0}""",
    ]:
      checkpoint("line: " & line)
      check simulation.applyLine(line).isNone
      check simulation == before

  test "finish keeps TRNRun's terminal status and records the execution error":
    var simulation = initSimulation("run", "deck.dck", @[])
    simulation.applyLine(statusLine("DONE"))
    simulation.finish(some(0), "Output capture failed")

    check simulation.state == ssFinished
    check simulation.status == some(StatusEvent(status: statusDone, message: ""))
    check simulation.exitCode == some(0)
    check simulation.error == "Output capture failed"

  test "finish adds a daemon ERROR when TRNRun reported no terminal status":
    let cases = [
      (line: "", error: "", expected: "TRNRun exited without a terminal status"),
      (line: statusLine("RUNNING"), error: "", expected: "TRNRun exited without a terminal status"),
      (line: "", error: "Launch failed", expected: "Launch failed"),
    ]

    for testCase in cases:
      checkpoint("status line: " & testCase.line & ", error: " & testCase.error)
      var simulation = initSimulation("run", "deck.dck", @[])
      simulation.applyLine(testCase.line)
      simulation.finish(none(int), testCase.error)

      check simulation.state == ssFinished
      check simulation.status ==
        some(StatusEvent(status: statusError, message: testCase.expected))

  test "interrupt cancels the run, keeping a terminal status TRNRun reported":
    let cases = [
      (started: false, line: "", reason: "the daemon shut down",
        status: StatusEvent(status: statusCancelled, message: "Not started"),
        error: "Not started: the daemon shut down"),
      (started: true, line: statusLine("RUNNING"), reason: "the client disconnected",
        status: StatusEvent(status: statusCancelled, message: "Interrupted"),
        error: "Interrupted: the client disconnected"),
      (started: true, line: statusLine("DONE"), reason: "the client disconnected",
        status: StatusEvent(status: statusDone, message: ""),
        error: "Interrupted: the client disconnected"),
    ]

    for testCase in cases:
      checkpoint($testCase)
      var simulation = initSimulation("run", "deck.dck", @[])
      if testCase.started:
        simulation.start()
      simulation.applyLine(testCase.line)
      simulation.interrupt(testCase.reason)

      check simulation.state == ssFinished
      check simulation.status == some(testCase.status)
      check simulation.error == testCase.error
      check simulation.exitCode.isNone
      check simulation.startedAt.isSome == testCase.started
      check simulation.finishedAt.isSome
      check not simulation.succeeded()

  test "succeeds only when finished with DONE, exit code 0, and no error":
    let cases = [
      (status: "DONE", finished: true, exitCode: some(0), error: "", expected: true),
      (status: "DONE", finished: false, exitCode: none(int), error: "", expected: false),
      (status: "DONE", finished: true, exitCode: some(1), error: "", expected: false),
      (status: "DONE", finished: true, exitCode: some(0), error: "Lost", expected: false),
      (status: "ERROR", finished: true, exitCode: some(0), error: "", expected: false),
    ]

    for testCase in cases:
      checkpoint($testCase)
      var simulation = initSimulation("run", "deck.dck", @[])
      simulation.applyLine(statusLine(testCase.status))
      if testCase.finished:
        simulation.finish(testCase.exitCode, testCase.error)
      check simulation.succeeded() == testCase.expected
