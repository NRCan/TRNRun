## Small queue-protocol fixture for MATLAB pipe and cleanup tests.

when not defined(windows):
  {.error: "fake_queue is Windows-only".}

import std/[json, os, osproc, strutils]

proc emit(node: JsonNode) =
  stdout.writeLine($node)
  stdout.flushFile()

proc accepted(runID: string) =
  emit(%*{"kind": "QUEUE", "event": "ACCEPTED", "timestamp": "t", "runID": runID})

proc completed(runID: string, exitCode = 0) =
  emit(%*{
    "kind": "QUEUE",
    "event": "COMPLETED",
    "timestamp": "t",
    "runID": runID,
    "exitCode": exitCode,
  })

proc childMain() =
  while true:
    sleep(1000)

proc queueMain() =
  var line = ""
  while stdin.readLine(line):
    if line.len == 0:
      continue
    let request = parseJson(line)
    let
      runID = request["runID"].getStr()
      deck = request["deckFile"].getStr()

    if deck.contains("crash"):
      stderr.writeLine("intentional queue crash — échec")
      stderr.flushFile()
      quit(7)

    if deck.contains("blocked"):
      sleep(1500)

    accepted(runID)

    if deck.contains("long-stderr"):
      stderr.writeLine(repeat("a", 1001))
      stderr.writeLine(repeat("b", 999) & "😀suffix")
      stderr.writeLine(repeat("c", 998) & "😀suffix")
      stderr.writeLine("")
      stderr.writeLine("after truncation")
      stderr.flushFile()

    if deck.contains("blank"):
      stdout.writeLine("")
      stdout.flushFile()

    if deck.contains("tree"):
      let child = startProcess(
        getAppFilename(),
        args = @["--child"],
        options = {poDaemon},
      )
      emit(%*{
        "kind": "TEST",
        "runID": runID,
        "childPid": child.processID,
        "message": "owned child",
      })
      while true:
        sleep(1000)

    if deck.contains("flood"):
      for index in 0 ..< 5000:
        stderr.writeLine("stderr-" & $index & "-é")
        stderr.flushFile()
        emit(%*{
          "kind": "LOG",
          "runID": runID,
          "timestamp": "t",
          "severity": "Notice",
          "messageCode": index,
          "message": "débit élevé",
        })
    else:
      emit(%*{
        "kind": "STATUS",
        "runID": runID,
        "timestamp": "t",
        "status": "DONE",
        "message": "terminé — ΔT",
      })

    completed(runID)

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "--child":
    childMain()
  else:
    queueMain()
