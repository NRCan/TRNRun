## Carries request lines from stdin, response lines to stdout, and diagnostics to stderr.
##
## Stdin is read on a thread of its own, so the daemon keeps starting and
## reaping simulations while the client is quiet; `poll` never blocks.

import std/[options, winlean]

type PollResult* = enum
  prNothing ## No request waiting.
  prLine ## A request line was read.
  prClosed ## The client closed stdin; nothing more will come.

var
  inbox: Channel[Option[string]] ## Each stdin line, then none once stdin ends.
  reader: Thread[void]

proc readStdin() {.thread.} =
  ## Posts each stdin line to `inbox`, then none once the client is gone.
  var line = ""
  try:
    while stdin.readLine(line):
      inbox.send(some(line))
  except IOError:
    discard # A broken pipe means the client is gone, like a closed one.
  inbox.send(none(string))

proc disinheritStdHandles() =
  ## Stops child processes such as TRNRun inheriting the client's pipes.
  # An inherited stdout would stay open in TRNRun, so the client could miss the daemon's exit.
  for kind in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
    discard setHandleInformation(getStdHandle(kind), HANDLE_FLAG_INHERIT, 0)

proc openPipe*() =
  ## Starts reading stdin and stops TRNRun inheriting the client's pipes.
  disinheritStdHandles()
  inbox.open()
  createThread(reader, readStdin)

proc poll*(line: var string): PollResult =
  ## Takes the next request line into `line` if one is waiting; never blocks.
  let (available, message) = inbox.tryRecv()
  if not available:
    prNothing
  elif message.isNone:
    prClosed
  else:
    line = message.get()
    prLine

proc diagnose*(message: string) =
  ## Writes a diagnostic to stderr, which stays free of protocol traffic.
  try:
    stderr.writeLine("trnrund2: ", message)
  except IOError:
    discard

proc respond*(response: string) =
  ## Writes one response line to stdout and flushes it; `IOError` once the client is gone.
  stdout.writeLine(response)
  stdout.flushFile()
