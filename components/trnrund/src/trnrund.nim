## Implements the trnrund command-line interface.
##
## Entry point for the daemon that runs TRNSYS simulations on behalf of one
## client. The client exchanges one JSON object per line over stdin and stdout;
## see `protocol` for the requests. stdout carries replies only. When the client
## closes stdin, the daemon exits at once and the job object kills any TRNRun
## process still going.
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
  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --trnrun:PATH           TRNRun executable (default: trnrun.exe beside trnrund)
  --maxConcurrent:N       Simulations run at once (default: max(CPUs - 1, 1))

Read one JSON request per stdin line and write one JSON reply per stdout line:
  {"cmd":"add","runId":"1","deckFile":"model.dck"}
Replies come in request order, one per request.

Commands: add, changes, remove, shutdown.
changes takes an optional "since" revision and returns the current revision
with every simulation changed after it, and only the logs added after it;
since 0, the default, returns everything.
Closing stdin exits at once and kills running simulations. Startup failures
are written to stderr.

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

proc main(): int =
  ## Collects user input from the command line and serves client requests.
  ##
  ## Returns 0. Failures raise instead: `ValueError` for usage errors, mapped
  ## to exit code 2 at the top level, and anything else to 1.
  result = 0
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
        return 0
      of "version", "v":
        echo NimblePkgVersion
        return 0
      else:
        if not input.applyOption(parser.key, parser.val):
          let dashes = if parser.kind == cmdShortOption: "-" else: "--"
          raise newException(ValueError, "Unknown option: " & dashes & parser.key)
    of cmdArgument:
      raise newException(ValueError, "Unexpected argument: " & parser.key)

  daemonScheduler = newScheduler(input.trnrunPath, input.maxConcurrent)
  let scheduler = daemonScheduler
  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  createThread(reader, readRequests, scheduler.requestInbox)
  {.pop.}

  while true:
    let message = scheduler.nextRequest()
    if message.kind == mkClosed:
      return 0

    let (reply, shutdown) = scheduler.handleRequest(message.line)
    stdout.writeLine(reply)
    stdout.flushFile()
    if shutdown:
      scheduler.shutdown()
      return 0

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
    except ValueError as error:
      writeError(error.msg)
      2
    except CatchableError as error:
      writeError(error.msg)
      1
  quit(exitCode)
