## Defines the values exchanged between the scheduler, its workers, and the
## client reader.
##
## The scheduler thread owns all simulation state, including every TRNRun
## `Process`. Workers only read a run's output; they post `Message`s to the
## scheduler inbox, as does the thread reading client requests. One shared
## inbox lets the scheduler block on a single channel, since Nim channels
## cannot wait on several at once. Work flows the other way through one shared
## worker channel. Both are flat objects: each kind lists the fields it sets,
## and the rest keep their defaults. Nothing else is shared between threads.

import std/[options, winlean]

type
  WorkKind* = enum
    ## Kind of `Work` sent to a worker.
    wkRead ## runId, output, process.
    wkStop ## No fields. Sent once per worker during shutdown.

  Work* = object
    ## One unit handed from the scheduler to a worker.
    kind*: WorkKind
    runId*: int
    output*: Handle
      ## Read end of TRNRun's merged stdout and stderr. Owned by the
      ## scheduler's `Process`, which it closes only after applying `mkExited`.
    process*: Handle
      ## A handle on TRNRun the worker owns and closes, to wait for its exit.

  MessageKind* = enum
    ## Kind of `Message` posted to the scheduler inbox.
    mkOutput ## runId, line. One line written by TRNRun.
    mkExited ## runId, exitCode, error. TRNRun exited and its output is drained.
    mkRequest ## line. One request line read from the client.
    mkClosed ## No fields. The client closed its input.

  Message* = object
    ## One notification posted to the scheduler inbox.
    kind*: MessageKind
    runId*: int
    line*: string ## TRNRun output or client request.
    exitCode*: Option[int] ## TRNRun exit code; none when it could not be read.
    error*: string ## Capture failure; empty otherwise.
