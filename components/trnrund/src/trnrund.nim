## Implements the trnrund command-line interface.
##
## Entry point for the daemon that runs TRNSYS simulations on behalf of one
## client. The client exchanges one JSON object per line over stdin and stdout;
## see `protocol` for the requests. Simulations are read from the SQLite
## database, see `database`. When the client closes stdin, the daemon saves its
## unfinished runs as interrupted and exits at once, and the job object kills
## any TRNRun process still going.

import std/[parseopt, winlean]
import ./cli
import ./messages
import ./protocol
import ./scheduler
import ./threadstart

const NimblePkgVersion {.strdefine.} = "unknown"
const HelpText = """trnrund - run TRNSYS simulations for one client

Usage:
  trnrund [options]

Options:
  -h, --help         Show this help and exit
  -v, --version      Show version and exit
  --trnrun:PATH      TRNRun executable (default: trnrun.exe beside trnrund)
  --maxConcurrent:N  Simulations run at once (default: max(CPUs - 1, 1))
  --database:PATH    SQLite database clients read (default: trnrund.sqlite3)

Read one JSON request per stdin line and write one JSON reply per stdout line,
in request order, among {"event":"changed","revision":N} notifications:
  {"id":1,"cmd":"add","deckFile":"model.dck"}  ->  {"id":1,"ok":true,"runId":7}
Commands: ready, add, cancel, shutdown. ready reports the database holding
every run's state and logs. Closing stdin exits at once, saving unfinished runs
as interrupted. See README.md for the protocol and the database layout.

Exit codes: 0 ok  1 fatal  2 usage error"""

var daemonScheduler: Scheduler
  ## Global so its channels outlive `main`; the reader and workers point into them.
var reader: Thread[ptr Channel[Message]]
  ## Global so it outlives `main`. Never joined: it blocks on stdin until exit.

proc readRequests(inbox: ptr Channel[Message]) {.thread.} =
  ## Posts each stdin line to the scheduler, then reports that the client left.
  var line = ""
  try:
    while stdin.readLine(line):
      inbox[].send(Message(kind: mkRequest, line: line))
  except IOError:
    discard # A broken pipe means the client is gone, like a closed one.
  inbox[].send(Message(kind: mkClosed))

proc writeLines(lines: seq[string]): bool {.nimcall, gcsafe, raises: [].} =
  ## Writes reply and notification lines to the client; false once it is gone.
  ## Runs on the writer thread, the only one writing stdout. Calls WriteFile
  ## directly, bypassing the C runtime's buffer, so a write cancelled at exit
  ## leaves nothing for the exit to flush and block on.
  var
    text = ""
    written = 0'i32
  for line in lines:
    text.add(line)
    text.add('\n')
  writeFile(getStdHandle(STD_OUTPUT_HANDLE), addr text[0], int32(text.len), addr written, nil) != 0 and
    written == int32(text.len)

proc keepStdHandlesPrivate() =
  ## Stops TRNRun children from inheriting the client's pipes, so stdout ends
  ## when the daemon exits, not when its last child does.
  for kind in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
    let handle = getStdHandle(kind)
    if handle != 0 and handle != INVALID_HANDLE_VALUE:
      discard setHandleInformation(handle, HANDLE_FLAG_INHERIT, 0)

proc main() =
  ## Parses the command line, then serves the client until it leaves or shuts down.
  var
    input = defaultCliInput()
    parser = initOptParser()
  for kind, key, value in parser.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case key
      of "help", "h":
        echo HelpText
        return
      of "version", "v":
        echo NimblePkgVersion
        return
      else:
        if not input.applyOption(key, value):
          let dashes = if kind == cmdShortOption: "-" else: "--"
          raise newException(InputError, "Unknown option: " & dashes & key)
    of cmdArgument:
      raise newException(InputError, "Unexpected argument: " & key)
    of cmdEnd:
      discard

  keepStdHandlesPrivate()
  daemonScheduler = newScheduler(input.trnrunPath, input.maxConcurrent, input.databasePath)
  reader.startThread(readRequests, daemonScheduler.requestInbox)
  daemonScheduler.serve(writeLines)

proc writeError(message: string) =
  ## Reports a fatal diagnostic for humans. Clients must not parse stderr.
  try:
    stderr.writeLine(message)
    stderr.flushFile()
  except IOError:
    discard

when isMainModule:
  let exitCode =
    try:
      main()
      0
    except InputError as error:
      writeError(error.msg)
      2
    except CatchableError as error:
      writeError(error.msg)
      1
  quit(exitCode)
