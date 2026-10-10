## Turns the importing test program into a fake TRNRun.
##
## When started with a deck as its first argument, the program plays TRNRun
## and exits before any test runs, so tests pass `getAppFilename()` as the
## TRNRun path. The deck name up to its first `-` picks the behaviour, letting
## several runs share one mode.

{.used.} # Importing it is the point, even when no symbol is used.

import std/[os, strutils]

const
  GateTimeoutMs = 10_000 ## Gated runs stop waiting for their release after this.
  ProgressGateLines* = [
    """{"kind":"PROGRESS","time":2.5,"percent":25,"elapsedMs":100,"etaMs":300}""",
    """{"kind":"PROGRESS","time":5,"percent":50,"elapsedMs":200,"etaMs":200}""",
    """{"kind":"PROGRESS","time":7.5,"percent":75,"elapsedMs":300,"etaMs":100}""",
  ]
  DoneLines* = [
    """{"kind":"STATUS","status":"RUNNING","message":""}""",
    """{"kind":"CONFIG","start":0,"stop":10,"step":1}""",
    """{"kind":"LOG","severity":"Notice","time":0,"message":"first"}""",
    """{"kind":"LOG","severity":"Warning","time":5,"message":"second"}""",
    """{"kind":"LOG","severity":"Notice","time":10,"message":"third"}""",
    """{"kind":"PROGRESS","time":10,"percent":100,"elapsedMs":5,"etaMs":0}""",
    """{"kind":"STATUS","status":"DONE","message":""}""",
  ]
    ## What a successful run prints: three logs, then a `DONE` status.

proc printLine(line: string, output = stdout) =
  ## Writes and flushes one line, so the parent reads lines in order.
  output.writeLine(line)
  output.flushFile()

proc runFakeTrnrun(deckFile: string): int =
  ## Plays the TRNRun behaviour named by `deckFile` and returns its exit code.
  ##
  ## `done` prints `DoneLines`; `failed` reports `ERROR` and exits 1; `args`
  ## echoes its arguments; `streams` writes to stdout, then stderr, and exits 3;
  ## `gate` waits for the deck's `.release` file, writes `.released`, then acts
  ## like `done`. `progressgate` emits only a progress burst, writes `.progress`
  ## as an emission marker, then waits silently like `gate` before `DoneLines`.
  ## Any other mode, such as `silent`, exits 0 without output.
  result = 0
  case deckFile.splitFile().name.split('-')[0].toLowerAscii()
  of "done":
    for line in DoneLines:
      printLine(line)
  of "failed":
    printLine("""{"kind":"STATUS","status":"ERROR","message":"Fake failure"}""")
    result = 1
  of "args":
    for argument in commandLineParams():
      printLine(argument)
  of "streams":
    printLine("to stdout")
    printLine("to stderr", stderr)
    result = 3
  of "progressgate":
    for line in ProgressGateLines:
      printLine(line)
    writeFile(deckFile.changeFileExt("progress"), "")
    var waitedMs = 0
    while not fileExists(deckFile.changeFileExt("release")) and waitedMs < GateTimeoutMs:
      sleep(10)
      waitedMs += 10
    writeFile(deckFile.changeFileExt("released"), "")
    for line in DoneLines:
      printLine(line)
  of "gate":
    var waitedMs = 0
    while not fileExists(deckFile.changeFileExt("release")) and waitedMs < GateTimeoutMs:
      sleep(10)
      waitedMs += 10
    writeFile(deckFile.changeFileExt("released"), "")
    for line in DoneLines:
      printLine(line)
  else:
    discard

if paramCount() >= 1 and
    paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
  quit(runFakeTrnrun(paramStr(1)))
