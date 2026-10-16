## Defines the messages passed between the scheduler and the other threads.
##
## The scheduler thread owns all simulation state, including every TRNRun
## `Process`. Workers only read a run's output and post `Message`s to the
## scheduler inbox, as do the stdin reader and the stdout writer, see `writer`.
## One shared inbox lets the scheduler block on a single channel, since Nim
## channels cannot wait on several at once. `Work` flows the other way, through
## one channel the workers share. Nothing else crosses threads but the replies
## handed to the writer.

import std/[options, winlean]

type
  WorkKind* = enum
    wkRead ## Capture the output and exit of one run.
    wkStop ## Sent once per worker during shutdown.

  Work* = object
    ## A task the scheduler hands to the worker pool.
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
    ## A message posted to the scheduler inbox; each kind sets only the fields it lists.
    kind*: MessageKind
    runId*: int
    line*: string ## TRNRun output or client request.
    exitCode*: Option[int] ## TRNRun exit code; none when it could not be read.
    error*: string ## Capture failure; empty otherwise.
