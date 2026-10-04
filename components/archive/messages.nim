## Defines the values exchanged between the scheduler, its workers, and the
## client reader.
##
## The scheduler thread owns all simulation state. Workers never touch it; they
## post `Message`s to the scheduler inbox instead, as does the thread reading
## client requests. One shared inbox lets the scheduler block on a single
## channel, since Nim channels cannot wait on several at once. Work flows the
## other way through one shared worker channel. Both are flat objects of plain
## values so channel deep copies stay trivial; each kind lists the fields it
## sets, and the rest keep their defaults.

import std/options

type
  WorkKind* = enum
    wkRun ## runId, deckFile, trnrunPath, trnrunArgs.
    wkStop ## No fields. Passed from worker to worker until all have stopped.

  Work* = object
    ## One unit handed from the scheduler to a worker.
    kind*: WorkKind
    runId*: string
    deckFile*: string
    trnrunPath*: string
    trnrunArgs*: seq[string]

  MessageKind* = enum
    mkLaunched ## runId. A worker started the TRNRun process.
    mkOutput ## runId, line. One line written by TRNRun.
    mkExited ## runId, exitCode, error. A simulation finished; its submission
      ## slot can be released.
    mkRequest ## line. One request line read from the client.
    mkClosed ## No fields. The client closed its input.

  Message* = object
    ## One notification posted to the scheduler inbox.
    kind*: MessageKind
    runId*: string
    line*: string ## TRNRun output or client request.
    exitCode*: Option[int] ## TRNRun exit code; none when it never launched.
    error*: string ## Validation, launch, or capture failure; empty otherwise.
