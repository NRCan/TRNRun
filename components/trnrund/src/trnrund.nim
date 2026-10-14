## Implements the trnrund command-line interface.
##
## Entry point for the daemon that runs TRNSYS simulations on behalf of one
## client. The client exchanges one JSON object per line over stdin and stdout;
## see `protocol` for the requests. Simulations are read from the SQLite
## database, see `database`. When the client closes stdin, the daemon saves its
## unfinished runs as interrupted and exits at once, and the job object kills
## any TRNRun process still going.
##
## Option parsing itself lives in `cli`; this module owns executable metadata,
## drives the parser, and connects the protocol to stdin and stdout.

import std/[parseopt, winlean]
import ./cli
import ./messages
import ./protocol
import ./scheduler

const NimblePkgVersion {.strdefine.} = "unknown"
const HelpText = """trnrund - run TRNSYS simulations for one client

Usage:
  trnrund [options]

Options:
  -h, --help         Show this help and exit
  -v, --version      Show version and exit
  --trnrun:PATH      TRNRun executable (default: trnrun.exe beside trnrund)
  --maxConcurrent:N  Simulations run at once (default: max(CPUs - 1, 1))
  --database:PATH    SQLite database clients read (default: trnrund.sqlite3)

Read one JSON request per stdin line and write one JSON reply per stdout line,
in request order. A request may carry an "id", which its reply repeats:
  {"id":1,"cmd":"add","deckFile":"model.dck"}  ->  {"id":1,"ok":true,"runId":7}
Rejected requests reply {"ok":false,"error":...}; database failures are fatal,
with no reply.

Commands: ready, subscribe, add, cancel, shutdown.
ready returns the databasePath holding every run's state and logs, this
daemon's sessionId, and the current revision and logId.
add takes deckFile, optional trnrunArgs and label, and returns the runId the
daemon assigned.
subscribe makes the daemon also write {"event":"changed","revision":N} after
each batch of saved changes; a subscribed client must keep reading stdout.
{"cmd":"cancel","runId":7} stops a queued or running simulation, killing its
TRNRun; it then finishes as CANCELLED. Finished runs are left unchanged.
{"cmd":"shutdown","cancelRunning":false} cancels queued runs, waits for running
ones (or kills them with cancelRunning true), then exits.
Closing stdin exits at once, killing running simulations and saving them as
FINISHED, interrupted. One daemon at a time may use a database. Keep it on a
local disk. Startup failures are written to stderr.

Exit codes: 0 ok  1 fatal  2 usage error"""

var daemonScheduler: Scheduler
  ## Global so its channels outlive `main`; the reader and workers point into them.
var reader: Thread[ptr Channel[Message]]
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

proc writeLines(lines: seq[string]): bool =
  ## Writes reply and notification lines to the client; false once it is gone.
  try:
    for line in lines:
      stdout.writeLine(line)
    stdout.flushFile()
    true
  except IOError:
    false

proc keepStdHandlesPrivate() =
  ## Stops TRNRun children from inheriting the client's pipes, so stdout ends
  ## when the daemon exits, not when its last child does.
  for kind in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
    let handle = getStdHandle(kind)
    if handle != 0 and handle != INVALID_HANDLE_VALUE:
      discard setHandleInformation(handle, HANDLE_FLAG_INHERIT, 0)

proc main() =
  ## Collects user input from the command line and serves client requests.
  ##
  ## Failures raise: `ValueError` for usage errors, mapped to exit code 2 at
  ## the top level, and anything else to 1.
  var input = defaultCliInput()

  var parser = initOptParser()
  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case parser.key
      of "help", "h":
        echo HelpText
        return
      of "version", "v":
        echo NimblePkgVersion
        return
      else:
        if not input.applyOption(parser.key, parser.val):
          let dashes = if parser.kind == cmdShortOption: "-" else: "--"
          raise newException(ValueError, "Unknown option: " & dashes & parser.key)
    of cmdArgument:
      raise newException(ValueError, "Unexpected argument: " & parser.key)

  keepStdHandlesPrivate()
  daemonScheduler = newScheduler(input.trnrunPath, input.maxConcurrent, input.databasePath)
  let scheduler = daemonScheduler
  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  createThread(reader, readRequests, scheduler.requestInbox)
  {.pop.}

  scheduler.serve(writeLines)

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
    except ValueError as error:
      writeError(error.msg)
      if daemonScheduler == nil: 2 else: 1 # Once serving, a ValueError is a bug, not a usage error.
    except CatchableError as error:
      writeError(error.msg)
      1
  quit(exitCode)
