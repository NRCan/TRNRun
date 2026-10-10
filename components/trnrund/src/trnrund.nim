## Implements the trnrund command-line interface.
##
## Entry point for the daemon that runs TRNSYS simulations on behalf of one
## client. The client exchanges one JSON object per line over stdin and stdout;
## see `protocol` for the requests. stdout carries replies only; simulations
## are read from the SQLite database, see `database`. When the client closes
## stdin, the daemon saves its unfinished runs as interrupted and exits at
## once, and the job object kills any TRNRun process still going.
##
## Option parsing itself lives in `cli`; this module owns executable metadata,
## drives the parser, and serves requests.

import std/parseopt
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

Read one JSON request per stdin line and write one JSON reply per stdout line:
  {"cmd":"add","runId":"1","deckFile":"model.dck"}
Replies come in request order, one per request. add replies at once with the
run's state, QUEUED or ACCEPTED.

Commands: ready, add, shutdown.
ready returns the databasePath holding every run's state and logs; poll it to
follow runs.
Closing stdin exits at once, killing running simulations and saving them as
FINISHED, interrupted. One daemon at a time may use a database. Startup
failures are written to stderr.

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

  daemonScheduler =
    newScheduler(input.trnrunPath, input.maxConcurrent, input.databasePath)
  let scheduler = daemonScheduler
  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  createThread(reader, readRequests, scheduler.requestInbox)
  {.pop.}

  while true:
    let message = scheduler.nextRequest()
    if message.kind == mkClosed:
      scheduler.abandon()
      return

    let (reply, shutdown) = scheduler.handleRequest(message.line)
    stdout.writeLine(reply)
    stdout.flushFile()
    if shutdown:
      scheduler.shutdown()
      return

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
