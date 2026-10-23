import std/[monotimes, options, os, sequtils, strutils, times, unittest]

import ../src/worker/pool
import ./fake_trnrun

proc simulationOf(pool: Pool, simId: int): Simulation =
  ## The simulation `simId`, which must exist.
  pool.get(simId).get()

proc stateOf(pool: Pool, simId: int): SimulationState =
  ## The state of simulation `simId`, which must exist.
  pool.simulationOf(simId).state

template waitUntil(pool: var Pool, condition: untyped) =
  ## Updates `pool` until `condition` holds; fails after 5 seconds.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while not condition and getMonoTime() < deadline:
    pool.update()
    sleep(10)
  check condition

let dir = createDeckDir()

suite "pool":
  var pool = initPool(getAppFilename(), 2)

  teardown:
    pool.stop()
    pool = initPool(getAppFilename(), 2)

  test "add starts a simulation at once when a worker is free":
    let simId = pool.add(createDeck(dir, "wait-a.dck"), @["--pollMs:50"], some("first"))
    let simulation = pool.simulationOf(simId)
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
    let first = pool.add(createDeck(dir, "done-ids.dck"))
    pool.waitUntil(pool.stateOf(first) == ssFinished)
    check pool.release(first)
    check pool.add(createDeck(dir, "done-ids.dck")) == first + 1

  test "queues beyond maxWorkers and starts the next when a worker frees":
    let
      first = createDeck(dir, "wait-b1.dck")
      simIds = [
        pool.add(first),
        pool.add(createDeck(dir, "wait-b2.dck")),
        pool.add(createDeck(dir, "wait-b3.dck")),
      ]
    check pool.stateOf(simIds[0]) == ssRunning
    check pool.stateOf(simIds[1]) == ssRunning
    check pool.stateOf(simIds[2]) == ssQueued
    check pool.simulationOf(simIds[2]).startedAt.isNone
    releaseDeck(first)
    pool.waitUntil(pool.stateOf(simIds[0]) == ssFinished)
    check pool.stateOf(simIds[2]) == ssRunning

  test "records every TRNRun event of a successful run, including an unterminated last line":
    let simId = pool.add(createDeck(dir, "done-c.dck"))
    pool.waitUntil(pool.stateOf(simId) == ssFinished)
    let simulation = pool.simulationOf(simId)
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
    let simId = pool.add(createDeck(dir, "wait-d.dck"))
    pool.waitUntil(pool.simulationOf(simId).percent == some(0.5))
    check pool.stateOf(simId) == ssRunning

  test "a TRNRun error fails the run":
    let simId = pool.add(createDeck(dir, "fail-e.dck"))
    pool.waitUntil(pool.stateOf(simId) == ssFinished)
    let simulation = pool.simulationOf(simId)
    check simulation.succeeded == some(false)
    check simulation.exitCode == some(1)
    check simulation.trnrunStatus == some(stError)
    check simulation.trnrunMessage == some("Fake failure")

  test "an exit without a terminal status fails the run":
    let simId = pool.add(createDeck(dir, "silent-f.dck"))
    pool.waitUntil(pool.stateOf(simId) == ssFinished)
    let simulation = pool.simulationOf(simId)
    check simulation.succeeded == some(false)
    check simulation.exitCode == some(0)
    check simulation.trnrunStatus == some(stError)
    check simulation.trnrunMessage == some("TRNRun exited without a terminal status")

  test "passes trnrunArgs after the deck":
    let deckFile = createDeck(dir, "args-g.dck")
    let simId = pool.add(deckFile, @["--pollMs:50", "--clean:true"])
    pool.waitUntil(pool.stateOf(simId) == ssFinished)
    check readFile(deckFile.changeFileExt("args")) == deckFile & "\n--pollMs:50\n--clean:true"

  test "a TRNRun that cannot start fails its run":
    var broken = initPool(dir / "missing.exe", 1)
    let simId = broken.add(createDeck(dir, "done-h.dck"))
    let simulation = broken.simulationOf(simId)
    check simulation.state == ssFinished
    check simulation.succeeded == some(false)
    check simulation.exitCode.isNone
    check simulation.trnrunStatus == some(stError)
    check simulation.error.get().startsWith("Cannot start TRNRun: ")

  test "cancels a queued simulation without starting it":
    discard pool.add(createDeck(dir, "wait-i1.dck"))
    discard pool.add(createDeck(dir, "wait-i2.dck"))
    let queued = pool.add(createDeck(dir, "wait-i3.dck"))
    check pool.cancel(queued)
    pool.update()
    let simulation = pool.simulationOf(queued)
    check simulation.state == ssFinished
    check simulation.succeeded == some(false)
    check simulation.startedAt.isNone
    check simulation.trnrunStatus == some(stCancelled)
    check simulation.trnrunMessage == some("Not started")
    check simulation.error == some("Not started: cancelled by the client")

  test "cancels a running simulation, keeping what it reported, and frees its worker":
    let
      running = pool.add(createDeck(dir, "wait-j1.dck"))
      other = pool.add(createDeck(dir, "wait-j2.dck"))
      queued = pool.add(createDeck(dir, "wait-j3.dck"))
    pool.waitUntil(pool.simulationOf(running).percent == some(0.5))
    check pool.cancel(running)
    let simulation = pool.simulationOf(running)
    check simulation.state == ssFinished
    check simulation.exitCode.isNone
    check simulation.percent == some(0.5)
    check simulation.trnrunStatus == some(stCancelled)
    check simulation.error == some("Interrupted: cancelled by the client")
    check pool.stateOf(queued) == ssRunning
    check pool.stateOf(other) == ssRunning

  test "cannot cancel a finished or unknown simulation":
    let simId = pool.add(createDeck(dir, "done-k.dck"))
    pool.waitUntil(pool.stateOf(simId) == ssFinished)
    check not pool.cancel(simId)
    check pool.simulationOf(simId).trnrunStatus == some(stDone)
    check not pool.cancel(999)

  test "releases only finished simulations":
    let
      running = pool.add(createDeck(dir, "wait-l1.dck"))
      done = pool.add(createDeck(dir, "done-l2.dck"))
    pool.waitUntil(pool.stateOf(done) == ssFinished)
    check not pool.release(running)
    check pool.release(done)
    check pool.get(done).isNone
    check not pool.release(done)
    check pool.cancel(running)
    check pool.release(running)

  test "list returns the simulations in a state, oldest first":
    let
      done = pool.add(createDeck(dir, "done-n1.dck"))
      running = pool.add(createDeck(dir, "wait-n2.dck"))
    pool.waitUntil(pool.stateOf(done) == ssFinished)
    let queued = [
      pool.add(createDeck(dir, "wait-n3.dck")),
      pool.add(createDeck(dir, "wait-n4.dck")),
      pool.add(createDeck(dir, "wait-n5.dck")),
    ]
    check pool.list(ssFinished).mapIt(it.simId) == @[done]
    check pool.list(ssRunning).mapIt(it.simId) == @[running, queued[0]]
    check pool.list(ssQueued).mapIt(it.simId) == @[queued[1], queued[2]]
    check pool.list(ssFinished)[0].logs.len == 3
    check pool.release(done)
    check pool.list(ssFinished).len == 0

  test "stop cancels every queued and running simulation":
    let simIds = [
      pool.add(createDeck(dir, "wait-m1.dck")),
      pool.add(createDeck(dir, "wait-m2.dck")),
      pool.add(createDeck(dir, "wait-m3.dck")),
    ]
    pool.stop()
    for simId in simIds:
      check pool.simulationOf(simId).trnrunStatus == some(stCancelled)

removeDir(dir)
