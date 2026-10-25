## Carries request lines from stdin, response lines to stdout, and diagnostics to stderr.
##
## Stdin is read on a thread of its own, so the daemon keeps starting and
## reaping simulations while the client is quiet; `poll` never blocks, and
## `waitForLine` sleeps only until the next line arrives.

import std/[options, oserrors, winlean]

type PollResult* = enum
  prNothing ## No request waiting.
  prLine ## A request line was read.
  prClosed ## The client closed stdin; nothing more will come.

var
  inbox: Channel[Option[string]] ## Each stdin line, then none once stdin ends.
  posted: Handle ## Auto-reset event set after each `inbox` send; wakes `waitForLine`.
  reader: Thread[void]

proc post(message: sink Option[string]) =
  ## Sends `message` to `inbox` and wakes `waitForLine`.
  inbox.send(message)
  discard setEvent(posted)

proc readStdin() {.thread.} =
  ## Posts each stdin line to `inbox`, then none once the client is gone.
  var line = ""
  try:
    while stdin.readLine(line):
      post(some(move line)) # readLine refills the emptied `line`.
  except IOError:
    discard # A broken pipe means the client is gone, like a closed one.
  post(none(string))

proc disinheritStdHandles() =
  ## Stops child processes such as TRNRun inheriting the client's pipes.
  # An inherited stdout would stay open in TRNRun, so the client could miss the daemon's exit.
  for kind in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
    discard setHandleInformation(getStdHandle(kind), HANDLE_FLAG_INHERIT, 0)

proc openPipe*() =
  ## Starts reading stdin and stops TRNRun inheriting the client's pipes; `OSError` on failure.
  disinheritStdHandles()
  posted = createEvent(nil, 0, 0, nil)
  if posted == 0:
    raiseOSError(osLastError(), "Failed to create the stdin event.")
  inbox.open()
  createThread(reader, readStdin)

proc waitForLine*(timeoutMs: int) =
  ## Sleeps until a stdin line may be waiting, or at most `timeoutMs`.
  # A line taken by `poll` before this wait leaves the event set, so the wait can
  # end early without a line; the caller just polls again.
  discard waitForSingleObject(posted, int32(timeoutMs))

proc poll*(line: var string): PollResult =
  ## Takes the next request line into `line` if one is waiting; never blocks.
  let (available, message) = inbox.tryRecv()
  if not available:
    return prNothing
  elif message.isNone:
    return prClosed
  else:
    line = message.get()
    return prLine

proc diagnose*(message: string) =
  ## Writes a diagnostic to stderr; call it only just before exiting.
  ##
  ## Clients may read stderr only once the daemon exits, so a diagnostic
  ## written while serving could fill the pipe and block the daemon.
  try:
    stderr.writeLine("trnrund: ", message)
  except IOError:
    discard

proc respond*(response: string) =
  ## Writes one response line to stdout and flushes it; `IOError` once the client is gone.
  stdout.writeLine(response)
  stdout.flushFile()
