import std/[json, os, strutils, times, unittest]

import ../src/[events, eventsink]


when defined(windows):
  proc duplicateFileDescriptor(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
  proc replaceFileDescriptor(source, destination: cint): cint {.
    importc: "_dup2", header: "<io.h>".}
  proc closeFileDescriptor(fd: cint): cint {.importc: "_close", header: "<io.h>".}
else:
  proc duplicateFileDescriptor(fd: cint): cint {.importc: "dup", header: "<unistd.h>".}
  proc replaceFileDescriptor(source, destination: cint): cint {.
    importc: "dup2", header: "<unistd.h>".}
  proc closeFileDescriptor(fd: cint): cint {.importc: "close", header: "<unistd.h>".}


proc fixedTimestamp(): DateTime =
  dateTime(2026, mJun, 19, 19, 37, 13, 0, utc())

proc statusEvent(status: SimStatus): SimulationEvent =
  SimulationEvent(
    kind: eventStatus,
    statusData: StatusEvent(timestamp: fixedTimestamp(), status: status),
  )

proc parseJsonLines(content: string): seq[JsonNode] =
  result = @[]
  for line in content.splitLines():
    if line.len > 0:
      result.add(line.parseJson())

proc captureStdout(
    path: string,
    events: openArray[SimulationEvent],
    writer: JsonlWriter = nil,
): string =
  var captureFile: File = nil
  if not open(captureFile, path, fmWrite, bufSize = 0):
    raise newException(IOError, "Could not open stdout capture file '" & path & "'")

  let
    stdoutDescriptor = cint(getFileHandle(stdout))
    captureDescriptor = cint(getFileHandle(captureFile))
    savedStdoutDescriptor = duplicateFileDescriptor(stdoutDescriptor)

  if savedStdoutDescriptor < 0:
    captureFile.close()
    raise newException(IOError, "Could not duplicate stdout")

  stdout.flushFile()
  if replaceFileDescriptor(captureDescriptor, stdoutDescriptor) < 0:
    discard closeFileDescriptor(savedStdoutDescriptor)
    captureFile.close()
    raise newException(IOError, "Could not redirect stdout")

  try:
    let sink = stdoutEventSink(writer)
    for event in events:
      sink(event)
  finally:
    stdout.flushFile()
    discard replaceFileDescriptor(savedStdoutDescriptor, stdoutDescriptor)
    discard closeFileDescriptor(savedStdoutDescriptor)
    captureFile.close()

  result = readFile(path)


template withTemporaryFile(path: string, body: untyped) =
  try:
    if fileExists(path):
      removeFile(path)
    body
  finally:
    if fileExists(path):
      removeFile(path)


suite "JSONL event sinks":
  test "opens a writer by truncating an existing file":
    let path = getTempDir() / "trnrun_eventsink_truncate.jsonl"
    withTemporaryFile(path):
      writeFile(path, "stale event data\n")

      let writer = openJsonlWriter(path)
      writer.close()

      check readFile(path) == ""

  test "allows nil and repeated writer closes":
    let path = getTempDir() / "trnrun_eventsink_close.jsonl"
    withTemporaryFile(path):
      var nilWriter: JsonlWriter = nil
      nilWriter.close()

      let writer = openJsonlWriter(path)
      writer.close()
      writer.close()

  test "raises IOError when the output directory does not exist":
    let missingDirectory = getTempDir() / "trnrun_eventsink_missing_directory"
    let path = missingDirectory / "events.jsonl"
    if dirExists(missingDirectory):
      removeDir(missingDirectory)

    expect IOError:
      discard openJsonlWriter(path)

  test "writes numbered JSON lines to stdout and the mirror file":
    let
      stdoutPath = getTempDir() / "trnrun_eventsink_stdout.jsonl"
      mirrorPath = getTempDir() / "trnrun_eventsink_mirror.jsonl"
      events = [statusEvent(statusPending), statusEvent(statusDone)]

    withTemporaryFile(stdoutPath):
      withTemporaryFile(mirrorPath):
        let writer = openJsonlWriter(mirrorPath)
        let stdoutContent = captureStdout(stdoutPath, events, writer)
        writer.close()

        let
          mirrorContent = readFile(mirrorPath)
          lines = stdoutContent.parseJsonLines()

        check mirrorContent == stdoutContent
        check lines == @[
          %*{
            "kind": "STATUS",
            "timestamp": "2026-06-19T19:37:13",
            "status": "PENDING",
            "seq": 1,
          },
          %*{
            "kind": "STATUS",
            "timestamp": "2026-06-19T19:37:13",
            "status": "DONE",
            "seq": 2,
          },
        ]

  test "gives each event sink an independent sequence":
    let
      firstPath = getTempDir() / "trnrun_eventsink_first.jsonl"
      secondPath = getTempDir() / "trnrun_eventsink_second.jsonl"
      event = statusEvent(statusRunning)

    withTemporaryFile(firstPath):
      withTemporaryFile(secondPath):
        let firstLines = captureStdout(firstPath, [event]).parseJsonLines()
        let secondLines = captureStdout(secondPath, [event]).parseJsonLines()

        check firstLines.len == 1
        check secondLines.len == 1
        check firstLines[0]["seq"].getInt() == 1
        check secondLines[0]["seq"].getInt() == 1

  test "continues writing to stdout after the mirror writer is closed":
    let
      stdoutPath = getTempDir() / "trnrun_eventsink_closed_stdout.jsonl"
      mirrorPath = getTempDir() / "trnrun_eventsink_closed_mirror.jsonl"
      event = statusEvent(statusCancelled)

    withTemporaryFile(stdoutPath):
      withTemporaryFile(mirrorPath):
        let writer = openJsonlWriter(mirrorPath)
        writer.close()

        let lines = captureStdout(stdoutPath, [event], writer).parseJsonLines()

        check lines.len == 1
        check lines[0]["status"].getStr() == "CANCELLED"
        check lines[0]["seq"].getInt() == 1
        check readFile(mirrorPath) == ""
