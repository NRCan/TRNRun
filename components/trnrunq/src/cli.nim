## Defines the TRNRun Queue command-line surface.
##
## Owns the option vocabulary: the default worker count and mapping from CLI
## keys onto `CliInput`.

import std/[cpuinfo, strutils]


type CliInput* = object
  ## User input gathered from the command line.
  maxConcurrent*: int


proc defaultCliInput*(): CliInput =
  ## Returns queue defaults derived from the current machine.
  CliInput(maxConcurrent: max(countProcessors() - 1, 1))


proc applyOption*(input: var CliInput, key, value: string): bool =
  ## Applies one CLI option, returning false when `key` is unknown.
  case key
  of "maxConcurrent":
    input.maxConcurrent = parseInt(value)
  else:
    return false

  return true
