## Defines the TRNRun command-line surface.
##
## Owns the option vocabulary: the accepted GUI visibility spellings and the
## mapping from CLI keys onto `RunnerSettings`. Adding a setting means touching
## this module and `settings`, and nothing else.

import std/strutils
import ./[events, settings]

type
  CliInput* = object
    ## User input gathered from the command line.
    deckFile*, runId*: string
    settings*: RunnerSettings

const DefaultCliInput* = CliInput(settings: DefaultRunnerSettings)
  ## Starting point for parsing: no deck selected, stock settings.

proc parseGuiVisibility(value: string): TrnexeGuiVisibility =
  ## Parses a case-insensitive visibility spelling; raises `ValueError` on unknown input.
  case value.toLowerAscii()
  of "keep", "keepopen":
    guiKeepOpen
  of "auto", "autoclose":
    guiAutoClose
  of "min", "minimized":
    guiMinimized
  of "minauto", "minimizedauto":
    guiMinimizedAuto
  of "hidden":
    guiHidden
  else:
    raise newException(ValueError, "Invalid guiVisibility: " & value)

proc applyOption*(input: var CliInput, key, value: string): bool =
  ## Applies one option, returning false for an unknown `key`; raises `ValueError` on a bad value.
  case key
  of "deckFile":
    input.deckFile = value
  of "runId":
    input.runId = value
  of "trnexePath":
    input.settings.trnexePath = value
  of "guiVisibility":
    input.settings.guiVisibility = parseGuiVisibility(value)
  of "waitForGui":
    input.settings.waitForGui = parseBool(value)
  of "waitForLst":
    input.settings.waitForLst = parseBool(value)
  of "waitForTmp":
    input.settings.waitForTmp = parseBool(value)
  of "detectTimeout":
    input.settings.detectTimeoutMs = parseInt(value)
  of "extraDelay":
    input.settings.extraDelayMs = parseInt(value)
  of "watchLog":
    input.settings.watchLog = parseBool(value)
  of "watchTmp":
    input.settings.watchTmp = parseBool(value)
  of "watchTimeout":
    input.settings.watchTimeoutMs = parseInt(value)
  of "stallTimeout":
    input.settings.stallTimeoutMs = parseInt(value)
  of "pollMs":
    input.settings.pollMs = parseInt(value)
  of "clean":
    input.settings.cleanOnSuccess = parseBool(value)
  of "killOnTimeout":
    input.settings.killOnTimeout = parseBool(value)
  of "killOnStall":
    input.settings.killOnStall = parseBool(value)
  of "severity":
    input.settings.severity = parseEnum[LogSeverity](value)
  of "writeEvents":
    input.settings.writeEvents = parseBool(value)
  else:
    return false

  return true
