## Defines and parses the trnrund command line.

import std/[cpuinfo, os, parseopt, strutils]
import ./validate

export InputError

const
  NimblePkgVersion* {.strdefine.} = "unknown"
  HelpText* = """
trnrund - run TRNSYS simulations through TRNRun for one client

Usage:
  trnrund [options]

Options:
  -h, --help     Show this help and exit
  -v, --version  Show version and exit
  --trnrun:PATH  TRNRun executable (default: trnrun.exe beside trnrund)
  --workers:N    Simulations run at once (default: max(CPUs - 1, 1))

Read one JSON request per stdin line and write one JSON response per stdout
line, and nothing else; the client waits for each response before the next:
  {"cmd":"add","deckFile":"model.dck"}  ->  {"ok":true,"simId":1}
Commands: ready, add, get, cancel, release. Simulations and their logs stay
in memory until released. Closing stdin cancels every simulation and exits.
See README.md for the protocol.

Exit codes: 0 ok  1 fatal  2 usage error"""

type
  CliInput* = object
    ## Settings for a serving daemon; see `HelpText` for each option.
    trnrunPath*: string ## Not checked here; `main` checks the file exists.
    maxWorkers*: int

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
  return CliInput(
    trnrunPath: getAppDir() / "trnrun.exe",
    maxWorkers: max(countProcessors() - 1, 1),
  )

proc parseWorkers(value: string): int =
  ## The `--workers` count in `value`; `InputError` unless an integer of at least 1.
  result =
    try:
      parseInt(value)
    except ValueError as error:
      raise newException(InputError, "Invalid --workers: " & error.msg)
  if result < 1:
    raise newException(InputError, "--workers must be at least 1")

proc applyOption*(self: var CliInput, key, value: string): bool =
  ## Applies one option; false if `key` is unknown, `InputError` if `value` is bad.
  result = true
  case key
  of "trnrun":
    self.trnrunPath = value
  of "workers":
    self.maxWorkers = parseWorkers(value)
  else:
    result = false

proc parseCommandLine*(args: openArray[string]): CliCommand =
  ## Parses the daemon's arguments, such as `commandLineParams()`.
  ##
  ## Options left out keep their `defaultCliInput` values. `--help` or
  ## `--version` returns as soon as it is seen, so options after it are not
  ## checked. Raises `InputError` for an unknown option, a bad value or a
  ## positional argument.
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
