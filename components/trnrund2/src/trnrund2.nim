## Starts trnrund2, which runs TRNRun simulations for one client.
##
## The client writes one JSON request per stdin line and reads exactly one JSON
## response per stdout line before sending the next. Diagnostics go to stderr.
## Closing stdin cancels every simulation and exits.

import std/os
import ./cli
import ./client/[pipe, protocol, validate]
import ./worker/[job, pool]

const PollMs = 10 ## Idle wait between checks for requests and finished simulations.

proc serve(pool: var Pool) =
  ## Answers requests until the client closes stdin, keeping simulations moving meanwhile.
  var line = ""
  while true:
    pool.update()
    case poll(line)
    of prNothing: sleep(PollMs)
    of prLine: respond(pool.handleRequest(line))
    of prClosed: return

proc main(): int =
  ## Runs the daemon and returns its exit code.
  var input = default(CliInput)
  try:
    let command = parseCommandLine(commandLineParams())
    case command.action
    of caHelp:
      echo HelpText
      return 0
    of caVersion:
      echo NimblePkgVersion
      return 0
    of caServe:
      input = command.input
      input.trnrunPath = validateFile(input.trnrunPath, "TRNRun")
  except InputError as error:
    stderr.writeLine("trnrund2: ", error.msg)
    return 2
  var pool = initPool(input.trnrunPath, input.workers)
  try:
    initJobGuard() # Even if the daemon crashes, Windows then kills every TRNRun it started.
    openPipe()
    pool.serve()
  except CatchableError as error:
    stderr.writeLine("trnrund2: ", error.msg)
    return 1
  finally:
    pool.stop()
  0

when isMainModule:
  quit(main())
