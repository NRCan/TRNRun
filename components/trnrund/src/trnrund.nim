## Starts the trnrund daemon, which runs TRNSYS simulations for one client.
##
## The client exchanges one JSON object per line over stdin and stdout, see
## `protocol`, and asks for the state and logs of its runs, which the daemon
## keeps in memory, see `store`. When the client closes stdin, the daemon exits
## at once, and the Job Object kills any TRNRun process still going.

import std/[os, winlean]
import ./[cli, job, messages, protocol, scheduler, server, threadstart]

var
  daemonScheduler: Scheduler
    ## Global so its channels outlive `main`; the reader and workers point into them.
  reader: Thread[ptr Channel[Message]]
    ## Global so it outlives `main`. Never joined: it blocks on stdin until exit.

proc readRequests(inbox: ptr Channel[Message]) {.thread.} =
  ## Posts each stdin line to the scheduler, then reports that the client left.
  var line = ""
  try:
    while stdin.readLine(line):
      inbox[].send(Message(kind: mkRequest, line: line))
  except IOError:
    discard # A broken pipe means the client is gone, like a closed one.
  inbox[].send(Message(kind: mkClosed))

proc writeLines(lines: seq[string]): bool {.nimcall, gcsafe, raises: [].} =
  ## Writes reply lines to the client; false once it is gone.
  # `WriteFile` bypasses the C runtime's buffer, so a write cancelled at exit
  # leaves nothing for the exit to flush and block on.
  var
    text = ""
    written = 0'i32
  for line in lines:
    text.add(line)
    text.add('\n')
  let output = getStdHandle(STD_OUTPUT_HANDLE)
  writeFile(output, addr text[0], int32(text.len), addr written, nil) != 0 and
    written == int32(text.len)

proc keepStdHandlesPrivate() =
  ## Stops TRNRun children inheriting the client's pipes, so stdout ends with the daemon.
  for kind in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
    let handle = getStdHandle(kind)
    if handle != 0 and handle != INVALID_HANDLE_VALUE:
      discard setHandleInformation(handle, HANDLE_FLAG_INHERIT, 0)

proc main() =
  ## Parses the command line, then serves the client until it leaves.
  let command = parseCommandLine(commandLineParams())
  case command.action
  of caHelp:
    echo HelpText
  of caVersion:
    echo NimblePkgVersion
  of caServe:
    let input = command.input
    keepStdHandlesPrivate()
    initJobGuard()
    daemonScheduler = newScheduler(input.trnrunPath, input.maxConcurrent)
    reader.startThread(readRequests, daemonScheduler.requestInbox)
    daemonScheduler.serve(writeLines)

proc writeError(message: string) =
  ## Reports a fatal diagnostic for humans. Clients must not parse stderr.
  try:
    stderr.writeLine(message)
    stderr.flushFile()
  except IOError:
    discard

when isMainModule:
  let exitCode =
    try:
      main()
      0
    except InputError as error:
      writeError(error.msg)
      2
    except CatchableError as error:
      writeError(error.msg)
      1
  quit(exitCode)
