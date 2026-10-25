## Turns the importing test program into a fake TRNRun, plus deck helpers for tests.
##
## Started with a `.dck` as its first argument, the program plays TRNRun and
## exits before any test runs, so tests pass `getAppFilename()` as the TRNRun
## path. The deck name up to its first `-` picks the behaviour.

{.used.}

import std/[os, strutils, tempfiles]

const
  WaitLimitMs = 10_000 ## A `wait` run gives up on its `.release` file after this.
  ProgressLine = """{"kind":"PROGRESS","time":5,"percent":0.5,"elapsedMs":100,"etaMs":100}"""
  DoneLines = [
    """{"kind":"STATUS","status":"RUNNING","message":""}""",
    """{"kind":"CONFIG","start":0,"stop":10,"step":1}""",
    """{"kind":"LOG","severity":"Notice","time":0,"message":"first"}""",
    """{"kind":"LOG","severity":"Warning","time":5,"message":"second"}""",
    "not an event",
    """{"kind":"LOG","severity":"Fatal","time":10,"message":"third"}""",
    """{"kind":"PROGRESS","time":10,"percent":1,"elapsedMs":200,"etaMs":0}""",
  ]
  DoneLastLine = """{"kind":"STATUS","status":"DONE","message":"finished"}"""

proc runFakeTrnrun(deckFile: string): int =
  ## Plays the TRNRun behaviour named by `deckFile`; returns its exit code.
  ##
  ## `done` floods progress, more than a pipe buffers, prints `DoneLines`, then
  ## `DoneLastLine` without a line break, and exits 0. `fail` reports `ERROR` and
  ## exits 1. `wait` reports progress, then exits 0 once the deck's `.release`
  ## file exists, leaving a `.finished` file. `args` writes its arguments, one
  ## per line, to the deck's `.args` file. Any other mode exits 0 silently.
  result = 0
  case deckFile.splitFile().name.split('-')[0]
  of "done":
    for _ in 1..2_000:
      stdout.writeLine(ProgressLine)
    for line in DoneLines:
      stdout.writeLine(line)
    stdout.write(DoneLastLine)
  of "fail":
    stdout.writeLine("""{"kind":"STATUS","status":"ERROR","message":"Fake failure"}""")
    result = 1
  of "wait":
    stdout.writeLine(ProgressLine)
    stdout.flushFile()
    var waitedMs = 0
    while not fileExists(deckFile.changeFileExt("release")) and waitedMs < WaitLimitMs:
      sleep(10)
      waitedMs += 10
    writeFile(deckFile.changeFileExt("finished"), "")
  of "args":
    writeFile(deckFile.changeFileExt("args"), commandLineParams().join("\n"))
  else:
    discard

proc createDeckDir*(): string =
  ## A new empty temporary directory for decks.
  return createTempDir("trnrund-", "")

proc createDeck*(dir, name: string): string =
  ## Writes an empty deck `name` in `dir` and returns its path.
  result = dir / name
  writeFile(result, "")

proc releaseDeck*(deckFile: string) =
  ## Lets a `wait` run finish.
  writeFile(deckFile.changeFileExt("release"), "")

if paramCount() >= 1 and paramStr(1).endsWith(".dck"):
  quit(runFakeTrnrun(paramStr(1)))
