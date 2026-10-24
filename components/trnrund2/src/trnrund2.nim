## Starts trnrund2, which runs TRNRun simulations for one client.
##
## The client writes one JSON request per stdin line and reads exactly one JSON
## response per stdout line before sending the next. Diagnostics go to stderr.
## Closing stdin cancels every simulation and exits.

import std/os
import ./[cli, job, pipe, pool, protocol, validate]

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

proc run(input: CliInput): int =
  ## Serves the client with `input` until it closes stdin and returns the exit code.
  ##
  ## Returns 0 once the client closes stdin. Returns 1 after writing the error
  ## to stderr if the job guard or pipe cannot be set up, or a fault stops the
  ## serve loop. Never raises a `CatchableError`.
  result = 0
  var pool = initPool(input.trnrunPath, input.maxWorkers)
  try:
    # Windows kills every TRNRun this daemon started once it exits, however it exits.
    initJobGuard()
    openPipe()
    pool.serve()
  except CatchableError as error:
    diagnose(error.msg)
    result = 1

proc main(): int =
  ## Runs what the command line asks for and returns the exit code.
  try:
    let command = parseCommandLine(commandLineParams())
    case command.action
    of caHelp:
      echo HelpText
      result = 0
    of caVersion:
      echo NimblePkgVersion
      result = 0
    of caServe:
      var input = command.input
      input.trnrunPath = validateFile(input.trnrunPath, "TRNRun")
      result = run(input) # Never raises: `run` turns its own failures into exit code 1.
  except InputError as error:
    diagnose(error.msg)
    result = 2

when isMainModule:
  quit(main())
