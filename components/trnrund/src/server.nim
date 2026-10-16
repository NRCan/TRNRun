## Serves one client until it leaves or a shutdown completes.
##
## The loop takes the scheduler's messages in batches and applies each batch
## in one transaction: client requests become replies, see `protocol`, and
## worker messages update their runs. The replies and the revision a batch
## saved go to the writer thread, see `writer`, so a client that reads slowly
## never holds up the next batch. A closed input or a failed write abandons the
## scheduler; a completed shutdown closes it.

import ./[messages, protocol, scheduler, writer]

export WriteLines

const ExitGraceMs = 1_000
  ## How long a daemon about to exit still writes to a client that may not be reading.

proc serve*(scheduler: Scheduler, write: WriteLines) =
  ## Serves the client with `write` until a shutdown completes, then closes the
  ## scheduler, or until the client leaves, then abandons it.
  ##
  ## Returns once everything sent is written, or after `ExitGraceMs` if the
  ## client is not reading.
  var writer = Writer()
  writer.start(write, scheduler.requestInbox, scheduler.savedRevision)
  defer: writer.stop(ExitGraceMs)
  while true:
    let messages = scheduler.receive()
    var
      replies: seq[string] = @[]
      closed = false
    scheduler.atomically:
      for message in messages:
        case message.kind
        of mkRequest: replies.add(scheduler.handleRequest(message.line))
        of mkClosed: closed = true
        of mkOutput, mkExited: scheduler.apply(message)
    writer.send(replies, scheduler.savedRevision)

    if closed:
      scheduler.abandon()
      return
    if scheduler.isDone:
      scheduler.close()
      return
