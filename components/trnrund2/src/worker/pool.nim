## Runs TRNRun simulations, at most `maxWorkers` at once, and keeps them in memory.
##
## Everything happens on the caller's thread. The caller must call `update`
## regularly: it records the events TRNRun wrote, finishes the simulations
## whose TRNRun exited, and starts queued ones on the workers they freed.
## Nothing here knows about the client protocol.

import std/[algorithm, options, sequtils, tables]
import ./[simulation, trnrun]

export simulation

type Pool* = object
  ## Every simulation not released yet, and the TRNRun running each started one.
  trnrunPath: string
  maxWorkers: int
  lastSimId: int
  simulations: Table[int, Simulation]
  queue: seq[int] ## Queued simIds, oldest first.
  running: Table[int, Trnrun]

proc diagnose(message: string) =
  ## Writes a diagnostic to stderr, which stays free of protocol traffic.
  try:
    stderr.writeLine("trnrund2: ", message)
  except IOError:
    discard

proc recordLines(simulation: var Simulation, lines: seq[string]) =
  ## Saves the TRNRun event in each output line.
  for line in lines:
    simulation.recordLine(line)

proc startQueued(pool: var Pool) =
  ## Starts the oldest queued simulations while a worker is free.
  while pool.running.len < pool.maxWorkers and pool.queue.len > 0:
    let simId = pool.queue[0]
    pool.queue.delete(0)
    template simulation: untyped = pool.simulations[simId]
    try:
      pool.running[simId] = launch(pool.trnrunPath, simulation.deckFile, simulation.trnrunArgs)
      simulation.start()
    except OSError as error:
      diagnose("cannot start simulation " & $simId & ": " & error.msg)
      simulation.finish(none(int), "Cannot start TRNRun: " & error.msg)

# Public API

proc initPool*(trnrunPath: string, maxWorkers: int): Pool =
  ## An empty pool running `trnrunPath` on at most `maxWorkers` (>= 1) simulations at once.
  doAssert maxWorkers >= 1, "maxWorkers must be at least 1"
  Pool(trnrunPath: trnrunPath, maxWorkers: maxWorkers)

proc add*(
    pool: var Pool,
    deckFile: string,
    trnrunArgs: seq[string] = @[],
    label: Option[string] = none(string),
): int =
  ## Queues a simulation of `deckFile`, starting it at once if a worker is free; returns its simId.
  inc pool.lastSimId
  result = pool.lastSimId
  pool.simulations[result] = initSimulation(result, deckFile, trnrunArgs, label)
  pool.queue.add(result)
  pool.startQueued()

proc get*(pool: Pool, simId: int): Option[Simulation] =
  ## The simulation `simId`, or none if it was never added or is released.
  if simId in pool.simulations: some(pool.simulations[simId]) else: none(Simulation)

proc list*(pool: Pool, state: SimulationState): seq[Simulation] =
  ## Every simulation not released yet that is in `state`, oldest first.
  result = @[]
  for simulation in pool.simulations.values:
    if simulation.state == state:
      result.add(simulation)
  result = result.sortedByIt(it.simId)

proc update*(pool: var Pool) =
  ## Records TRNRun output, finishes the simulations whose TRNRun exited, then starts queued ones.
  var exited: seq[int] = @[]
  for simId, trnrun in pool.running.mpairs:
    pool.simulations[simId].recordLines(trnrun.readLines())
    let exitCode = trnrun.exitCode()
    if exitCode.isSome:
      pool.simulations[simId].recordLines(trnrun.readLastLines())
      pool.simulations[simId].finish(exitCode)
      exited.add(simId)
  for simId in exited:
    pool.running[simId].close()
    pool.running.del(simId)
  pool.startQueued()

proc cancel*(pool: var Pool, simId: int): bool =
  ## Cancels a queued or running simulation, killing its TRNRun; false if unknown or finished.
  if simId notin pool.simulations or pool.simulations[simId].state == ssFinished:
    return false
  if simId in pool.running:
    try:
      pool.running[simId].kill()
    except OSError as error:
      diagnose("cannot cancel simulation " & $simId & ": " & error.msg)
      return false
    pool.simulations[simId].recordLines(pool.running[simId].readLastLines())
    pool.simulations[simId].cancel()
    pool.running[simId].close()
    pool.running.del(simId)
  else:
    pool.queue.delete(pool.queue.find(simId))
    pool.simulations[simId].cancel()
  pool.startQueued()
  true

proc release*(pool: var Pool, simId: int): bool =
  ## Forgets a finished simulation and its logs; false if unknown, queued or running.
  if simId notin pool.simulations or pool.simulations[simId].state != ssFinished:
    return false
  pool.simulations.del(simId)
  true

proc stop*(pool: var Pool) =
  ## Cancels every queued and running simulation; call before the daemon exits.
  for simId in pool.queue:
    pool.simulations[simId].cancel()
  pool.queue.setLen(0)
  for simId in toSeq(pool.running.keys):
    discard pool.cancel(simId)
