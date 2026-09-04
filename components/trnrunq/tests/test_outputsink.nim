import std/[algorithm, atomics, os, strutils, unittest]

import ../src/outputsink


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


const
  WriterCount = 8
  LinesPerWriter = 40
  PayloadLength = 1_024


type WriterArgs = object
  sink: ptr OutputSink
  writerIndex: int


var
  readyWriters: Atomic[int]
  writersMayStart: Atomic[bool]


proc emittedLine(writerIndex, lineIndex: int): string {.gcsafe.} =
  let marker = char(ord('A') + writerIndex)
  result = "writer-" & $writerIndex & "-line-" & $lineIndex & ":" &
    marker.repeat(PayloadLength)

proc writeLines(args: WriterArgs) {.thread.} =
  discard readyWriters.fetchAdd(1)
  while not writersMayStart.load():
    sleep(0)

  for lineIndex in 0 ..< LinesPerWriter:
    args.sink[].emit(emittedLine(args.writerIndex, lineIndex))


template captureStdout(path: string, body: untyped): string =
  block:
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
      body
    finally:
      stdout.flushFile()
      discard replaceFileDescriptor(savedStdoutDescriptor, stdoutDescriptor)
      discard closeFileDescriptor(savedStdoutDescriptor)
      captureFile.close()

    readFile(path)


template withTemporaryFile(path: string, body: untyped) =
  try:
    if fileExists(path):
      removeFile(path)
    body
  finally:
    if fileExists(path):
      removeFile(path)


suite "queue output sink":
  test "writes exact complete lines to stdout":
    let path = getTempDir() / "trnrunq_outputsink_lines.txt"
    withTemporaryFile(path):
      let content = captureStdout(path):
        var sink = default(OutputSink)
        sink.initOutputSink()
        try:
          sink.emit("first line")
          sink.emit("")
          sink.emit("third line")
        finally:
          sink.deinitOutputSink()

      check content == "first line\n\nthird line\n"

  test "serializes concurrent writers into complete lines":
    let path = getTempDir() / "trnrunq_outputsink_concurrent.txt"
    withTemporaryFile(path):
      readyWriters.store(0)
      writersMayStart.store(false)

      let content = captureStdout(path):
        var
          sink = default(OutputSink)
          writers: array[WriterCount, Thread[WriterArgs]]

        sink.initOutputSink()
        try:
          {.push warning[ProveInit]: off, warning[Uninit]: off.}
          for writerIndex in 0 ..< WriterCount:
            createThread(
              writers[writerIndex],
              writeLines,
              WriterArgs(sink: addr sink, writerIndex: writerIndex),
            )
          {.pop.}

          while readyWriters.load() < WriterCount:
            sleep(1)
          writersMayStart.store(true)

          for writer in writers.mitems:
            joinThread(writer)
        finally:
          writersMayStart.store(true)
          sink.deinitOutputSink()

      var
        actualLines: seq[string] = @[]
        expectedLines: seq[string] = @[]
      for line in content.splitLines():
        if line.len > 0:
          actualLines.add(line)
      for writerIndex in 0 ..< WriterCount:
        for lineIndex in 0 ..< LinesPerWriter:
          expectedLines.add(emittedLine(writerIndex, lineIndex))

      actualLines.sort()
      expectedLines.sort()

      check content.endsWith("\n")
      check content.count('\n') == WriterCount * LinesPerWriter
      check actualLines == expectedLines
