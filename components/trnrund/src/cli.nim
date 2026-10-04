## Defines the TRNRun daemon command-line surface.
##
## Owns the option vocabulary: the defaults derived from the executable and
## machine, and the mapping from CLI keys onto `CliInput`.

import std/[cpuinfo, os, strutils]

type
  CliInput* = object
    ## User input gathered from the command line.
    trnrunPath*: string
    maxConcurrent*: int

proc defaultCliInput*(): CliInput =
  ## Returns trnrun.exe beside trnrund and one worker per processor but one.
  result = CliInput(
    trnrunPath: getAppDir() / "trnrun.exe",
    maxConcurrent: max(countProcessors() - 1, 1),
  )

proc applyOption*(input: var CliInput, key, value: string): bool =
  ## Applies one option; false if `key` is unknown, `ValueError` if `value` is bad.
  case key
  of "trnrun":
    input.trnrunPath = value
  of "maxConcurrent":
    input.maxConcurrent = parseInt(value)
  else:
    return false

  return true
