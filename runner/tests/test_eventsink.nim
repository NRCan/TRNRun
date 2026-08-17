import std/[os, strutils, times, unittest]
import ../src/events
import ../src/eventsink

let timestamp = fromUnix(0).utc()

suite "event sinks":
  test "delivers an event to a collector":
    var received: seq[SimulationEvent]
    let collector: EventSink = proc(event: SimulationEvent) =
      received.add(event)

    collector(statusEvent(statusRunning, timestamp))

    check received.len == 1
    check received[0].kind == eventStatus
    check received[0].statusData.status == statusRunning


  test "fans out to child sinks in order":
    var calls: seq[string]
    let first: EventSink = proc(event: SimulationEvent) =
      calls.add("first:" & $event.kind)
    let second: EventSink = proc(event: SimulationEvent) =
      calls.add("second:" & $event.kind)
    let sink = fanoutEventSink([first, second])

    sink(statusEvent(statusRunning, timestamp))

    check calls == @["first:STATUS", "second:STATUS"]

  test "JSONL sink writes events to an open file":
    let path = getTempDir() / ("trnrun-eventsink-" & $epochTime() & ".jsonl")
    defer:
      if fileExists(path):
        removeFile(path)

    path.writeFile("old event\n")
    let sink = jsonlEventSink(path)
    sink(statusEvent(statusRunning, timestamp))
    sink(statusEvent(statusDone, timestamp))

    let lines = path.readFile().strip().splitLines()
    check lines.len == 2
    check lines[0] == statusEvent(statusRunning, timestamp).toJsonLine()
    check lines[1] == statusEvent(statusDone, timestamp).toJsonLine()
