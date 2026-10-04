when not defined(windows):
  {.error: "test_daemon.nim is Windows-only.".}

import std/[json, monotimes, os, osproc, streams, strutils, tempfiles, times, unittest, winlean]

let
  daemon = getAppDir() / "trnrund.exe"
  fakeTrnrun = getAppDir() / "fake_trnrun.exe"
for binary in [daemon, fakeTrnrun]:
  if not fileExists(binary):
    quit("Compile " & binary.extractFilename & " beside the test executable first", 2)

const
  ReadyTimeoutMs = 4000
  ExitTimeoutMs = 2000

proc expired(start: MonoTime, timeoutMs: int): bool =
  (getMonoTime() - start).inMilliseconds >= timeoutMs

proc launch(args: openArray[string]): Process =
  startProcess(daemon, args = args, options = {poDaemon})

proc launchDaemon(): Process =
  launch(["--trnrun:" & fakeTrnrun, "--maxConcurrent:1"])

proc awaitExit(process: Process): int =
  # Windows waitForExit(timeout) kills on timeout; poll first so a timeout fails
  # the test rather than making an incorrect shutdown look successful.
  let start = getMonoTime()
  while process.running:
    if start.expired(ExitTimeoutMs):
      raise newException(AssertionDefect, "Daemon did not exit within the deadline")
    sleep(5)
  process.waitForExit()

proc dispose(process: Process) =
  try:
    if process.running:
      process.kill()
      discard process.waitForExit(ExitTimeoutMs)
  finally:
    process.close()

proc send(process: Process, request: JsonNode) =
  process.inputStream.writeLine($request)
  process.inputStream.flush()

proc reply(process: Process): JsonNode =
  let start = getMonoTime()
  while not process.hasData():
    if not process.running or start.expired(ReadyTimeoutMs):
      raise newException(AssertionDefect, "Daemon did not send a reply within the deadline")
    sleep(5)
  var line = ""
  if not process.outputStream.readLine(line):
    raise newException(AssertionDefect, "Daemon closed stdout without a reply")
  parseJson(line)

proc awaitChild(process: Process, deck: string): Handle =
  let start = getMonoTime()
  while not fileExists(deck & ".ready"):
    if not process.running or start.expired(ReadyTimeoutMs):
      raise newException(AssertionDefect, "Fake TRNRun did not become ready")
    sleep(5)
  # The PID marker is written before .ready. Retain a handle while the child is
  # alive so termination checks cannot mistake a reused PID for this child.
  let pid = parseInt(readFile(deck & ".pid"))
  result = openProcess(DWORD(SYNCHRONIZE), 0, DWORD(pid))
  if result == 0:
    raise newException(AssertionDefect, "Could not open the fake TRNRun process")

proc checkCleanExit(process: Process, child: Handle = 0) =
  check process.awaitExit() == 0
  if child != 0 and waitForSingleObject(child, ExitTimeoutMs) != WAIT_OBJECT_0:
    raise newException(AssertionDefect, "Fake TRNRun survived daemon exit")
  check process.outputStream.readAll() == ""
  check process.errorStream.readAll() == ""

suite "Daemon executable":
  test "help and version work without a valid TRNRun executable":
    let directory = createTempDir("trnrund-cli-", "")
    try:
      for option in ["--help", "-h", "--version", "-v"]:
        let process = launch(["--trnrun:" & (directory / "missing.exe"), option])
        try:
          check process.awaitExit() == 0
          let output = process.outputStream.readAll()
          check process.errorStream.readAll() == ""
          if option in ["--help", "-h"]:
            check "Usage:" in output
            check "--maxConcurrent:N" in output
          else:
            check output.strip().len > 0
            check output.strip().splitLines().len == 1
        finally:
          process.dispose()
    finally:
      removeDir(directory)

  test "usage errors return code 2 and diagnostics only on stderr":
    let directory = createTempDir("trnrund-usage-", "")
    try:
      let cases = @[
        ("--unknown", "Unknown option: --unknown"),
        ("-x", "Unknown option: -x"),
        ("unexpected", "Unexpected argument: unexpected"),
        ("--maxConcurrent:", "invalid integer"),
        ("--maxConcurrent:abc", "invalid integer"),
        ("--maxConcurrent:0", "'maxConcurrent' must be at least 1"),
        ("--maxConcurrent:-1", "'maxConcurrent' must be at least 1"),
        ("--trnrun:" & (directory / "missing.exe"), "TRNRun not found:"),
      ]
      for (argument, diagnostic) in cases:
        let process = launch(["--trnrun:" & fakeTrnrun, argument])
        try:
          check process.awaitExit() == 2
          check process.outputStream.readAll() == ""
          check diagnostic in process.errorStream.readAll()
        finally:
          process.dispose()
    finally:
      removeDir(directory)

  test "explicit shutdown acknowledges and exits with stdin still open":
    let process = launchDaemon()
    try:
      process.send(%*{"cmd": "shutdown"})
      check process.reply() == %*{"ok": true}
      process.checkCleanExit()
    finally:
      process.dispose()

  test "explicit shutdown waits for held work to finish":
    let directory = createTempDir("trnrund-graceful-", "")
    let deck = directory / "held.dck"
    writeFile(deck, "hold")
    let process = launchDaemon()
    var child: Handle = 0
    try:
      process.send(%*{"cmd": "add", "runId": "held", "deckFile": deck})
      check process.reply() == %*{"ok": true}
      child = process.awaitChild(deck)
      check waitForSingleObject(child, 0) == WAIT_TIMEOUT
      process.send(%*{"cmd": "shutdown"})
      check process.reply() == %*{"ok": true}
      check waitForSingleObject(child, 0) == WAIT_TIMEOUT
      check process.running
      writeFile(deck & ".release", "")
      process.checkCleanExit(child)
    finally:
      writeFile(deck & ".release", "")
      process.dispose()
      if child != 0:
        discard closeHandle(child)
      removeDir(directory)

  test "EOF exits promptly and kills held work without a release":
    for attempt in 0 ..< 3:
      let directory = createTempDir("trnrund-eof-" & $attempt & "-", "")
      let deck = directory / "held.dck"
      writeFile(deck, "hold")
      let process = launchDaemon()
      var child: Handle = 0
      try:
        process.send(%*{"cmd": "add", "runId": "held", "deckFile": deck})
        check process.reply() == %*{"ok": true}
        child = process.awaitChild(deck)
        check waitForSingleObject(child, 0) == WAIT_TIMEOUT
        process.inputStream.close()
        process.checkCleanExit(child)
        check not fileExists(deck & ".release")
      finally:
        writeFile(deck & ".release", "")
        process.dispose()
        if child != 0:
          discard closeHandle(child)
        removeDir(directory)
