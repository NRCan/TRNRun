## Defines and parses the trnrund command line.

import std/[cpuinfo, os, parseopt, strutils]
import ./validate

export InputError

const HelpText* = """
trnrund - run TRNSYS simulations for one client

Usage:
  trnrund [options]

Options:
  -h, --help         Show this help and exit
  -v, --version      Show version and exit
  --trnrun:PATH      TRNRun executable (default: trnrun.exe beside trnrund)
  --maxConcurrent:N  Simulations run at once (default: max(CPUs - 1, 1))

Read one JSON request per stdin line and write one JSON reply per stdout line,
and nothing else:
  {"id":1,"cmd":"add","deckFile":"model.dck"}  ->  {"id":1,"ok":true,"runId":7,...}
Commands: ready, add, get, release, cancel, shutdown. Runs and their logs
stay in memory until released. Closing stdin exits at once, killing running
TRNRun. See README.md for the protocol.

Exit codes: 0 ok  1 fatal  2 usage error"""

type
  CliInput* = object
    ## Settings for a serving daemon; see `HelpText` for each option.
    trnrunPath*: string
    maxConcurrent*: int ## Not checked here; `newScheduler` rejects values below 1.

  CliAction* = enum
    caServe ## Serve a client with the parsed input.
    caHelp ## Show `HelpText` and exit.
    caVersion ## Show the version and exit.

  CliCommand* = object
    ## What the command line asks the daemon to do.
    action*: CliAction
    input*: CliInput ## The defaults unless `action` is `caServe`.

proc defaultCliInput*(): CliInput =
  ## Returns the input used for options the command line leaves out.
  CliInput(
    trnrunPath: getAppDir() / "trnrun.exe",
    maxConcurrent: max(countProcessors() - 1, 1),
  )

proc applyOption*(input: var CliInput, key, value: string): bool =
  ## Applies one option; false if `key` is unknown, `InputError` if `value` is bad.
  result = true
  case key
  of "trnrun":
    input.trnrunPath = value
  of "maxConcurrent":
    input.maxConcurrent =
      try:
        parseInt(value)
      except ValueError as error:
        raise newException(InputError, error.msg)
  else:
    result = false

proc parseCommandLine*(args: openArray[string]): CliCommand =
  ## Parses the daemon's arguments, such as `commandLineParams()`; `InputError` if one is invalid.
  result = CliCommand(action: caServe, input: defaultCliInput())
  if args.len == 0:
    return # `initOptParser` would parse the process's own command line instead.
  var parser = initOptParser(@args)
  for kind, key, value in parser.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "help", "h":
        return CliCommand(action: caHelp, input: defaultCliInput())
      of "version", "v":
        return CliCommand(action: caVersion, input: defaultCliInput())
      else:
        if not result.input.applyOption(key, value):
          let dashes = if kind == cmdShortOption: "-" else: "--"
          raise newException(InputError, "Unknown option: " & dashes & key)
    of cmdArgument:
      raise newException(InputError, "Unexpected argument: " & key)
    of cmdEnd:
      discard
