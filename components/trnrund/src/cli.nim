## Defines the TRNRun daemon command-line surface.
##
## Owns the option vocabulary: the defaults derived from the executable and
## machine, and the mapping from CLI keys onto `CliInput`.

import std/[cpuinfo, os, strutils]

type CliInput* = object
  ## User input gathered from the command line.
  trnrunPath*: string
  maxConcurrent*: int

proc defaultCliInput*(): CliInput =
  ## Returns daemon defaults: the TRNRun beside trnrund, and one worker per
  ## processor but one.
  result = CliInput(
    trnrunPath: getAppDir() / "trnrun.exe",
    maxConcurrent: max(countProcessors() - 1, 1),
  )

proc applyOption*(input: var CliInput, key, value: string): bool =
  ## Applies one CLI option, returning false when `key` is unknown.
  ##
  ## Raises `ValueError` when `value` does not parse for a known key, letting
  ## the caller's error boundary report it.
  case key
  of "trnrun":
    input.trnrunPath = value
  of "maxConcurrent":
    input.maxConcurrent = parseInt(value)
  else:
    return false

  return true
