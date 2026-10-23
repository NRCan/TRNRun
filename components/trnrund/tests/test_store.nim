import std/[json, options, sequtils, strutils, times, unittest]

import ../src/[events, store, validate]

const TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"

proc event(line: string): SimulationEvent =
  ## Parses one TRNRun event line, which must be a valid event.
  parseEventLine(line).get()

proc statusEvent(status: string, message = ""): SimulationEvent =
  ## A `STATUS` event with `status` and `message`.
  event($(%*{"kind": "STATUS", "status": status, "message": message}))

proc logEvent(severity: string, message = ""): SimulationEvent =
  ## A `LOG` event of `severity` at simulation time 0.
  event($(%*{"kind": "LOG", "severity": severity, "time": 0, "message": message}))

const Setting = SettingEvent(guiVisibility: "hidden", severity: lsWarning, pollMs: 50)

proc settingEvent(setting: SettingEvent): SimulationEvent =
  ## The SETTING event TRNRun sends for `setting`.
  let node = %setting
  node["kind"] = %"SETTING"
  node["timestamp"] = %"2026-06-19T19:37:13"
  event($node)

proc started(store: var Store): int =
  ## Adds a new run as submitted and started.
  result = store.submit("deck.dck")
  store.start(result)

proc reported(store: var Store): int =
  ## Adds a new run as running after TRNRun sent every kind of event.
  result = store.started()
  store.record(result, settingEvent(Setting))
  store.record(result, statusEvent("RUNNING", "going"))
  store.record(result, event("""{"kind":"CONFIG","start":0,"stop":8760,"step":0.25}"""))
  store.record(result, event(
    """{"kind":"PROGRESS","time":4380,"percent":0.5,"elapsedMs":1234.5,"etaMs":1234.5}"""))
  store.record(result, logEvent("Warning", "careful"))

proc finished(store: var Store): int =
  ## Adds a new run as finished with a `DONE` status and exit code 0.
  result = store.started()
  store.record(result, statusEvent("DONE"))
  store.finish(result, some(0), "")

proc json(run: Run): JsonNode =
  ## `run` as the protocol object clients read.
  var text = ""
  text.addJson(run)
  parseJson(text)

proc reportedFields(run: Run): JsonNode =
  ## The fields `reported` fills that finishing leaves alone.
  let node = run.json
  %*{
    "deckFile": node["deckFile"], "startTime": node["startTime"], "stopTime": node["stopTime"],
    "timeStep": node["timeStep"], "simTime": node["simTime"], "percent": node["percent"],
    "elapsedMs": node["elapsedMs"], "etaMs": node["etaMs"], "notices": node["notices"],
    "warnings": node["warnings"], "fatals": node["fatals"], "setting": node["setting"],
  }

