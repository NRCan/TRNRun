## Command-line entry point for bounded TRNRun supervision.
##
## The queue owns only its runner path and concurrency limit. Every other option
## is forwarded unchanged to each trnrun invocation.

import std/[cpuinfo, os, parseutils, strutils]
import ./supervisor


const NimblePkgVersion {.strdefine.} = "unknown"


type QueueOptions = object
  runnerPath: string
  maxConcurrent: int
  runnerArgs: seq[string]
  deckFiles: seq[string]


proc optionParts(argument: string): tuple[key, value: string, hasValue: bool] =
  let colon = argument.find(':', 2)
  let equals = argument.find('=', 2)
  var separator = -1

  if colon >= 0 and equals >= 0:
    separator = min(colon, equals)
  elif colon >= 0:
    separator = colon
  else:
    separator = equals

  if separator < 0:
    return (argument[2 .. ^1], "", false)

  (
    argument[2 ..< separator],
    argument[separator + 1 .. ^1],
    true,
  )

proc requireValue(key, value: string, hasValue: bool): string =
  if not hasValue or value.len == 0:
    raise newException(ValueError, "--" & key & " requires a value")
  value

proc parseInteger(key, value: string, hasValue: bool): int =
  result = 0
  let value = requireValue(key, value, hasValue)
  if parseInt(value, result) != value.len:
    raise newException(ValueError, "--" & key & " must be an integer")

proc writeHelp() =
  echo """trnrunq3 - supervise concurrent TRNRun simulations

Usage:
  trnrunq3 [queue options] deckFile [deckFile ...] [trnrun options]

Queue options:
  -h, --help                Show this help and exit
  -v, --version             Show version and exit
  --runnerPath:PATH         trnrun.exe path (default: beside trnrunq3)
  --maxConcurrent:N         Maximum simultaneous runners

All other options are forwarded unchanged to each trnrun process.
Stdout is strict JSONL containing event, output, and exit envelopes."""

proc defaultOptions(): QueueOptions =
  QueueOptions(
    runnerPath: "trnrun.exe",
    maxConcurrent: max(countProcessors() - 1, 1),
  )

proc parseCommandLine(): tuple[options: QueueOptions, shouldRun: bool] =
  result = (options: defaultOptions(), shouldRun: true)
  var forwardOnly = false

  for argument in commandLineParams():
    if not forwardOnly and argument == "--":
      forwardOnly = true
      continue

    if not forwardOnly and argument in ["-h", "--help"]:
      writeHelp()
      result.shouldRun = false
      return
    if not forwardOnly and argument in ["-v", "--version"]:
      echo NimblePkgVersion
      result.shouldRun = false
      return

    if not forwardOnly and argument.startsWith("--"):
      let (key, value, hasValue) = optionParts(argument)
      case key
      of "runnerPath":
        result.options.runnerPath = requireValue(key, value, hasValue)
      of "maxConcurrent":
        result.options.maxConcurrent = parseInteger(key, value, hasValue)
        if result.options.maxConcurrent < 1:
          raise newException(ValueError, "--maxConcurrent must be at least 1")
      of "deckFile":
        raise newException(
          ValueError,
          "trnrunq3 accepts deck files as positional arguments",
        )
      else:
        result.options.runnerArgs.add(argument)
    elif forwardOnly or argument.startsWith("-"):
      result.options.runnerArgs.add(argument)
    else:
      result.options.deckFiles.add(
        argument.absolutePath().normalizedPath()
      )

  if result.options.deckFiles.len == 0:
    raise newException(ValueError, "At least one deck file is required")

proc main(): int =
  let parsed = parseCommandLine()
  if not parsed.shouldRun:
    return 0

  var requests = newSeq[RunRequest](parsed.options.deckFiles.len)
  for index, deckFile in parsed.options.deckFiles:
    requests[index] = RunRequest(
      runId: index + 1,
      deckFile: deckFile,
      runnerPath: parsed.options.runnerPath,
      runnerArgs: parsed.options.runnerArgs,
    )

  let summary = superviseRuns(
    requests,
    maxConcurrent = parsed.options.maxConcurrent,
  )
  if summary.failed == 0: 0 else: 1

when isMainModule:
  let exitCode =
    try:
      main()
    except ValueError:
      try:
        stderr.writeLine("Error: ", getCurrentExceptionMsg())
      except IOError:
        discard
      2
    except CatchableError:
      try:
        stderr.writeLine("Fatal: ", getCurrentExceptionMsg())
      except IOError:
        discard
      1
  quit(exitCode)
