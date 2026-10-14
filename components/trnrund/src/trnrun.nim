## Launches TRNRun processes and captures their output.
##
## `launch` runs on the scheduler thread, which then owns the `Process` and
## cancels a run by killing it. `captureOutput` runs on a worker thread: it
## blocks reading TRNRun's merged stdout and stderr until the pipe ends, which
## happens when TRNRun exits or is killed, then waits for the exit code. TRNRun
## validates the deck itself and reports a missing one as an `ERROR` status.
##
## Launching on one thread keeps launches from overlapping, so no TRNRun
## inherits the pipe of another, which would keep that pipe open. Children
## inherit the daemon's kill-on-close Job Object, so they cannot outlive it.
## Killing TRNRun also stops its TrnEXE, which TRNRun keeps in a kill-on-close
## Job Object of its own.

import std/[options, oserrors, osproc, strutils, winlean]

type
  OutputCallback* = proc(line: string) {.gcsafe, raises: [].}

  Launched* = object
    process*: Process ## Owned by the launching thread; close it after the capture ends.
    output*: Handle ## Read end of the merged output; closed with `process`.
    waitHandle*: Handle ## For `captureOutput`, which closes it.

  CaptureResult* = tuple
    exitCode: Option[int] ## None when it could not be read.
    error: string ## Capture failure; empty otherwise.

const
  ErrorBrokenPipe = 109'i32 # Missing from winlean: the writing end closed.
  ReadSize = 4096
  WaitAccess = SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION or PROCESS_TERMINATE

proc release(process: Process) =
  ## Kills a still-running TRNRun and closes its handles and pipes.
  try:
    if process.running:
      process.kill()
  finally:
    process.close()

proc launch*(
    runId: int, deckFile, trnrunPath: string, trnrunArgs: openArray[string]
): Launched =
  ## Starts TRNRun on `deckFile` with `trnrunArgs` and `--runId:<runId>`.
  ## Raises `OSError` when it cannot start.
  let process = startProcess(
    trnrunPath,
    args = @[deckFile] & @trnrunArgs & @["--runId:" & $runId],
    options = {poStdErrToStdOut, poDaemon},
  )
  # The scheduler's `Process` keeps TRNRun's process ID from being reused meanwhile.
  let waitHandle = openProcess(WaitAccess, 0, process.processID.DWORD)
  if waitHandle == 0:
    let error = osLastError()
    try:
      process.release()
    except CatchableError:
      discard
    raiseOSError(error, "Cannot wait for TRNRun")
  Launched(process: process, output: Handle(process.outputHandle), waitHandle: waitHandle)

proc forwardLines(pending: var string, onOutput: OutputCallback) =
  ## Forwards each complete line in `pending`, without its line break, and
  ## keeps the incomplete rest.
  var start = 0
  while true:
    let newline = pending.find('\n', start)
    if newline < 0:
      break
    var stop = newline
    if stop > start and pending[stop - 1] == '\r':
      dec stop
    onOutput(pending[start ..< stop])
    start = newline + 1
  if start > 0:
    pending.delete(0 ..< start)

proc captureOutput*(output, process: Handle, onOutput: OutputCallback): CaptureResult =
  ## Forwards every output line until the pipe ends, then waits for TRNRun to
  ## exit and closes `process`.
  ##
  ## A failed read kills TRNRun, so it cannot block on a full pipe, and is
  ## reported as the error. Callbacks run on the calling thread.
  result = (exitCode: none(int), error: "")
  var
    buffer = default(array[ReadSize, char])
    pending = ""
  while true:
    var read = 0'i32
    if readFile(output, addr buffer[0], ReadSize.int32, addr read, nil) == 0:
      let error = osLastError()
      if error.int32 notin [ErrorBrokenPipe, ERROR_HANDLE_EOF.int32]:
        result.error = "Cannot read TRNRun output: " & osErrorMsg(error)
        discard terminateProcess(process, 1)
      break
    if read == 0:
      break
    let start = pending.len
    pending.setLen(start + read)
    copyMem(addr pending[start], addr buffer[0], read)
    forwardLines(pending, onOutput)
  if pending.len > 0:
    pending.add('\n')
    forwardLines(pending, onOutput)

  discard waitForSingleObject(process, INFINITE)
  var exitCode = 0'i32
  if getExitCodeProcess(process, exitCode) != 0:
    result.exitCode = some(exitCode.int)
  elif result.error.len == 0:
    result.error = "Cannot read the TRNRun exit code: " & osErrorMsg(osLastError())
  discard closeHandle(process)
