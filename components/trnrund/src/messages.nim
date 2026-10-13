## Defines the values exchanged between the scheduler, its workers, and the
## client reader.
##
## The scheduler thread owns all simulation state. Workers never touch it; they
## post `Message`s to the scheduler inbox instead, as does the thread reading
## client requests. One shared inbox lets the scheduler block on a single
## channel, since Nim channels cannot wait on several at once. Work flows the
## other way through one shared worker channel. Both are flat objects: each
## kind lists the fields it sets, and the rest keep their defaults. The one
## value both sides share is a run's cancel flag, which the scheduler sets and
## the worker polls.

import std/[atomics, options]

type
  WorkKind* = enum
    ## Kind of `Work` sent to a worker.
    wkRun ## runId, deckFile, trnrunArgs, cancel.
    wkStop ## No fields. Sent once per worker during shutdown.

  Work* = object
    ## One unit handed from the scheduler to a worker.
    kind*: WorkKind
    runId*: string
    deckFile*: string
    trnrunArgs*: seq[string]
    cancel*: ptr Atomic[bool]
      ## Set by the scheduler to stop the run. Shared memory the scheduler
      ## frees once it applies the run's `mkExited`, after the worker's last read.

  MessageKind* = enum
    ## Kind of `Message` posted to the scheduler inbox.
    mkLaunched ## runId. A worker started the TRNRun process.
    mkOutput ## runId, line. One line written by TRNRun.
    mkExited ## runId, exitCode, error, cancelled. A simulation finished; its
      ## submission slot can be released.
    mkRequest ## line. One request line read from the client.
    mkClosed ## No fields. The client closed its input.

  Message* = object
    ## One notification posted to the scheduler inbox.
    kind*: MessageKind
    runId*: string
    line*: string ## TRNRun output or client request.
    exitCode*: Option[int] ## TRNRun exit code; none when it never launched.
    error*: string ## Launch or capture failure; empty otherwise.
    cancelled*: bool ## The worker stopped the run because its cancel flag was set.
