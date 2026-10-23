## Launches one TRNRun process, reads its output lines, and stops it.
##
## TRNRun writes its events to stdout, merged here with stderr into one pipe.
## Nothing waits on that pipe: the caller polls `readLines` and `exitCode`, and
## must keep reading so TRNRun never blocks on a full pipe.

import std/[options, osproc, streams, strutils]

type Trnrun* = object
  ## One started TRNRun and its output not yet ended by a line break.
  process: Process
  pending: string

const ReadSize = 4096

proc launch*(trnrunPath, deckFile: string, trnrunArgs: seq[string]): Trnrun =
  ## Starts `trnrunPath` on `deckFile` with `trnrunArgs`, without a console window; `OSError` on failure.
  let process = startProcess(
    trnrunPath,
    args = @[deckFile] & trnrunArgs,
    options = {poStdErrToStdOut, poDaemon},
  )
  Trnrun(process: process)

proc readLines*(trnrun: var Trnrun): seq[string] =
  ## The complete lines TRNRun wrote since the last call, without line breaks; never blocks.
  result = @[]
  while trnrun.process.hasData:
    let start = trnrun.pending.len
    trnrun.pending.setLen(start + ReadSize)
    let count = trnrun.process.outputStream.readData(addr trnrun.pending[start], ReadSize)
    trnrun.pending.setLen(start + count)
  var lineStart = 0
  while true:
    let newline = trnrun.pending.find('\n', lineStart)
    if newline < 0:
      break
    result.add(trnrun.pending[lineStart ..< newline])
    lineStart = newline + 1
  if lineStart > 0:
    trnrun.pending.delete(0 ..< lineStart)

proc readLastLines*(trnrun: var Trnrun): seq[string] =
  ## `readLines`, plus a last line without a line break; call once TRNRun exited.
  result = trnrun.readLines()
  if trnrun.pending.len > 0:
    result.add(trnrun.pending)
    trnrun.pending = ""

proc exitCode*(trnrun: Trnrun): Option[int] =
  ## TRNRun's exit code, or none while it runs; never blocks.
  # Windows reports a process that exited with 259 (`STILL_ACTIVE`) as running; TRNRun never does.
  let code = trnrun.process.peekExitCode()
  if code == -1: none(int) else: some(code)

proc kill*(trnrun: Trnrun) =
  ## Kills TRNRun and waits for it to exit; `OSError` if it cannot be killed.
  # TRNRun keeps TrnEXE in a kill-on-close Job Object, so killing TRNRun stops both.
  trnrun.process.kill()
  discard trnrun.process.waitForExit()

proc close*(trnrun: Trnrun) =
  ## Releases TRNRun's handles and pipes; call once it exited.
  trnrun.process.close()
