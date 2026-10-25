## Defines and parses the TRNRun command line.
##
## Owns the option vocabulary: the accepted GUI visibility spellings and the
## mapping from CLI keys onto `RunnerSettings`. Adding a setting means touching
## this module and its `HelpText`, the `RunnerSettings` field in `events`, and
## its default in `settings`.

import std/[parseopt, strutils]
import ./[events, settings]

const HelpText* = """
trnrun - launch and monitor TRNSYS simulations

Usage:
  trnrun [deckFile] [options]     # no deckFile -> opens a file picker

Options:
  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --deckFile:PATH         Deck path; same as the positional argument
  --runId:ID              Attach an opaque run identifier to every event
  --trnexePath:PATH       Path to TrnEXE64.exe
  --guiVisibility:MODE    keep | auto | min | minauto | hidden   (default: hidden)
  --waitForGui:BOOL       (default: true)
  --waitForLst:BOOL       (default: true)
  --waitForTmp:BOOL       (default: false)
  --detectTimeout:MS      Readiness timeout, 0 = unlimited (default: 300000)
  --extraDelay:MS         (default: 0)
  --watchLog:BOOL         (default: true)
  --watchTmp:BOOL         Needed for stall detection (default: false)
  --watchTimeout:MS       0 = unlimited (default: 0)
  --stallTimeout:MS       0 = disabled (default: 0)
  --pollMs:MS             (default: 100)
  --clean:BOOL            (default: false)
  --killOnTimeout:BOOL    (default: false)
  --killOnStall:BOOL      (default: false)
  --severity:LEVEL        Notice | Warning | Fatal (default: Notice)
  --writeEvents:BOOL      (default: false)

Exit codes: 0 done  1 fatal  2 usage error  124 timeout  125 stalled  130 cancelled"""

type
  CliInput* = object
    ## User input gathered from the command line.
    deckFile*, runId*: string
    settings*: RunnerSettings

  CliAction* = enum
    caRun ## Run one simulation with the parsed input.
    caHelp ## Show `HelpText` and exit.
    caVersion ## Show the version and exit.

  CliCommand* = object
    ## What the command line asks TRNRun to do.
    action*: CliAction
    input*: CliInput ## `DefaultCliInput` unless `action` is `caRun`.

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

proc parseMs(key, value: string, minimum: int = 0): int =
  ## Parses a millisecond count; raises `ValueError` if malformed or below `minimum`.
  result = parseInt(value)
  if result < minimum:
    raise newException(ValueError, "Invalid " & key & ": must be >= " & $minimum & ", got " & value)

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
    input.settings.detectTimeoutMs = parseMs(key, value)
  of "extraDelay":
    input.settings.extraDelayMs = parseMs(key, value)
  of "watchLog":
    input.settings.watchLog = parseBool(value)
  of "watchTmp":
    input.settings.watchTmp = parseBool(value)
  of "watchTimeout":
    input.settings.watchTimeoutMs = parseMs(key, value)
  of "stallTimeout":
    input.settings.stallTimeoutMs = parseMs(key, value)
  of "pollMs":
    input.settings.pollMs = parseMs(key, value, minimum = 1)
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

proc parseCommandLine*(args: openArray[string]): CliCommand =
  ## Parses TRNRun's arguments, such as `commandLineParams()`; `ValueError` if one is invalid.
  result = CliCommand(action: caRun, input: DefaultCliInput)
  if args.len == 0:
    return # `initOptParser` would parse the process's own command line instead.
  var parser = initOptParser(@args)
  for kind, key, value in parser.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "help", "h":
        return CliCommand(action: caHelp, input: DefaultCliInput)
      of "version", "v":
        return CliCommand(action: caVersion, input: DefaultCliInput)
      else:
        if not result.input.applyOption(key, value):
          let dashes = if kind == cmdShortOption: "-" else: "--"
          raise newException(ValueError, "Unknown option: " & dashes & key)
    of cmdArgument:
      if result.input.deckFile != "":
        raise newException(ValueError, "Unexpected argument: " & key)
      result.input.deckFile = key
    of cmdEnd:
      discard
