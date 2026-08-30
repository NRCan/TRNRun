## Defines simulation lifecycle statuses and outcomes.
##
## Creates lifecycle events and provides the canonical mappings from a final
## simulation result to its wire-protocol status and process exit code.

import std/times
import ./events

type
  SimResult* = enum
    ## Final outcome of a simulation run.
    simDone # Process exited and simulation reached 100 %.
    simCancelled # Process exited before simulation reached 100 %.
    simFatal # Process crashed, failed to start, or logged a fatal error.
    simTimeout # Process still running but did not finish in time.
    simStalled # Simulation time stopped advancing for too long.
    simInvalid # Deck or TrnEXE path failed validation; nothing was launched.

func status*(outcome: SimResult): SimStatus =
  ## Maps a final simulation result to its terminal lifecycle status.
  case outcome
  of simDone: statusDone
  of simCancelled: statusCancelled
  of simFatal: statusError
  of simTimeout: statusTimeout
  of simStalled: statusStalled
  of simInvalid: statusError

func exitCode*(outcome: SimResult): int =
  ## Maps a final simulation result to a conventional process exit code.
  ##
  ## `simInvalid` keeps the usage-error code so bad inputs stay distinct from
  ## a simulation that started and then failed.
  case outcome
  of simDone: 0
  of simCancelled: 130
  of simFatal: 1
  of simTimeout: 124
  of simStalled: 125
  of simInvalid: 2

proc statusEvent*(
    status: SimStatus,
    timestamp: DateTime = now(),
    message: string = "",
): SimulationEvent =
  ## Creates a timestamped lifecycle event; `message` is empty by default.
  SimulationEvent(
    kind: eventStatus,
    statusData: StatusEvent(
      timestamp: timestamp,
      status: status,
      message: message,
    ),
  )

