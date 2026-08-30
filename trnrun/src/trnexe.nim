## Launches the TRNSYS executable for a validated deck file.

import std/[os, osproc]
import ./settings


type TrnexeLaunchError* = object of CatchableError
  ## Raised when TrnEXE fails to start.

proc launchTrnexe*(
    deckFile: string,
    trnexePath: string,
    guiVisibility: TrnexeGuiVisibility,
): Process =
  ## Spawns TrnEXE for `deckFile` and returns the process; raises
  ## `TrnexeLaunchError` on failure.
  result = default(Process)
  var args = @[deckFile]
  let switch = guiVisibility.flag()
  if switch.len > 0:
    args.add(switch)

  try:
    return startProcess(
      trnexePath,
      workingDir = deckFile.parentDir(),
      args = args,
      options = {},
    )
  except OSError, IOError:
    raise newException(
      TrnexeLaunchError,
      "Failed to launch TRNSYS: " & getCurrentExceptionMsg(),
    )
