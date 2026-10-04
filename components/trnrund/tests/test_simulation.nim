import std/[json, options, unittest]

import ../src/[events, simulation]


proc statusLine(status: string, message = ""): string =
  $(%*{"kind": "STATUS", "status": status, "message": message})

proc logLine(severity: string, message: string): string =
  $(%*{"kind": "LOG", "severity": severity, "time": 0, "message": message})


suite "simulation state":
  test "starts queued with nothing reported":
    check initSimulation("run", "deck.dck", @["--pollMs:50"]) == Simulation(
      runId: "run",
      deckFile: "deck.dck",
      trnrunArgs: @["--pollMs:50"],
      state: ssQueued,
    )

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
    check simulation.logs.len == 0

  test "appends logs and counts them by severity":
    var simulation = initSimulation("run", "deck.dck", @[])
    for (severity, message) in [
      ("Notice", "first"),
      ("Warning", "second"),
      ("Warning", "third"),
      ("Fatal", "fourth"),
    ]:
      simulation.applyLine(logLine(severity, message))

    check simulation.logs.len == 4
    check simulation.logs[3] == LogEvent(severity: Fatal, time: 0, message: some("fourth"))
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
      simulation.applyLine(line)
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

  test "serializes every field but logs, plus the success verdict":
    var simulation = initSimulation("run", "deck.dck", @[])
    simulation.applyLine(logLine("Notice", "first"))
    simulation.applyLine(statusLine("DONE"))
    simulation.finish(some(0), "")

    let node = %simulation
    check "logs" notin node
    check node["succeeded"].getBool()
    check node["runId"].getStr() == "run"
    check node["state"].getStr() == "FINISHED"
    check node["status"] == %*{"status": "DONE", "message": ""}
    check node["exitCode"].getInt() == 0
    check node["config"].kind == JNull
    check node["notices"].getInt() == 1
