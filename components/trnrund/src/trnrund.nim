## TRNRun daemon: runs TRNSYS simulations on behalf of one client.
##
## The client starts the daemon and exchanges one JSON object per line over
## its stdin and stdout; see `protocol` for the requests. stdout carries
## replies only. When the client closes stdin, the daemon exits at once and
## the job object kills any TRNRun process still going.
##
## Usage: trnrund [--maxConcurrent:N] [--trnrun:PATH]
##
##   --maxConcurrent  Simulations run at once (default: processors - 1)
##   --trnrun         TRNRun executable (default: trnrun.exe beside trnrund)
##
## Invalid options or a missing TRNRun end startup with a one-line message on
## stderr and exit code 2.

import std/[os, parseopt, strutils]
import ./messages
import ./protocol
import ./scheduler

proc readRequests(inbox: ptr Channel[Message]) {.thread.} =
  ## Posts each stdin line to the scheduler, then reports that the client closed
  ## its input.
  var line = ""
  try:
    while stdin.readLine(line):
      inbox[].send(Message(kind: mkRequest, line: line))
  except IOError:
    discard # A broken pipe means the client is gone, like a closed one.
  inbox[].send(Message(kind: mkClosed))

proc main() =
  var
    maxConcurrent = DefaultMaxConcurrent
    trnrunPath = getAppDir() / "trnrun.exe"
  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "maxConcurrent":
        try:
          maxConcurrent = parseInt(value)
        except ValueError:
          quit("Invalid --maxConcurrent: '" & value & "'", 2)
      of "trnrun":
        trnrunPath = value
      else:
        quit("Unknown option: --" & key, 2)
    else:
      quit("Unexpected argument: " & key, 2)

  let scheduler =
    try:
      newScheduler(trnrunPath, maxConcurrent)
    except CatchableError as error:
      quit(error.msg, 2)
  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  var reader: Thread[ptr Channel[Message]]
  createThread(reader, readRequests, scheduler.requestInbox)
  {.pop.}

  while true:
    let message = scheduler.nextRequest()
    if message.kind == mkClosed:
      quit(0)

    let (reply, shutdown) = scheduler.handleRequest(message.line)
    stdout.writeLine(reply)
    stdout.flushFile()
    if shutdown:
      scheduler.shutdown()
      quit(0)

main()
