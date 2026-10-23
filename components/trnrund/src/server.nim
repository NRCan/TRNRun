## Serves one client until it leaves.
##
## The loop takes the scheduler's messages in batches: client requests become
## replies, see `protocol`, and worker messages update their runs. The batch's
## replies, then those of waiting adds whose runs got there, go to the writer
## thread, see `writer`, so a client that reads slowly never holds up the next
## batch. A closed input or a failed write abandons the scheduler, killing any
## TRNRun still running; nothing else ends serving, not even `shutdown`.

import ./[messages, protocol, scheduler, writer]

export WriteLines

const ExitGraceMs = 1_000
  ## How long a daemon about to exit still writes to a client that may not be reading.

proc serve*(scheduler: Scheduler, write: WriteLines) =
  ## Serves the client with `write` until it leaves, then abandons the scheduler.
  ##
  ## Returns once everything sent is written, or after `ExitGraceMs` if the
  ## client is not reading.
  var writer = Writer()
  writer.start(write, scheduler.requestInbox)
  defer: writer.stop(ExitGraceMs)
  while true:
    let messages = scheduler.receive()
    var
      replies: seq[string] = @[]
      closed = false
    for message in messages:
      case message.kind
      of mkRequest:
        let reply = scheduler.handleRequest(message.line)
        if reply.len > 0:
          replies.add(reply)
      of mkClosed: closed = true
      of mkOutput, mkExited: scheduler.apply(message)
    replies.add(scheduler.takeReplies())
    writer.send(replies)

    if closed:
      scheduler.abandon()
      return
