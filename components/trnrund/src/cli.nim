## Defines the TRNRun daemon command-line options and their defaults.

import std/[cpuinfo, os, strutils]
import ./validate

export InputError

type
  CliInput* = object
    trnrunPath*: string
    maxConcurrent*: int
    databasePath*: string

proc defaultCliInput*(): CliInput =
  ## Returns the input used for options the command line leaves out.
  result = CliInput(
    trnrunPath: getAppDir() / "trnrun.exe",
    maxConcurrent: max(countProcessors() - 1, 1),
    databasePath: "trnrund.sqlite3",
  )

proc applyOption*(input: var CliInput, key, value: string): bool =
  ## Applies one option; false if `key` is unknown, `InputError` if `value` is bad.
  result = true
  case key
  of "trnrun":
    input.trnrunPath = value
  of "maxConcurrent":
    try:
      input.maxConcurrent = parseInt(value)
    except ValueError as error:
      raise newException(InputError, error.msg)
  of "database":
    if value.len == 0:
      raise newException(InputError, "'database' must not be empty")
    input.databasePath = value
  else:
    result = false
