## Implements the trnrunq command-line interface.
##
## Command-line entry point for running concurrent TRNSYS simulations through a
## bounded worker pool. It acts as a thin wrapper around `supervisor`, exposing
## the pool size as a CLI flag and mapping failures onto process exit codes.
##
## The queue protocol itself lives in `request` and `outputsink`; this module
## only drives the parser and reports the outcome.

import std/[cpuinfo, parseopt, strutils]
import ./supervisor

const NimblePkgVersion {.strdefine.} = "unknown"

const HelpText = """trnrunq - run concurrent TRNRun simulations

Usage:
  trnrunq [--maxConcurrent:N]

Options:
  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --maxConcurrent:N       Maximum simultaneous runners (default: CPUs - 1)

Read one JSON request per stdin line:
  {"runId":"1","deckFile":"model.dck","runnerPath":"trnrun.exe","runnerArgs":[]}

EOF ends submission and waits for every accepted run. Child output is forwarded
unchanged to stdout. Diagnostics are written to stderr as plain text; they are
not a protocol and must not be read as run results.

Exit codes: 0 ok  1 fatal  2 usage error"""
  ## Usage text; must stay in step with the option cases in `main`.


proc requireInt(key, value: string): int =
  ## Parses an option value that must be a whole integer.
  ##
  ## Raises `ValueError` naming the option, which reads better at the error
  ## boundary than the stock `parseInt` message.
  result = 0
  if value.len == 0:
    raise newException(ValueError, "--" & key & " requires a value")
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, "--" & key & " must be an integer")

proc main(): int =
  ## Collects user input from the command line and serves the queue.
  ##
  ## Returns the process exit code: 0 ok, 1 fatal, 2 usage error.
  ##
  ## This procedure does not call `quit`, ensuring the `defer` and `finally`
  ## cleanup in `serve` can run and every worker is joined.
  var maxConcurrent = max(countProcessors() - 1, 1)

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
      of "maxConcurrent":
        maxConcurrent = requireInt(parser.key, parser.val)
        if maxConcurrent < 1:
          raise newException(ValueError, "--maxConcurrent must be at least 1")
      else:
        raise newException(ValueError, "Unknown queue option: --" & parser.key)
    of cmdArgument:
      raise newException(ValueError, "Unexpected positional argument: " & parser.key)

  serve(maxConcurrent)
  0

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
      # CLI trust boundary: usage errors stay distinct from runtime failures.
      writeError(getCurrentExceptionMsg())
      2
    except CatchableError:
      writeError(getCurrentExceptionMsg())
      1
  quit(exitCode)
