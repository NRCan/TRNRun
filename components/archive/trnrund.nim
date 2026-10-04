## Implements the trnrund command-line interface.
##
## Command-line entry point for the TRNRun daemon: a long-lived process that
## runs TRNSYS simulations through a bounded worker pool, keeps the state of
## every simulation, and answers requests about it. It acts as a thin wrapper around
## `daemon`, exposing the worker count as a CLI flag and mapping failures onto
## process exit codes.
##
## Option parsing itself lives in `cli`; this module owns executable metadata,
## drives the parser, and reports the outcome.

import std/parseopt
import ./cli
import ./daemon


const NimblePkgVersion {.strdefine.} = "unknown"
const HelpText = """trnrund - serve TRNRun simulations over stdin/stdout

Usage:
  trnrund [--maxConcurrent:N]

Options:
  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --maxConcurrent:N       Maximum simultaneous runners (default: max(CPUs - 1, 1))

Read one JSON request per stdin line and write exactly one JSON reply line
per request to stdout, echoing the request "id":
  {"id":1,"cmd":"submit","runId":"a","deckFile":"model.dck","runnerPath":"trnrun.exe","runnerArgs":[]}
  {"id":2,"cmd":"snapshot","runId":"a"}
  {"id":3,"cmd":"list","since":0}
  {"id":4,"cmd":"wait","runId":"a"}
  {"id":5,"cmd":"shutdown"}

  {"id":1,"ok":true,"result":{...}}
  {"id":1,"ok":false,"error":"..."}

Each simulation is reported as its "runId" and daemon "state": QUEUED
(waiting for a worker), ACCEPTED (a worker is launching it), RUNNING (the
runner started), FINISHED.
Submit rejects missing decks or runners; relative paths resolve from the
daemon working directory. "list" replies with a "version"; passing it back as
"since" returns only the simulations that changed after it.
Omitting "runId" in wait targets every simulation. "wait" replies once its
simulations finish, so replies may arrive out of order.

"shutdown" refuses new simulations, drains the rest, replies, and exits.
Stdin EOF drops queued simulations, waits for running ones, and exits.
Daemon-level fatal diagnostics are written to stderr for humans.

Exit codes: 0 ok  1 fatal  2 usage error"""

proc main(): int =
  ## Collects user input from the command line and serves the daemon.
  ##
  ## Returns the process exit code: 0 ok, 1 fatal, 2 usage error.
  ##
  ## This procedure does not call `quit`, ensuring cleanup in `serve` can run
  ## and every worker is joined.
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
          raise newException(ValueError, "Unknown daemon option: --" & parser.key)
    of cmdArgument:
      raise newException(ValueError, "Unexpected positional argument: " & parser.key)

  serve(input.maxConcurrent)
  return 0

proc writeError(message: string) =
  ## Reports a fatal diagnostic for humans. Wrappers must not parse stderr.
  try:
    stderr.writeLine(message)
    stderr.flushFile()
  except IOError:
    discard

when isMainModule:
  let exitCode =
    try:
      main()
    except ValueError:
      writeError(getCurrentExceptionMsg())
      2
    except CatchableError:
      writeError(getCurrentExceptionMsg())
      1
  quit(exitCode)
