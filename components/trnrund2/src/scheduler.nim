## Runs TRNRun simulations, at most `maxWorkers` at once, and keeps them in memory.
##
## Everything happens on the caller's thread. The caller must call `update`
## regularly: it records the events TRNRun wrote, finishes the simulations
## whose TRNRun exited, and starts queued ones on the workers they freed.
## Nothing here knows about the client protocol.

import std/[algorithm, options, tables]
import ./[pipe, simulation, trnrun]

export simulation

type Scheduler* = object
  ## Every simulation not released yet, and the TRNRun running each started one.
  trnrunPath: string
  maxWorkers: int
  lastSimId: int
  simulations: Table[int, Simulation]
  queue: seq[int] ## Queued simIds, oldest first.
  running: Table[int, Trnrun]

proc startTrnrun(self: var Scheduler, simId: int) =
  ## Starts TRNRun for simulation `simId`, finishing it with an error if TRNRun cannot start.
  template simulation: untyped = self.simulations[simId]
  try:
    self.running[simId] =
      launch(self.trnrunPath, simulation.deckFile, simulation.trnrunArgs)
    simulation.start()
  except OSError as error:
    diagnose("cannot start simulation " & $simId & ": " & error.msg)
    simulation.finish(none(int), "Cannot start TRNRun: " & error.msg)

proc startQueued(self: var Scheduler) =
  ## Starts the oldest queued simulations while a worker is free.
  while self.running.len < self.maxWorkers and self.queue.len > 0:
    let simId = self.queue[0]
    self.queue.delete(0)
    self.startTrnrun(simId)

proc recordOutput(self: var Scheduler) =
  ## Records the lines every running TRNRun wrote since the last call.
  for simId, trnrun in self.running.mpairs:
    self.simulations[simId].recordLines(trnrun.readLines())

proc dropTrnrun(self: var Scheduler, simId: int) =
  ## Records the last output of `simId`'s exited TRNRun, then closes and forgets it.
  self.simulations[simId].recordLines(self.running[simId].readLastLines())
  self.running[simId].close()
  self.running.del(simId)

proc finishExited(self: var Scheduler) =
  ## Finishes the simulations whose TRNRun exited, freeing their workers.
  var exited: seq[(int, int)] = @[]
  for simId, trnrun in self.running:
    let exitCode = trnrun.exitCode()
    if exitCode.isSome:
      exited.add((simId, exitCode.get()))
  for (simId, exitCode) in exited:
    self.dropTrnrun(simId)
    self.simulations[simId].finish(some(exitCode))

# --------------------------
# Public API
# --------------------------

proc initScheduler*(trnrunPath: string, maxWorkers: Positive): Scheduler =
  ## An empty scheduler running `trnrunPath` on at most `maxWorkers` simulations at once.
  Scheduler(trnrunPath: trnrunPath, maxWorkers: maxWorkers)

proc add*(
    self: var Scheduler,
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
  inc self.lastSimId
  result = self.lastSimId
  self.simulations[result] = initSimulation(result, deckFile, trnrunArgs, label)
  self.queue.add(result)
  self.startQueued()

proc contains*(self: Scheduler, simId: int): bool {.inline.} =
  ## Whether simulation `simId` was added and is not released yet.
  simId in self.simulations

proc `[]`*(self: Scheduler, simId: int): lent Simulation {.inline.} =
  ## The simulation `simId`, borrowed; `KeyError` unless `simId in self`.
  self.simulations[simId]

proc list*(self: Scheduler, state: SimulationState): seq[Simulation] =
  ## Every simulation not released yet that is in `state`, oldest first.
  result = @[]
  for simulation in self.simulations.values:
    if simulation.state == state:
      result.add(simulation)
  result = result.sortedByIt(it.simId)

proc update*(self: var Scheduler) =
  ## Moves every simulation forward one step; never blocks.
  ##
  ## In order, it records the events every running TRNRun wrote, finishes the
  ## simulations whose TRNRun exited, and starts queued simulations on the
  ## workers that freed up. Call it often: TRNRun blocks once its output pipe
  ## is full, and nothing else reads that pipe.
  self.recordOutput()
  self.finishExited()
  self.startQueued()

proc cancel*(self: var Scheduler, simId: int): bool =
  ## Cancels a queued or running simulation; false if it is unknown or already finished.
  ##
  ## A running simulation has its TRNRun killed, its last output recorded, and
  ## is reported as interrupted. A queued one leaves the queue and is reported
  ## as not started. Both end `FINISHED` with status `CANCELLED`, and the freed
  ## worker starts the next queued simulation. Raises `OSError` if TRNRun
  ## cannot be killed, which leaves the simulation running.
  if simId notin self.simulations or self.simulations[simId].state == ssFinished:
    return false
  if simId in self.running:
    self.running[simId].kill()
    self.dropTrnrun(simId)
  else:
    self.queue.delete(self.queue.find(simId))
  self.simulations[simId].cancel() # Still RUNNING here, so it is reported as interrupted.
  self.startQueued()
  true

proc release*(self: var Scheduler, simId: int): bool =
  ## Forgets a finished simulation and its logs; false if unknown, queued or running.
  if simId notin self.simulations or self.simulations[simId].state != ssFinished:
    return false
  self.simulations.del(simId)
  true
