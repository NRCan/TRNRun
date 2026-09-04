## Implements the trnrunq command-line interface.
##
## Command-line entry point for running concurrent TRNSYS simulations through a
## bounded worker pool. It acts as a thin wrapper around `supervisor`, exposing
## the pool and pending-queue sizes as CLI flags and mapping failures onto
## process exit codes.
##
## Option parsing itself lives in `cli`; this module owns executable metadata,
## drives the parser, and reports the outcome.

import std/parseopt
import ./cli
import ./supervisor


const NimblePkgVersion {.strdefine.} = "unknown"
const HelpText = """trnrunq - run concurrent TRNRun simulations

Usage:
  trnrunq [--maxConcurrent:N] [--maxPending:N]

Options:
  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --maxConcurrent:N       Maximum simultaneous runners (default: max(CPUs - 1, 1))
  --maxPending:N          Maximum requests waiting for a runner (default: 0, unlimited)

Read one JSON request per stdin line:
  {"runId":"1","deckFile":"model.dck","runnerPath":"trnrun.exe","runnerArgs":[]}

EOF ends submission and waits for every accepted run. Child output is forwarded
unchanged to stdout. Diagnostics are written to stderr as plain text; they are
not a protocol and must not be read as run results.

Exit codes: 0 ok  1 fatal  2 usage error"""

proc main(): int =
  ## Collects user input from the command line and serves the queue.
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
          raise newException(ValueError, "Unknown queue option: --" & parser.key)
    of cmdArgument:
      raise newException(ValueError, "Unexpected positional argument: " & parser.key)

  serve(input.maxConcurrent, input.maxPending)
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
