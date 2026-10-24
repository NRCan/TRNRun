## Runs TRNRun simulations, at most `maxWorkers` at once, and keeps them in memory.
##
## Everything happens on the caller's thread. The caller must call `update`
## regularly: it records the events TRNRun wrote, finishes the simulations
## whose TRNRun exited, and starts queued ones on the workers they freed.
## Nothing here knows about the client protocol.

import std/[algorithm, options, tables]
import ./[pipe, simulation, trnrun]

export simulation

type Pool* = object
  ## Every simulation not released yet, and the TRNRun running each started one.
  trnrunPath: string
  maxWorkers: int
  lastSimId: int
  simulations: Table[int, Simulation]
  queue: seq[int] ## Queued simIds, oldest first.
  running: Table[int, Trnrun]

proc startTrnrun(pool: var Pool, simId: int) =
  ## Starts TRNRun for simulation `simId`, finishing it with an error if TRNRun cannot start.
  template simulation: untyped = pool.simulations[simId]
  try:
    pool.running[simId] = launch(pool.trnrunPath, simulation.deckFile, simulation.trnrunArgs)
    simulation.start()
  except OSError as error:
    diagnose("cannot start simulation " & $simId & ": " & error.msg)
    simulation.finish(none(int), "Cannot start TRNRun: " & error.msg)

proc startQueued(pool: var Pool) =
  ## Starts the oldest queued simulations while a worker is free.
  while pool.running.len < pool.maxWorkers and pool.queue.len > 0:
    let simId = pool.queue[0]
    pool.queue.delete(0)
    pool.startTrnrun(simId)

proc recordOutput(pool: var Pool) =
  ## Records the lines every running TRNRun wrote since the last call.
  for simId, trnrun in pool.running.mpairs:
    pool.simulations[simId].recordLines(trnrun.readLines())

proc dropTrnrun(pool: var Pool, simId: int) =
  ## Records the last output of `simId`'s exited TRNRun, then closes and forgets it.
  pool.simulations[simId].recordLines(pool.running[simId].readLastLines())
  pool.running[simId].close()
  pool.running.del(simId)

proc finishExited(pool: var Pool) =
  ## Finishes the simulations whose TRNRun exited, freeing their workers.
  var exited: seq[(int, int)] = @[]
  for simId, trnrun in pool.running:
    let exitCode = trnrun.exitCode()
    if exitCode.isSome:
      exited.add((simId, exitCode.get()))
  for (simId, exitCode) in exited:
    pool.dropTrnrun(simId)
    pool.simulations[simId].finish(some(exitCode))

# Public API

proc initPool*(trnrunPath: string, maxWorkers: Positive): Pool =
  ## An empty pool running `trnrunPath` on at most `maxWorkers` simulations at once.
  Pool(trnrunPath: trnrunPath, maxWorkers: maxWorkers)

proc add*(
    pool: var Pool,
    deckFile: sink string,
    trnrunArgs: sink seq[string] = @[],
    label: sink Option[string] = none(string),
): int =
  ## Queues a simulation of `deckFile` and returns its simId.
  ##
  ## simIds start at 1 and are never reused, even after `release`. The
  ## simulation starts at once if a worker is free. If TRNRun cannot start, the
  ## simulation is already `FINISHED` with an error when this returns. Nothing
  ## is validated here; `deckFile` and `trnrunArgs` are passed to TRNRun as given.
  inc pool.lastSimId
  result = pool.lastSimId
  pool.simulations[result] = initSimulation(result, deckFile, trnrunArgs, label)
  pool.queue.add(result)
  pool.startQueued()

proc contains*(pool: Pool, simId: int): bool {.inline.} =
  ## Whether simulation `simId` was added and is not released yet.
  simId in pool.simulations

proc `[]`*(pool: Pool, simId: int): lent Simulation {.inline.} =
  ## The simulation `simId`, borrowed; `KeyError` unless `simId in pool`.
  pool.simulations[simId]

proc list*(pool: Pool, state: SimulationState): seq[Simulation] =
  ## Every simulation not released yet that is in `state`, oldest first.
  result = @[]
  for simulation in pool.simulations.values:
    if simulation.state == state:
      result.add(simulation)
  result = result.sortedByIt(it.simId)

proc update*(pool: var Pool) =
  ## Moves every simulation forward one step; never blocks.
  ##
  ## In order, it records the events every running TRNRun wrote, finishes the
  ## simulations whose TRNRun exited, and starts queued simulations on the
  ## workers that freed up. Call it often: TRNRun blocks once its output pipe
  ## is full, and nothing else reads that pipe.
  pool.recordOutput()
  pool.finishExited()
  pool.startQueued()

proc cancel*(pool: var Pool, simId: int): bool =
  ## Cancels a queued or running simulation; false if it is unknown or already finished.
  ##
  ## A running simulation has its TRNRun killed, its last output recorded, and
  ## is reported as interrupted. A queued one leaves the queue and is reported
  ## as not started. Both end `FINISHED` with status `CANCELLED`, and the freed
  ## worker starts the next queued simulation. Raises `OSError` if TRNRun
  ## cannot be killed, which leaves the simulation running.
  if simId notin pool.simulations or pool.simulations[simId].state == ssFinished:
    return false
  if simId in pool.running:
    pool.running[simId].kill()
    pool.dropTrnrun(simId)
  else:
    pool.queue.delete(pool.queue.find(simId))
  pool.simulations[simId].cancel() # Still RUNNING here, so it is reported as interrupted.
  pool.startQueued()
  true

proc release*(pool: var Pool, simId: int): bool =
  ## Forgets a finished simulation and its logs; false if unknown, queued or running.
  if simId notin pool.simulations or pool.simulations[simId].state != ssFinished:
    return false
  pool.simulations.del(simId)
  true
