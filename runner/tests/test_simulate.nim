import std/[os, sequtils, strutils, unittest]

import ../src/[events, eventsink, settings, simulate, status]


const
  FakeLongRunMs = 300
  KillAssertionWaitMs = FakeLongRunMs + 200


proc runFakeTrnexe(deckFile: string) =
  let mode = deckFile.splitFile().name.toLowerAscii()

  case mode
  of "done", "cancelled", "cleanup", "args", "stale":
    let progress =
      if mode == "cancelled":
        "50, 0, 100, 1"
      else:
        "100, 0, 100, 1"
    if mode == "stale":
      var staleExtensions = newSeq[string]()
      for extension in ["tmp", "log", "lst", "PTI"]:
        if fileExists(deckFile.changeFileExt(extension)):
          staleExtensions.add(extension)
      writeFile(
        deckFile.changeFileExt("stale"),
        if staleExtensions.len == 0: "clean" else: staleExtensions.join(","),
      )

    writeFile(deckFile.changeFileExt("tmp"), progress)

    if mode == "cleanup":
      writeFile(deckFile.changeFileExt("log"), "")
      writeFile(deckFile.changeFileExt("lst"), "generated")
      writeFile(deckFile.changeFileExt("PTI"), "generated")

    if mode == "args":
      writeFile(
        deckFile.changeFileExt("args"),
        commandLineParams().join("\n"),
      )

    sleep(50)

  of "fatal":
    writeFile(
      deckFile.changeFileExt("log"),
      "*** Fatal at time : 0\n" &
      "Message : Fake TrnEXE failure\n",
    )

  of "timeout", "timeout-no-kill", "no-tmp":
    sleep(FakeLongRunMs)
    writeFile(deckFile.changeFileExt("completed"), "completed naturally")

  of "stalled", "stalled-no-kill":
    writeFile(deckFile.changeFileExt("tmp"), "10, 0, 100, 1")
    sleep(FakeLongRunMs)
    writeFile(deckFile.changeFileExt("completed"), "completed naturally")

  else:
    discard

if paramCount() >= 1 and
    paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
  runFakeTrnexe(paramStr(1))
  quit(QuitSuccess)


type EventCollector = ref object
  events: seq[SimulationEvent]
  sink: EventSink

proc newEventCollector(): EventCollector =
  result = EventCollector(events: @[])
  let collector = result
  result.sink = proc(event: SimulationEvent) {.gcsafe.} =
    collector.events.add(event)

proc newLaunchFailureCollector(deckFile: string): EventCollector =
  result = EventCollector(events: @[])
  let collector = result
  result.sink = proc(event: SimulationEvent) {.gcsafe.} =
    collector.events.add(event)
    if event.kind == eventStatus and event.statusData.status == statusLaunching:
      removeFile(deckFile)
      removeDir(deckFile.parentDir())

proc terminalStatuses(events: openArray[SimulationEvent]): seq[SimStatus] =
  result = @[]
  for event in events:
    if event.kind == eventStatus:
      result.add(event.statusData.status)

proc testSettings(): RunnerSettings =
  result = DefaultRunnerSettings
  result.trnexePath = getAppFilename()
  result.guiVisibility = guiKeepOpen
  result.waitForGui = false
  result.waitForLst = false
  result.waitForTmp = false
  result.detectTimeoutMs = 500
  result.extraDelayMs = 0
  result.watchLog = false
  result.watchTmp = false
  result.watchTimeoutMs = 0
  result.stallTimeoutMs = 0
  result.pollMs = 10
  result.cleanOnSuccess = false
  result.killOnTimeout = false
  result.killOnStall = false
  result.writeEvents = false

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")


