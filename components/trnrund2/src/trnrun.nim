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

const
  ReadSize = 4096
  KillWaitMs = 5000 ## How long `kill` waits for TRNRun to exit before giving up.

proc launch*(trnrunPath, deckFile: string, trnrunArgs: seq[string]): Trnrun =
  ## Starts `trnrunPath` on `deckFile` with `trnrunArgs` and no console; `OSError` on failure.
  let process = startProcess(
    trnrunPath,
    args = @[deckFile] & trnrunArgs,
    options = {poStdErrToStdOut, poDaemon},
  )
  return Trnrun(process: process)

proc drain(self: var Trnrun) =
  ## Appends everything TRNRun wrote so far to `pending`; never blocks.
  while self.process.hasData:
    let start = self.pending.len
    self.pending.setLen(start + ReadSize)
    let count = self.process.outputStream.readData(addr self.pending[start], ReadSize)
    self.pending.setLen(start + count)

proc takeLines(pending: var string): seq[string] =
  ## Removes the complete lines from the start of `pending` and returns them without line breaks.
  result = @[]
  var
    lineStart = 0
    lineEnd = pending.find('\n')
  while lineEnd >= 0:
    result.add(pending[lineStart..<lineEnd])
    lineStart = lineEnd + 1
    lineEnd = pending.find('\n', lineStart)
  if lineStart > 0:
    pending.delete(0..<lineStart)

proc readLines*(self: var Trnrun): seq[string] =
  ## The complete lines TRNRun wrote since the last call, without line breaks; never blocks.
  self.drain()
  return self.pending.takeLines()

proc readLastLines*(self: var Trnrun): seq[string] =
  ## `readLines`, plus a last line without a line break; call once TRNRun exited.
  result = self.readLines()
  if self.pending.len > 0:
    result.add(move self.pending)

proc exitCode*(self: Trnrun): Option[int] =
  ## TRNRun's exit code, or none while it runs; never blocks.
  # Windows reports a process that exited with 259 (`STILL_ACTIVE`) as running; TRNRun never does.
  let code = self.process.peekExitCode()
  return if code == -1: none(int) else: some(code)

proc kill*(self: Trnrun) =
  ## Kills TRNRun and waits for it to exit; `OSError` if it cannot be killed.
  # TRNRun keeps TrnEXE in a kill-on-close Job Object, so killing TRNRun stops both.
  self.process.kill()
  # On Windows `kill` ignores a failed TerminateProcess, so an unbounded wait could hang the daemon.
  if self.process.waitForExit(KillWaitMs) == -1:
    raise newException(OSError, "TRNRun still running " & $KillWaitMs & " ms after being killed")

proc close*(self: Trnrun) {.inline.} =
  ## Releases TRNRun's handles and pipes; call once it exited.
  self.process.close()
