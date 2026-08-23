## status.nim - simulation lifecycle status and outcomes.
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

func status*(outcome: SimResult): SimStatus =
  ## Maps a final simulation result to its terminal lifecycle status.
  case outcome
  of simDone: statusDone
  of simCancelled: statusCancelled
  of simFatal: statusError
  of simTimeout: statusTimeout
  of simStalled: statusStalled

func exitCode*(outcome: SimResult): int =
  ## Maps a final simulation result to a conventional process exit code.
  case outcome
  of simDone: 0
  of simCancelled: 130
  of simFatal: 1
  of simTimeout: 124
  of simStalled: 125

proc statusEvent*(status: SimStatus, timestamp: DateTime = now()): SimulationEvent =
  ## Creates a timestamped lifecycle event.
  SimulationEvent(
    kind: eventStatus,
    statusData: StatusEvent(timestamp: timestamp, status: status),
  )
