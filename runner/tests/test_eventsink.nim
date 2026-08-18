import std/[os, strutils, tempfiles, times, unittest]
import ../src/events
import ../src/eventsink

let timestamp = fromUnix(0).utc()

suite "event sinks and writers":
  test "delivers an event to a collector":
    var received: seq[SimulationEvent]
    let collector: EventSink = proc(event: SimulationEvent) =
      received.add(event)

    collector(statusEvent(statusRunning, timestamp))

    check received.len == 1
    check received[0].kind == eventStatus
    check received[0].statusData.status == statusRunning

  test "JSONL writer truncates, writes, and closes safely":
    let (file, path) = createTempFile("trnrun-eventsink-", ".jsonl")
    file.write("old event\n")
    file.close()
    defer:
      removeFile(path)

    let writer = openJsonlWriter(path)
    writer.write(statusEvent(statusRunning, timestamp).toJsonLine())
    writer.write(statusEvent(statusDone, timestamp).toJsonLine())
    writer.close()
    writer.close()
    writer.write("ignored after close")

    let lines = path.readFile().strip().splitLines()
    check lines == @[
      statusEvent(statusRunning, timestamp).toJsonLine(),
      statusEvent(statusDone, timestamp).toJsonLine(),
    ]

  test "nil JSONL writer operations are no-ops":
    var output: JsonlWriter = nil
    output.write(statusEvent(statusRunning, timestamp).toJsonLine())
    output.close()

  test "invalid JSONL path raises IOError":
    let parent = createTempDir("trnrun-eventsink-", "")
    defer:
      removeDir(parent)

    expect IOError:
      discard openJsonlWriter(parent / "missing" / "events.jsonl")