proc runTests() =
  let testDirectory = getTempDir() / "trnrun_simulate_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "simulation lifecycle":
    test "emits the complete successful lifecycle":
      let
        deckFile = createDeck(testDirectory, "done.dck")
        collector = newEventCollector()
      var settings = testSettings()
      settings.watchTmp = true
      settings.detectTimeoutMs = -1
      settings.pollMs = 0

      let outcome = simulate(deckFile, collector.sink, settings)

      check outcome == simDone
      check collector.events.terminalStatuses() == @[
        statusPending,
        statusLaunching,
        statusRunning,
        statusDone,
      ]
      check collector.events[0].kind == eventSetting
      check collector.events[0].settingData.trnexePath ==
        getAppFilename().absolutePath().normalizedPath()
      check collector.events[0].settingData.detectTimeoutMs == 0
      check collector.events[0].settingData.pollMs == 1
      check collector.events.anyIt(it.kind == eventConfig)
      check collector.events.anyIt(it.kind == eventProgress)

    test "returns cancelled when the process exits before full progress":
      let
        deckFile = createDeck(testDirectory, "cancelled.dck")
        collector = newEventCollector()
      var settings = testSettings()
      settings.watchTmp = true

      let outcome = simulate(deckFile, collector.sink, settings)

      check outcome == simCancelled
      check collector.events.terminalStatuses()[^1] == statusCancelled

    test "detects a fatal log emitted by the process":
      let
        deckFile = createDeck(testDirectory, "fatal.dck")
        collector = newEventCollector()
      var settings = testSettings()
      settings.watchLog = true

      let outcome = simulate(deckFile, collector.sink, settings)

      check outcome == simFatal
      check collector.events.terminalStatuses()[^1] == statusError
      check collector.events.anyIt(
        it.kind == eventLog and it.logData.severity == Fatal
      )

    test "kills the process after a monitoring timeout when configured":
      let
        deckFile = createDeck(testDirectory, "timeout.dck")
        completedFile = deckFile.changeFileExt("completed")
        collector = newEventCollector()
      removeIfExists(completedFile)
      var settings = testSettings()
      settings.watchTimeoutMs = 50
      settings.killOnTimeout = true

      let outcome = simulate(deckFile, collector.sink, settings)
      sleep(KillAssertionWaitMs)

      check outcome == simTimeout
      check collector.events.terminalStatuses()[^1] == statusTimeout
      check not fileExists(completedFile)

    test "waits for natural exit after a monitoring timeout when kill is disabled":
      let
        deckFile = createDeck(testDirectory, "timeout-no-kill.dck")
        completedFile = deckFile.changeFileExt("completed")
        collector = newEventCollector()
      removeIfExists(completedFile)
      var settings = testSettings()
      settings.watchTimeoutMs = 50
      settings.killOnTimeout = false

      let outcome = simulate(deckFile, collector.sink, settings)

      check outcome == simTimeout
      check collector.events.terminalStatuses()[^1] == statusTimeout
      check readFile(completedFile) == "completed naturally"

    test "kills a stalled process when configured":
      let
        deckFile = createDeck(testDirectory, "stalled.dck")
        completedFile = deckFile.changeFileExt("completed")
        collector = newEventCollector()
      removeIfExists(completedFile)
      var settings = testSettings()
      settings.watchTmp = true
      settings.stallTimeoutMs = 50
      settings.killOnStall = true

      let outcome = simulate(deckFile, collector.sink, settings)
      sleep(KillAssertionWaitMs)

      check outcome == simStalled
      check collector.events.terminalStatuses()[^1] == statusStalled
      check not fileExists(completedFile)

    test "waits for natural exit after a stall when kill is disabled":
      let
        deckFile = createDeck(testDirectory, "stalled-no-kill.dck")
        completedFile = deckFile.changeFileExt("completed")
        collector = newEventCollector()
      removeIfExists(completedFile)
      var settings = testSettings()
      settings.watchTmp = true
      settings.stallTimeoutMs = 50
      settings.killOnStall = false

      let outcome = simulate(deckFile, collector.sink, settings)

      check outcome == simStalled
      check collector.events.terminalStatuses()[^1] == statusStalled
      check readFile(completedFile) == "completed naturally"

    test "returns from readiness timeout before entering running status":
      let
        deckFile = createDeck(testDirectory, "no-tmp.dck")
        completedFile = deckFile.changeFileExt("completed")
        collector = newEventCollector()
      removeIfExists(completedFile)
      var settings = testSettings()
      settings.waitForTmp = true
      settings.detectTimeoutMs = 50
      settings.killOnTimeout = true

      let outcome = simulate(deckFile, collector.sink, settings)
      sleep(KillAssertionWaitMs)

      check outcome == simTimeout
      check collector.events.terminalStatuses() == @[
        statusPending,
        statusLaunching,
        statusTimeout,
      ]
      check not fileExists(completedFile)

    test "removes generated sidecars after a successful clean run":
      let
        deckFile = createDeck(testDirectory, "cleanup.dck")
        collector = newEventCollector()
      var settings = testSettings()
      settings.watchTmp = true
      settings.cleanOnSuccess = true

      check simulate(deckFile, collector.sink, settings) == simDone
      for extension in ["tmp", "log", "lst", "PTI"]:
        check not fileExists(deckFile.changeFileExt(extension))

    test "removes stale sidecars before launching the process":
      let
        deckFile = createDeck(testDirectory, "stale.dck")
        staleCheckFile = deckFile.changeFileExt("stale")
        collector = newEventCollector()
      writeFile(deckFile.changeFileExt("tmp"), "50, 0, 100, 1")
      writeFile(
        deckFile.changeFileExt("log"),
        "*** Fatal at time : 0\nMessage : stale failure\n",
      )
      writeFile(deckFile.changeFileExt("lst"), "stale list")
      writeFile(deckFile.changeFileExt("PTI"), "stale plot")

      var settings = testSettings()
      settings.watchLog = true
      settings.watchTmp = true

      check simulate(deckFile, collector.sink, settings) == simDone
      check readFile(staleCheckFile) == "clean"

    test "converts process launch failures to fatal results":
      let launchDirectory = testDirectory / "launch-failure"
      createDir(launchDirectory)
      let
        deckFile = createDeck(launchDirectory, "launch-failure.dck")
        collector = newLaunchFailureCollector(deckFile)
        settings = testSettings()

      check simulate(deckFile, collector.sink, settings) == simFatal
      check collector.events[^1].statusData.message.contains(
        "Failed to launch TRNSYS:",
      )
      check collector.events.terminalStatuses() == @[
        statusPending,
        statusLaunching,
        statusError,
      ]

    test "passes the visibility switch to the launched executable":
      let
        deckFile = createDeck(testDirectory, "args.dck")
        argsFile = deckFile.changeFileExt("args")
        collector = newEventCollector()
      var settings = testSettings()
      settings.guiVisibility = guiHidden
      settings.watchTmp = true

      check simulate(deckFile, collector.sink, settings) == simDone
      let arguments = readFile(argsFile).splitLines()
      check arguments[0] == deckFile.absolutePath().normalizedPath()
      check arguments[1] == "/h"

runTests()
