## Implements the trnrunq command-line interface.
##
## A thin wrapper around `supervisor` that runs concurrent TRNSYS simulations
## through a bounded worker pool, exposes the worker count as a CLI flag, and
## maps failures onto process exit codes. Option parsing lives in `cli`.

import std/parseopt
import ./cli
import ./supervisor


const NimblePkgVersion {.strdefine.} = "unknown"
const HelpText = """trnrunq - run concurrent TRNRun simulations

Usage:
  trnrunq [--maxConcurrent:N]

Options:
  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --maxConcurrent:N       Maximum simultaneous runners (default: max(CPUs - 1, 1))

Read one JSON request per stdin line:
  {"runId":"1","deckFile":"model.dck","runnerPath":"trnrun.exe","runnerArgs":[]}

Requests use a fixed one-slot handoff channel. QUEUE/ACCEPTED is emitted only
when a worker picks up a request, before resolving or launching the runner.
A channel-buffered request remains unacknowledged until worker pickup.
QUEUE/COMPLETED follows runner exit and output forwarding.

EOF ends submission and drains all submitted requests. Queue lifecycle events
and merged child output are written to stdout. Queue-level fatal diagnostics
are written to stderr for humans.

Exit codes: 0 ok  1 fatal  2 usage error"""

proc main(): int =
  ## Parses the command line and serves the queue; raises `ValueError` on a usage error.
  ##
  ## Never calls `quit`, so cleanup in `serve` runs and every worker is joined.
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
