## Defines the values exchanged between the scheduler, its workers, and the
## client reader.
##
## The scheduler thread owns all simulation state, including every TRNRun
## `Process`. Workers only read a run's output; they post `Message`s to the
## scheduler inbox, as does the thread reading client requests. One shared
## inbox lets the scheduler block on a single channel, since Nim channels
## cannot wait on several at once. Work flows the other way through one shared
## worker channel. `Message` is a flat object, since several kinds share
## fields: each kind lists the fields it sets, and the rest keep their
## defaults. Nothing else is shared between threads
## but the replies handed to the stdout writer, see `writer`, which posts
## `mkClosed` here too.

import std/[options, winlean]

type
  WorkKind* = enum
    wkRead ## Capture the output and exit of one run.
    wkStop ## Sent once per worker during shutdown.

  Work* = object
    case kind*: WorkKind
    of wkRead:
      runId*: int
      output*: Handle
        ## Read end of TRNRun's merged stdout and stderr. Owned by the
        ## scheduler's `Process`, which it closes only after applying `mkExited`.
      process*: Handle
        ## A handle on TRNRun the worker owns and closes, to wait for its exit.
    of wkStop:
      discard

  MessageKind* = enum
    mkOutput ## runId, line. One line written by TRNRun.
    mkExited ## runId, exitCode, error. TRNRun exited and its output is drained.
    mkRequest ## line. One request line read from the client.
    mkClosed ## No fields. The client closed its input.

  Message* = object
    kind*: MessageKind
    runId*: int
    line*: string ## TRNRun output or client request.
    exitCode*: Option[int] ## TRNRun exit code; none when it could not be read.
    error*: string ## Capture failure; empty otherwise.