suite "run store":
  setup:
    var store = initStore()

  test "starts empty":
    check 1 notin store

  test "numbers new runs and keeps them queued, null where TRNRun has not reported yet":
    check store.submit("first.dck") == 1
    check store.submit("second.dck", label = some("my label")) == 2
    check 1 in store
    let first = store[1].json
    check first["submittedAt"].getStr().len > 0
    first.delete("submittedAt")
    check first == %*{
      "runId": 1, "label": nil, "state": "QUEUED", "trnrunStatus": nil, "trnrunMessage": nil,
      "percent": nil, "simTime": nil, "elapsedMs": nil, "etaMs": nil,
      "notices": 0, "warnings": 0, "fatals": 0, "succeeded": nil, "exitCode": nil, "error": nil,
      "startedAt": nil, "finishedAt": nil, "deckFile": "first.dck", "trnrunArgs": [],
      "startTime": nil, "stopTime": nil, "timeStep": nil, "setting": nil, "logs": [],
    }
    check store[2].label == some("my label")

  test "keeps TRNRun arguments":
    let runId = store.submit("deck.dck", @["--pollMs:50", "--guiVisibility:hidden"])
    check store[runId].json["trnrunArgs"] == %["--pollMs:50", "--guiVisibility:hidden"]

  test "each event changes only its own fields":
    let other = store.submit("deck.dck")
    let runId = store.reported()
    check store[other].state == ssQueued
    check store[runId].state == ssRunning
    check store[runId].reportedFields == %*{
      "deckFile": "deck.dck", "startTime": 0.0, "stopTime": 8760.0, "timeStep": 0.25,
      "simTime": 4380.0, "percent": 0.5, "elapsedMs": 1234.5, "etaMs": 1234.5,
      "notices": 0, "warnings": 1, "fatals": 0, "setting": %Setting,
    }
    check (store[runId].trnrunStatus, store[runId].trnrunMessage) == (some(stRunning), some("going"))

  test "keeps SETTING without its kind and timestamp":
    let runId = store.reported()
    check store[runId].json["setting"] == %Setting

  test "keeps the latest SETTING, STATUS, CONFIG and PROGRESS":
    let runId = store.reported()
    var newer = Setting
    newer.pollMs = 75
    store.record(runId, settingEvent(newer))
    store.record(runId, statusEvent("DONE", "finished"))
    store.record(runId, event("""{"kind":"CONFIG","start":2,"stop":20,"step":0.5}"""))
    store.record(runId, event(
      """{"kind":"PROGRESS","time":20,"percent":1,"elapsedMs":9,"etaMs":0}"""))
    let node = store[runId].json
    check node["setting"] == %newer
    check (node["trnrunStatus"], node["trnrunMessage"]) == (%"DONE", %"finished")
    check [node["startTime"], node["stopTime"], node["timeStep"]] == [%2.0, %20.0, %0.5]
    check [node["simTime"], node["percent"], node["elapsedMs"], node["etaMs"]] ==
      [%20.0, %1.0, %9.0, %0.0]

  test "appends each LOG to its own run and counts it by severity":
    let runId = store.started()
    let other = store.started()
    for (severity, message) in [
      ("Notice", "first"), ("Warning", "second"), ("Warning", "third"), ("Fatal", "fourth")
    ]:
      store.record(runId, logEvent(severity, message))
    store.record(other, logEvent("Notice", "other"))
    store.record(runId, event(
      """{"kind":"LOG","severity":"Fatal","time":1.5,"unitId":7,"typeId":56,""" &
      """"messageCode":100,"message":"fifth","information":"Check unit 7"}"""))
    check (store[runId].notices, store[runId].warnings, store[runId].fatals) == (1, 2, 2)
    let logs = store[runId].json["logs"]
    check logs.elems.mapIt(it["message"].getStr()) == @["first", "second", "third", "fourth", "fifth"]
    check store[other].json["logs"].elems.mapIt(it["message"].getStr()) == @["other"]
    check logs[^1] == %*{
      "severity": "Fatal", "simTime": 1.5, "unitId": 7, "typeId": 56,
      "messageCode": 100, "message": "fifth", "information": "Check unit 7",
    }
    check logs[0] == %*{
      "severity": "Notice", "simTime": 0.0, "unitId": nil,
      "typeId": nil, "messageCode": nil, "message": "first", "information": nil,
    }

  test "stamps submission, start, and finish in UTC ISO 8601 with milliseconds":
    let before = now().utc()
    let runId = store.submit("deck.dck")
    check store[runId].startedAt.isNone and store[runId].finishedAt.isNone
    store.start(runId)
    check store[runId].state == ssRunning and store[runId].finishedAt.isNone
    store.finish(runId, some(0), "")
    let after = now().utc()

    let stamps = [store[runId].submittedAt, store[runId].startedAt.get(),
      store[runId].finishedAt.get()]
    for stamp in stamps:
      checkpoint("timestamp: " & stamp)
      let time = parse(stamp, TimestampFormat, utc())
      check time >= before - initDuration(milliseconds = 1)
      check time <= after + initDuration(milliseconds = 1)
    check stamps[0] <= stamps[1]
    check stamps[1] <= stamps[2]

  test "finish keeps TRNRun's terminal status and records the execution error":
    let runId = store.reported()
    let reported = store[runId].reportedFields
    store.record(runId, statusEvent("DONE"))
    store.finish(runId, some(0), "Output capture failed")
    let run = store[runId]
    check (run.state, run.trnrunStatus, run.trnrunMessage) == (ssFinished, some(stDone), some(""))
    check (run.exitCode, run.error, run.succeeded) ==
      (some(0), some("Output capture failed"), some(false))
    check run.reportedFields == reported

  test "finish adds a daemon ERROR when TRNRun reported no terminal status":
    let cases = [
      (status: "", exitCode: some(0), error: "",
        expected: "TRNRun exited without a terminal status"),
      (status: "RUNNING", exitCode: some(0), error: "",
        expected: "TRNRun exited without a terminal status"),
      (status: "", exitCode: none(int), error: "Launch failed", expected: "Launch failed"),
    ]
    for testCase in cases:
      checkpoint($testCase)
      let runId = store.started()
      if testCase.status.len > 0:
        store.record(runId, statusEvent(testCase.status))
      store.finish(runId, testCase.exitCode, testCase.error)
      let run = store[runId]
      check (run.state, run.trnrunStatus, run.trnrunMessage, run.succeeded) ==
        (ssFinished, some(stError), some(testCase.expected), some(false))

  test "a run that never launched finishes from QUEUED without a start time":
    let runId = store.submit("deck.dck")
    store.finish(runId, none(int), "Requested command not found")
    let run = store[runId]
    check (run.state, run.startedAt, run.exitCode, run.error, run.succeeded) ==
      (ssFinished, none(string), none(int), some("Requested command not found"), some(false))

  test "succeeds only when finished with DONE, exit code 0, and no error":
    let cases = [
      (status: "DONE", exitCode: some(0), error: "", expected: true),
      (status: "DONE", exitCode: some(1), error: "", expected: false),
      (status: "DONE", exitCode: none(int), error: "", expected: false),
      (status: "DONE", exitCode: some(0), error: "Lost", expected: false),
      (status: "ERROR", exitCode: some(0), error: "", expected: false),
    ]
    for testCase in cases:
      checkpoint($testCase)
      let runId = store.started()
      store.record(runId, statusEvent(testCase.status))
      check store[runId].succeeded.isNone
      store.finish(runId, testCase.exitCode, testCase.error)
      check store[runId].succeeded == some(testCase.expected)

  test "cancel finishes as CANCELLED, keeping a terminal status TRNRun reported":
    let
      queued = store.submit("deck.dck")
      running = store.reported()
      done = store.started()
    store.record(done, statusEvent("DONE"))
    store.cancel(queued, started = false, "the daemon shut down")
    store.cancel(running, started = true, "cancelled by the client")
    store.cancel(done, started = true, "cancelled by the client")

    proc outcome(run: Run): auto =
      ## The fields cancelling sets.
      (run.state, run.trnrunStatus, run.trnrunMessage, run.error, run.exitCode,
        run.startedAt.isSome, run.finishedAt.isSome, run.succeeded)
    check store[queued].outcome == (ssFinished, some(stCancelled), some("Not started"),
      some("Not started: the daemon shut down"), none(int), false, true, some(false))
    check store[running].outcome == (ssFinished, some(stCancelled), some("Interrupted"),
      some("Interrupted: cancelled by the client"), none(int), true, true, some(false))
    check store[done].outcome == (ssFinished, some(stDone), some(""),
      some("Interrupted: cancelled by the client"), none(int), true, true, some(false))

  test "release deletes a finished run with its logs, and skips an unknown runId":
    let first = store.finished()
    let second = store.finished()
    store.record(first, logEvent("Notice"))
    store.release(first)
    check first notin store
    check second in store
    store.release(first) # Safe to retry.
    store.release(99)

  test "release rejects a run that is not finished":
    let queued = store.submit("deck.dck")
    let running = store.started()
    for unfinished in [queued, running]:
      checkpoint($unfinished)
      try:
        store.release(unfinished)
        fail()
      except InputError as error:
        check error.msg == "Run " & $unfinished & " is not FINISHED"
      check unfinished in store

  test "keeps apostrophes, Unicode, and JSON-like text verbatim":
    let special = "O'Brien — été 中文 🙂\"}, {\"injected\": 1, \\ \n\t"
    let runId = store.submit(special, label = some(special))
    store.record(runId, logEvent("Notice", special))
    let node = store[runId].json
    check (node["deckFile"].getStr(), node["label"].getStr()) == (special, special)
    check node["logs"][0]["message"].getStr() == special
    var text = ""
    text.addJson(store[runId])
    check "\n" notin text
