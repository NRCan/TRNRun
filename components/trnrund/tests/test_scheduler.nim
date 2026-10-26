import std/[monotimes, options, os, strutils, times, unittest]

import ../src/scheduler
import ./fake_trnrun
import ./junit

proc simulationOf(scheduler: Scheduler, simId: int): Simulation =
  ## The simulation `simId`, which must exist.
  return scheduler[simId]

proc stateOf(scheduler: Scheduler, simId: int): SimulationState =
  ## The state of simulation `simId`, which must exist.
  return scheduler.simulationOf(simId).state

template waitUntil(scheduler: var Scheduler, condition: untyped) =
  ## Updates `scheduler` until `condition` holds; fails after 5 seconds.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not condition and getMonoTime() < deadline:
    scheduler.update()
    sleep(10)
  check condition

let dir = createDeckDir()

suite "scheduler":
  var scheduler = initScheduler(getAppFilename(), 2)

  teardown:
    # Queued first, so cancelling a running one starts nothing.
    for state in [ssQueued, ssRunning]:
      for simId in scheduler.list({state}):
        discard scheduler.cancel(simId)
    scheduler = initScheduler(getAppFilename(), 2)

  test "add starts a simulation at once when a worker is free":
    let simId = scheduler.add(createDeck(dir, "wait-a.dck"), @["--pollMs:50"], some("first"))
    let simulation = scheduler.simulationOf(simId)
    check simulation.simId == simId
    check simulation.deckFile == dir / "wait-a.dck"
    check simulation.trnrunArgs == @["--pollMs:50"]
    check simulation.label == some("first")
    check simulation.state == ssRunning
    check simulation.submittedAt.endsWith("Z")
    check simulation.startedAt.isSome
    check simulation.finishedAt.isNone
    check simulation.succeeded.isNone

  test "simIds are never reused":
    let first = scheduler.add(createDeck(dir, "done-ids.dck"))
    scheduler.waitUntil(scheduler.stateOf(first) == ssFinished)
    check scheduler.release(first)
    check scheduler.add(createDeck(dir, "done-ids.dck")) == first + 1

  test "queues beyond maxWorkers and starts the next when a worker frees":
    let
      first = createDeck(dir, "wait-b1.dck")
      simIds = [
        scheduler.add(first),
        scheduler.add(createDeck(dir, "wait-b2.dck")),
        scheduler.add(createDeck(dir, "wait-b3.dck")),
      ]
    check scheduler.stateOf(simIds[0]) == ssRunning
    check scheduler.stateOf(simIds[1]) == ssRunning
    check scheduler.stateOf(simIds[2]) == ssQueued
    check scheduler.simulationOf(simIds[2]).startedAt.isNone
    releaseDeck(first)
    scheduler.waitUntil(scheduler.stateOf(simIds[0]) == ssFinished)
    check scheduler.stateOf(simIds[2]) == ssRunning

  test "records every TRNRun event of a successful run, including an unterminated last line":
    let simId = scheduler.add(createDeck(dir, "done-c.dck"))
    scheduler.waitUntil(scheduler.stateOf(simId) == ssFinished)
    let simulation = scheduler.simulationOf(simId)
    check simulation.succeeded == some(true)
    check simulation.exitCode == some(0)
    check simulation.error.isNone
    check simulation.trnrunStatus == some(stDone)
    check simulation.trnrunMessage == some("finished")
    check simulation.percent == some(1.0)
    check simulation.simTime == some(10.0)
    check simulation.elapsedMs == some(200.0)
    check simulation.etaMs == some(0.0)
    check (simulation.startTime, simulation.stopTime, simulation.timeStep) ==
      (some(0.0), some(10.0), some(1.0))
    check (simulation.notices, simulation.warnings, simulation.fatals) == (1, 1, 1)
    check simulation.logs.len == 3
    check simulation.logs[1].message == some("second")
    check simulation.finishedAt.isSome

  test "records progress while TRNRun runs":
    let simId = scheduler.add(createDeck(dir, "wait-d.dck"))
    scheduler.waitUntil(scheduler.simulationOf(simId).percent == some(0.5))
    check scheduler.stateOf(simId) == ssRunning

  test "a TRNRun error fails the run":
    let simId = scheduler.add(createDeck(dir, "fail-e.dck"))
    scheduler.waitUntil(scheduler.stateOf(simId) == ssFinished)
    let simulation = scheduler.simulationOf(simId)
    check simulation.succeeded == some(false)
    check simulation.exitCode == some(1)
    check simulation.trnrunStatus == some(stError)
    check simulation.trnrunMessage == some("Fake failure")

  test "an exit without a terminal status fails the run":
    let simId = scheduler.add(createDeck(dir, "silent-f.dck"))
    scheduler.waitUntil(scheduler.stateOf(simId) == ssFinished)
    let simulation = scheduler.simulationOf(simId)
    check simulation.succeeded == some(false)
    check simulation.exitCode == some(0)
    check simulation.trnrunStatus == some(stError)
    check simulation.trnrunMessage == some("TRNRun exited without a terminal status")

  test "passes trnrunArgs after the deck":
    let deckFile = createDeck(dir, "args-g.dck")
    let simId = scheduler.add(deckFile, @["--pollMs:50", "--clean:true"])
    scheduler.waitUntil(scheduler.stateOf(simId) == ssFinished)
    check readFile(deckFile.changeFileExt("args")) == deckFile & "\n--pollMs:50\n--clean:true"

  test "a TRNRun that cannot start fails its run":
    var broken = initScheduler(dir / "missing.exe", 1)
    let simId = broken.add(createDeck(dir, "done-h.dck"))
    let simulation = broken.simulationOf(simId)
    check simulation.state == ssFinished
    check simulation.succeeded == some(false)
    check simulation.exitCode.isNone
    check simulation.trnrunStatus == some(stError)
    check simulation.error.get().startsWith("Cannot start TRNRun: ")

  test "cancels a queued simulation without starting it":
    discard scheduler.add(createDeck(dir, "wait-i1.dck"))
    discard scheduler.add(createDeck(dir, "wait-i2.dck"))
    let queued = scheduler.add(createDeck(dir, "wait-i3.dck"))
    check scheduler.cancel(queued)
    scheduler.update()
    let simulation = scheduler.simulationOf(queued)
    check simulation.state == ssFinished
    check simulation.succeeded == some(false)
    check simulation.startedAt.isNone
    check simulation.trnrunStatus == some(stCancelled)
    check simulation.trnrunMessage == some("Not started")
    check simulation.error == some("Not started: cancelled by the client")

  test "cancels a running simulation, keeping what it reported, and frees its worker":
    let
      running = scheduler.add(createDeck(dir, "wait-j1.dck"))
      other = scheduler.add(createDeck(dir, "wait-j2.dck"))
      queued = scheduler.add(createDeck(dir, "wait-j3.dck"))
    scheduler.waitUntil(scheduler.simulationOf(running).percent == some(0.5))
    check scheduler.cancel(running)
    let simulation = scheduler.simulationOf(running)
    check simulation.state == ssFinished
    check simulation.exitCode.isNone
    check simulation.percent == some(0.5)
    check simulation.trnrunStatus == some(stCancelled)
    check simulation.error == some("Interrupted: cancelled by the client")
    check scheduler.stateOf(queued) == ssRunning
    check scheduler.stateOf(other) == ssRunning

  test "cancelling a finished simulation leaves it unchanged; an unknown one is refused":
    let simId = scheduler.add(createDeck(dir, "done-k.dck"))
    scheduler.waitUntil(scheduler.stateOf(simId) == ssFinished)
    check scheduler.cancel(simId)
    check scheduler.simulationOf(simId).trnrunStatus == some(stDone)
    check not scheduler.cancel(999)

  test "releases only finished simulations":
    let
      running = scheduler.add(createDeck(dir, "wait-l1.dck"))
      done = scheduler.add(createDeck(dir, "done-l2.dck"))
    scheduler.waitUntil(scheduler.stateOf(done) == ssFinished)
    check not scheduler.release(running)
    check scheduler.release(done)
    check done notin scheduler
    expect KeyError:
      discard scheduler[done]
    check not scheduler.release(done)
    check scheduler.cancel(running)
    check scheduler.release(running)

  test "list returns the simIds in the given states, oldest first":
    let
      done = scheduler.add(createDeck(dir, "done-n1.dck"))
      running = scheduler.add(createDeck(dir, "wait-n2.dck"))
    scheduler.waitUntil(scheduler.stateOf(done) == ssFinished)
    let queued = [
      scheduler.add(createDeck(dir, "wait-n3.dck")),
      scheduler.add(createDeck(dir, "wait-n4.dck")),
      scheduler.add(createDeck(dir, "wait-n5.dck")),
    ]
    check scheduler.list({ssFinished}) == @[done]
    check scheduler.list({ssRunning}) == @[running, queued[0]]
    check scheduler.list({ssQueued}) == @[queued[1], queued[2]]
    check scheduler.list({ssQueued, ssFinished}) == @[done, queued[1], queued[2]]
    check scheduler.release(done)
    check scheduler.list({ssFinished}).len == 0

removeDir(dir)
